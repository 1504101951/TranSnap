import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit

struct ApplicationCaptureCanvas: Equatable {
    struct Display: Equatable {
        let id: CGDirectDisplayID
        let frame: CGRect
        let scale: CGFloat
    }
    let displays: [Display]
    let bounds: CGRect
    let scale: CGFloat
    let size: CGSize

    init(displays: [Display]) throws {
        guard !displays.isEmpty, Set(displays.map(\.id)).count == displays.count,
              displays.allSatisfy({ $0.scale.isFinite && $0.scale > 0 &&
                !$0.frame.isEmpty && !$0.frame.isInfinite && !$0.frame.isNull &&
                [$0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height].allSatisfy(\.isFinite) }) else {
            throw GIFExporter.ExportError(message: "显示器布局无效，无法建立应用录制画布。")
        }
        self.displays = displays.sorted { $0.id < $1.id }
        bounds = displays.dropFirst().reduce(displays[0].frame) { $0.union($1.frame) }
        scale = displays.map(\.scale).max()!
        size = CGSize(width: ceil(bounds.width * scale / 2) * 2,
                      height: ceil(bounds.height * scale / 2) * 2)
    }

    func composite(_ frames: [CGDirectDisplayID: CIImage]) -> CIImage {
        let extent = CGRect(origin: .zero, size: size)
        var image = CIImage(color: .black).cropped(to: extent)
        for display in displays {
            guard let frame = frames[display.id] else { continue }
            let rect = CGRect(x: (display.frame.minX - bounds.minX) * scale,
                y: size.height - (display.frame.maxY - bounds.minY) * scale,
                width: display.frame.width * scale, height: display.frame.height * scale)
            let content = frame.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: -frame.extent.minX, y: -frame.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: rect.width / frame.extent.width, y: rect.height / frame.extent.height))
                .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
                .cropped(to: rect)
            image = content.composited(over: image)
        }
        return image.cropped(to: extent)
    }
}

final class ApplicationVideoEncoder: NSObject, SCStreamOutput, @unchecked Sendable {
    private static let mediaTimeScale: CMTimeScale = 600
    let queue = DispatchQueue(label: "TranSnap.application-video")
    let canvas: ApplicationCaptureCanvas
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var streams: [ObjectIdentifier: CGDirectDisplayID] = [:]
    private var frames: [CGDirectDisplayID: CIImage] = [:]
    private var composed: CVPixelBuffer?
    private var changed = false
    private var timer: DispatchSourceTimer?
    private var epoch: CMTime?
    private var lastTime = CMTime.invalid
    private var ready: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var finishing = false
    private let onFailure: @Sendable (Error) -> Void

