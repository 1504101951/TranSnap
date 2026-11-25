import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

struct LiveOcrSlot {
    private(set) var busy = false
    private var pending = false
    private(set) var acceptedGeneration = 0
    private var pendingGeneration = 0

    mutating func adopt(_ generation: Int) {
        acceptedGeneration = generation
        pending = false
    }

    mutating func offer(generation: Int) -> Bool {
        guard generation == acceptedGeneration else { return false }
        if busy {
            pending = true
            pendingGeneration = generation
            return false
        }
        busy = true
        return true
    }

    mutating func finish() -> Bool {
        busy = false
        guard pending, pendingGeneration == acceptedGeneration else {
            pending = false
            return false
        }
        pending = false
        busy = true
        return true
    }
}

@MainActor
final class LiveRegionCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    var onRecognized: ((Int, [[String: Any]]?, String?) -> Void)?
    var onUnavailable: ((String) -> Void)?
    var onFrame: ((NSRect) -> Void)?

    private let queue = DispatchQueue(label: "transnap.live-frames")
    private let background = CGColor(gray: 0, alpha: 1)
    private var slot = LiveOcrSlot()
    private var streams: [SCStream] = []
    private var frames: [ObjectIdentifier: CMSampleBuffer] = [:]
    private var changed: Set<ObjectIdentifier> = []
    private var recognized: [ObjectIdentifier: [[String: Any]]] = [:]
    private var frameBounds: [ObjectIdentifier: NSRect] = [:]
    private var running = false
    private var targetDisplayID: CGDirectDisplayID?
    private var screenObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var lockObserver: NSObjectProtocol?

    func start(
        source: [String: Any],
        region: MediaCaptureService.Region?,
        generation: Int
    ) async throws {
        try DisplayCapture.requireAuthorization()
        await stopStreams()
        slot.adopt(generation)
        frames.removeAll()
        changed.removeAll()
        recognized.removeAll()
        frameBounds.removeAll()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let kind = source["kind"] as? String else {
            throw GIFExporter.ExportError(message: "缺少采集方式。")
        }
        let built = try build(kind: kind, source: source, region: region, content: content)
        targetDisplayID = built.displayID
        onFrame?(built.shade)
        for item in built.streams {
            try item.stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            streams.append(item.stream)
            frameBounds[ObjectIdentifier(item.stream)] = item.bounds
        }
        running = true
        observeSystem()
        for item in built.streams {
            guard running else { throw CancellationError() }
            try await item.stream.startCapture()
        }
    }

    func pause(generation: Int) async {
        slot.adopt(generation)
        running = false
        frames.removeAll()
        changed.removeAll()
        recognized.removeAll()
        frameBounds.removeAll()
        await stopStreams()
    }

    func resume(source: [String: Any], region: MediaCaptureService.Region?, generation: Int) async throws {
        try await start(source: source, region: region, generation: generation)
    }

    func stop() async {
        running = false
        slot.adopt(slot.acceptedGeneration + 1)
        frames.removeAll()
        changed.removeAll()
        recognized.removeAll()
        frameBounds.removeAll()
        await stopStreams()
        removeObservers()
    }

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return }
        if status == .idle || (status == .started && CMSampleBufferGetImageBuffer(sampleBuffer) == nil) { return }
        guard status == .complete || status == .started,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        let retained = sampleBuffer
        let identity = ObjectIdentifier(stream)
        Task { @MainActor in
            self.receive(identity, sample: retained)
        }
    }

    nonisolated func stream(_ stopped: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.running, self.streams.contains(where: { $0 === stopped }) else { return }
            self.fail(error.localizedDescription)
        }
    }

    private func receive(_ identity: ObjectIdentifier, sample: CMSampleBuffer) {
        guard running else { return }
        frames[identity] = sample
        changed.insert(identity)
        guard slot.offer(generation: slot.acceptedGeneration) else { return }
        recognize(slot.acceptedGeneration)
    }

    private func recognize(_ generation: Int) {
        let batch = frames.map { ($0.key, $0.value) }
        let bounds = frameBounds
        let fresh = changed
        changed = []
        let cached = recognized
        Task.detached {
            let started = ContinuousClock.now
            var pixels = 0.0
            let outcome: Result<(blocks: [[String: Any]], perStream: [ObjectIdentifier: [[String: Any]]]), Error>
            do {
                var blocks: [[String: Any]] = []
                var latest: [ObjectIdentifier: [[String: Any]]] = [:]
                for (identity, sample) in batch {
                    if !fresh.contains(identity), let previous = cached[identity] {
                        latest[identity] = previous
                        blocks.append(contentsOf: previous)
                        continue
                    }
                    var streamBlocks: [[String: Any]] = []
                    defer {
                        latest[identity] = streamBlocks
                        blocks.append(contentsOf: streamBlocks)
                    }
                    guard let buffer = CMSampleBufferGetImageBuffer(sample),
                          let imageBounds = bounds[identity] else { continue }
                    let found = try await ScreenCaptureService.recognizeParagraphs(pixelBuffer: buffer)
                    let pixelWidth = Double(CVPixelBufferGetWidth(buffer))
                    let pixelHeight = Double(CVPixelBufferGetHeight(buffer))
                    guard pixelWidth > 0, pixelHeight > 0 else { continue }
                    pixels += pixelWidth * pixelHeight
                    for item in found {
                        guard let text = item["text"] as? String,
                              let x = item["x"] as? Double,
                              let y = item["y"] as? Double,
                              let width = item["width"] as? Double,
                              let height = item["height"] as? Double else { continue }
                        let rect = NSRect(
                            x: imageBounds.minX + x / pixelWidth * imageBounds.width,
                            y: imageBounds.maxY - (y + height) / pixelHeight * imageBounds.height,
                            width: width / pixelWidth * imageBounds.width,
                            height: height / pixelHeight * imageBounds.height
                        )
                        streamBlocks.append([
                            "text": text,
                            "x": rect.minX,
                            "y": rect.minY,
                            "width": rect.width,
                            "height": rect.height,
                        ])
                    }
                }
                blocks.sort { lhs, rhs in
                    let ly = lhs["y"] as? Double ?? 0
                    let ry = rhs["y"] as? Double ?? 0
                    let lh = lhs["height"] as? Double ?? 0
                    let rh = rhs["height"] as? Double ?? 0
                    if abs((ly + lh) - (ry + rh)) > 1 { return ly + lh > ry + rh }
                    return (lhs["x"] as? Double ?? 0) < (rhs["x"] as? Double ?? 0)
                }
                let elapsed = started.duration(to: .now).components
                let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                LiveRegionLog.note("ocr ms=\(Int(milliseconds)) pixels=\(Int(pixels)) paragraphs=\(blocks.count)")
                outcome = .success((blocks, latest))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                let follow = self.slot.finish()
                if generation == self.slot.acceptedGeneration, self.running {
                    switch outcome {
                    case let .success(result):
                        self.recognized = result.perStream
                        self.onRecognized?(generation, result.blocks, nil)
                    case let .failure(error):
                        self.changed.formUnion(fresh)
                        self.onRecognized?(generation, nil, error.localizedDescription)
                    }
                }
                if follow, self.running {
                    self.recognize(self.slot.acceptedGeneration)
                }
            }
        }
    }

    private func fail(_ message: String) {
        guard running else { return }
        running = false
        onUnavailable?(message)
    }

    private func observeSystem() {
        removeObservers()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.noteScreens() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.fail("屏幕已锁定或进入睡眠。") }
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.fail("屏幕已锁定或进入睡眠。") }
        }
    }

    private func noteScreens() {
        guard running, let targetDisplayID else { return }
        let ids = NSScreen.screens.compactMap(\.displayID)
        if !ids.contains(targetDisplayID) {
            fail("目标显示器已移除。")
        }
    }

    private func removeObservers() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
        screenObserver = nil
        sleepObserver = nil
        lockObserver = nil
    }

    private func stopStreams() async {
        let active = streams
        streams = []
        for stream in active {
            try? await stream.stopCapture()
        }
    }

    private func build(
        kind: String,
        source: [String: Any],
        region: MediaCaptureService.Region?,
        content: SCShareableContent
    ) throws -> (streams: [(stream: SCStream, displayID: CGDirectDisplayID, bounds: NSRect)], shade: NSRect, displayID: CGDirectDisplayID) {
        if kind == CaptureTarget.application.rawValue {
            guard let applicationID = source["applicationID"] as? String else {
                throw GIFExporter.ExportError(message: "请选择要翻译的应用。")
            }
            let apps = content.applications.filter { $0.bundleIdentifier == applicationID }
            guard applicationID != Bundle.main.bundleIdentifier, !apps.isEmpty,
                  content.windows.contains(where: {
                      $0.isOnScreen && $0.frame.width > 0 && $0.frame.height > 0 &&
                      $0.owningApplication?.bundleIdentifier == applicationID
                  }) else {
                throw GIFExporter.ExportError(message: "所选应用已退出或没有可识别的可见窗口。")
            }
            let filters = content.displays.map { display in
                (display, SCContentFilter(display: display, including: apps, exceptingWindows: []))
            }
            let canvas = try ApplicationCaptureCanvas(displays: filters.map {
                .init(id: $0.0.displayID, frame: $0.0.frame, scale: CGFloat($0.1.pointPixelScale))
            })
            let interval = CMTime(value: CMTimeValue(AppConstants.liveCaptureMinIntervalMs), timescale: 1000)
            var streams: [(SCStream, CGDirectDisplayID, NSRect)] = []
            for (display, filter) in filters {
                filter.includeMenuBar = false
                let config = baseConfig(width: Int((display.frame.width * CGFloat(filter.pointPixelScale)).rounded()),
                                         height: Int((display.frame.height * CGFloat(filter.pointPixelScale)).rounded()),
                                         interval: interval)
                config.backgroundColor = background
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                streams.append((
                    stream,
                    display.displayID,
                    CaptureGeometry.appKitRect(fromCGWindowBounds: display.frame)
                ))
            }
            let sourceID = (source["sourceID"] as? NSNumber)?.uint32Value ?? filters[0].0.displayID
            return (streams, CaptureGeometry.appKitRect(fromCGWindowBounds: canvas.bounds), sourceID)
        }
        let displayID = kind == CaptureTarget.region.rawValue
            ? region?.displayID
            : (source["sourceID"] as? NSNumber)?.uint32Value
        let display = try DisplayCapture.display(displayID, in: content)
        let own = try DisplayCapture.ownApplications(in: content)
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        var crop: CGRect?
        if kind == CaptureTarget.region.rawValue, let region {
            crop = try DisplayCapture.crop(region, in: filter)
        }
        let scale = CGFloat(filter.pointPixelScale)
        let size = crop?.size ?? filter.contentRect.size
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        try DisplayCapture.requireMinimumSize(width: width, height: height)
        let config = baseConfig(
            width: width,
            height: height,
            interval: CMTime(value: CMTimeValue(AppConstants.liveCaptureMinIntervalMs), timescale: 1000)
        )
        if let crop { config.sourceRect = crop }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        var target = display.frame
        let actual = crop ?? CGRect(origin: .zero, size: filter.contentRect.size)
        target.origin.x += actual.minX
        target.origin.y += actual.minY
        target.size = actual.size
        let bounds = CaptureGeometry.appKitRect(fromCGWindowBounds: target)
        return ([(stream, display.displayID, bounds)], bounds, display.displayID)
    }

    private func baseConfig(width: Int, height: Int, interval: CMTime) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = interval
        config.showsCursor = false
        config.capturesAudio = false
        config.captureMicrophone = false
        config.scalesToFit = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 3
        return config
    }
}