    init(canvas: ApplicationCaptureCanvas, url: URL, onFailure: @escaping @Sendable (Error) -> Void) throws {
        self.canvas = canvas
        self.onFailure = onFailure
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(canvas.size.width), AVVideoHeightKey: Int(canvas.size.height),
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoExpectedSourceFrameRateKey: AppConstants.recordingFramesPerSecond]]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw GIFExporter.ExportError(message: "编码器不支持当前显示器联合画布尺寸，请调整显示器布局后重试。")
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        input.mediaTimeScale = Self.mediaTimeScale
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(canvas.size.width),
                kCVPixelBufferHeightKey as String: Int(canvas.size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        super.init()
        guard writer.canAdd(input) else { throw GIFExporter.ExportError(message: "无法建立应用录制编码轨道。") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? GIFExporter.ExportError(message: "无法启动应用录制编码器。") }
    }

    func register(_ identities: [ObjectIdentifier: CGDirectDisplayID]) { queue.sync { streams = identities } }

    func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.finishing else { continuation.resume(throwing: CancellationError()); return }
                if let failure = self.failure { continuation.resume(throwing: failure); return }
                if self.lastTime.isValid { continuation.resume(); return }
                self.ready = continuation
                self.queue.asyncAfter(deadline: .now() + 5) {
                    guard self.ready != nil else { return }
                    self.report(GIFExporter.ExportError(message: "未能取得全部显示器画面，应用录制未开始。"))
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finishing, failure == nil, type == .screen,
              let display = streams[ObjectIdentifier(stream)],
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        if status == .idle || (status == .started && CMSampleBufferGetImageBuffer(sampleBuffer) == nil) { return }
        guard status == .complete || status == .started, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            report(GIFExporter.ExportError(message: "显示器画面已中断，已停止应用录制。"))
            return
        }
        receive(CIImage(cvPixelBuffer: buffer), display: display)
    }

    func receive(_ image: CIImage, display: CGDirectDisplayID) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !finishing, failure == nil, canvas.displays.contains(where: { $0.id == display }) else { return }
        frames[display] = image
        changed = true
        guard epoch == nil, frames.count == canvas.displays.count else { return }
        writer.startSession(atSourceTime: .zero)
        epoch = CMClockGetTime(CMClockGetHostTimeClock())
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / Int(AppConstants.recordingFramesPerSecond)))
        timer.setEventHandler { [weak self] in self?.appendFrame() }
        self.timer = timer
        timer.resume()
        appendFrame()
    }

    private func appendFrame() {
        guard !finishing, failure == nil, let epoch else { return }
        guard input.isReadyForMoreMediaData else {
            if writer.status == .failed { report(writer.error ?? GIFExporter.ExportError(message: "应用录制编码失败。")) }
            return
        }
        let buffer: CVPixelBuffer
        if let composed, !changed {
            buffer = composed
        } else {
            var created: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess,
                  let created else { report(GIFExporter.ExportError(message: "联合画布无法分配像素缓冲，请缩小显示器布局。")); return }
            context.render(canvas.composite(frames), to: created, bounds: CGRect(origin: .zero, size: canvas.size),
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            composed = created
            changed = false
            buffer = created
        }
        let elapsed = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), epoch)
        let time = lastTime.isValid ? CMTimeConvertScale(elapsed, timescale: Self.mediaTimeScale, method: .roundTowardZero) : .zero
        guard !lastTime.isValid || CMTimeCompare(time, lastTime) > 0 else { return }
        guard adaptor.append(buffer, withPresentationTime: time) else {
            report(writer.error ?? GIFExporter.ExportError(message: "无法追加应用录制画面。")); return
        }
        lastTime = time
        ready?.resume()
        ready = nil
    }

    private func report(_ error: Error) {
        guard failure == nil, !finishing else { return }
        failure = error
        timer?.cancel()
        timer = nil
        ready?.resume(throwing: error)
        ready = nil
        onFailure(error)
    }

    func finish(discard: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.finishing = true
                self.timer?.cancel()
                self.timer = nil
                self.ready?.resume(throwing: CancellationError())
                self.ready = nil
                self.frames = [:]
                self.composed = nil
                if discard || !self.lastTime.isValid {
                    self.writer.cancelWriting()
                    if discard { continuation.resume() }
                    else { continuation.resume(throwing: self.failure ?? GIFExporter.ExportError(message: "没有可保留的应用录制画面。")) }
                    return
                }
                self.writer.endSession(atSourceTime: CMTimeAdd(self.lastTime, CMTime(value: 1, timescale: AppConstants.recordingFramesPerSecond)))
                self.input.markAsFinished()
                self.writer.finishWriting {
                    if self.writer.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: self.writer.error ?? GIFExporter.ExportError(message: "应用录制未能完成编码。")) }
                }
            }
        }
    }
}

@MainActor
final class ApplicationRecorder: NSObject, SCStreamDelegate {
    let canvas: ApplicationCaptureCanvas
    private let applicationID: String
    private let encoder: ApplicationVideoEncoder
    private var streams: [SCStream] = []
    private let background = CGColor(gray: 0, alpha: 1)
    private var ended = false
    private var finishTask: Task<Void, Error>?
    private let onFailure: @MainActor (Error) -> Void

    init(content: SCShareableContent, applicationID: String, expected: ApplicationCaptureCanvas?, url: URL,
         onFailure: @escaping @MainActor (Error) -> Void) async throws {
        let apps = content.applications.filter { $0.bundleIdentifier == applicationID }
        guard applicationID != Bundle.main.bundleIdentifier, !apps.isEmpty,
              content.windows.contains(where: { $0.isOnScreen && $0.frame.width > 0 && $0.frame.height > 0 && $0.owningApplication?.bundleIdentifier == applicationID }) else {
            throw GIFExporter.ExportError(message: "所选应用已退出或没有可录制的可见窗口。")
        }
        self.applicationID = applicationID
        self.onFailure = onFailure
        let own = try DisplayCapture.ownApplications(in: content)
        let included = apps + own
        let excepted = try await DisplayCapture.controlWindows()
        let filters = content.displays.map { display in
            (display, SCContentFilter(display: display, including: included, exceptingWindows: excepted))
        }
        canvas = try ApplicationCaptureCanvas(displays: filters.map {
            .init(id: $0.0.displayID, frame: $0.0.frame, scale: CGFloat($0.1.pointPixelScale))
        })
        guard expected == nil || expected == canvas else {
            throw GIFExporter.ExportError(message: "显示器布局或倍率已改变，请结束并保存当前录制后重新开始。")
        }
        let encodingCanvas = canvas
        encoder = try await Task.detached(priority: .userInitiated) {
            try ApplicationVideoEncoder(canvas: encodingCanvas, url: url) { error in
                Task { @MainActor in onFailure(error) }
            }
        }.value
        super.init()
        var identities: [ObjectIdentifier: CGDirectDisplayID] = [:]
        for (display, filter) in filters {
            filter.includeMenuBar = false
            let config = SCStreamConfiguration()
            config.width = Int((display.frame.width * CGFloat(filter.pointPixelScale)).rounded())
            config.height = Int((display.frame.height * CGFloat(filter.pointPixelScale)).rounded())
            config.minimumFrameInterval = CMTime(value: 1, timescale: AppConstants.recordingFramesPerSecond)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.backgroundColor = background
            config.ignoreShadowsDisplay = true
            config.showsCursor = false
            config.capturesAudio = false
            config.captureMicrophone = false
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(encoder, type: .screen, sampleHandlerQueue: encoder.queue)
            streams.append(stream)
            identities[ObjectIdentifier(stream)] = display.displayID
        }
        encoder.register(identities)
    }

    func start() async throws {
        for stream in streams {
            guard !ended else { throw CancellationError() }
            try await stream.startCapture()
            if ended { try? await stream.stopCapture(); throw CancellationError() }
        }
        try await encoder.waitUntilReady()
    }

    func validate() async throws {
        try DisplayCapture.requireAuthorization()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard content.windows.contains(where: { $0.isOnScreen && $0.frame.width > 0 && $0.frame.height > 0 && $0.owningApplication?.bundleIdentifier == applicationID }) else {
            throw GIFExporter.ExportError(message: "所选应用已退出或没有可录制的可见窗口。")
        }
        let current = try ApplicationCaptureCanvas(displays: content.displays.map {
            .init(id: $0.displayID, frame: $0.frame,
                  scale: CGFloat(SCContentFilter(display: $0, excludingWindows: []).pointPixelScale))
        })
        guard current == canvas else { throw GIFExporter.ExportError(message: "显示器布局或倍率已改变，已停止并保留录制内容。") }
    }

    func finish(discard: Bool) async throws {
        if let finishTask { return try await finishTask.value }
        ended = true
        let active = streams
        streams = []
        let task = Task { @MainActor in
            for stream in active { try? await stream.stopCapture() }
            try await encoder.finish(discard: discard)
        }
        finishTask = task
        try await task.value
    }

    nonisolated func stream(_ stopped: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard !ended, streams.contains(where: { $0 === stopped }) else { return }
            onFailure(error)
        }
    }
}
