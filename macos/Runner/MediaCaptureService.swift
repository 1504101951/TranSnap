import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import FlutterMacOS
import ScreenCaptureKit

@MainActor
final class MediaCaptureService: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    struct Region {
        let displayID: CGDirectDisplayID
        let rect: CGRect
        let scale: CGFloat
        let edges: ScrollStitcher.Edges
    }

    private var applicationRecorder: ApplicationRecorder?
    private var applicationCanvas: ApplicationCaptureCanvas?
    private var applicationSegmentID: UUID?
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var temporaryDirectory: URL?
    private var video: URL?
    private var scrollTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var finishScroll = false
    private var autoScrollAvailable = false
    private var autoScrollActive = false
    private var scrollWheelMonitor: Any?
    private var scrollHintSerial = 0
    private var discardRecording = false
    private var recordingFailure: String?
    private var recordingSegments: [URL] = []
    private var recordingArguments: [String: Any] = [:]
    private var recordedElapsed: TimeInterval = 0
    private var recordingCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var timer: Timer?
    private var startedAt: Date?
    private let clickOverlay = RecordingClickOverlay()
    private var recordingRequestedAt: ContinuousClock.Instant?
    private(set) var phase = CapturePhase.idle
    private(set) var id = UUID().uuidString
    private(set) var trim: CMTimeRange?
    private(set) var region: Region?
    private(set) var captureFrame: NSRect?
    private var details: [String: Any] = [:]
    var onChange: (([String: Any]) -> Void)?
    var onActiveChanged: ((Bool) -> Void)?
    var onScrollPreview: ((ScrollStitcher.Preview, CGFloat) -> Void)?

    var isBusy: Bool { [.preparing, .recording, .pausing, .paused, .finalizing, .scrolling, .converting].contains(phase) }

    var isCountingDown: Bool { phase == .preparing && details["countdown"] != nil }

    var isRegionRecording: Bool {
        details["kind"] as? String == "recording"
            && recordingArguments["kind"] as? String == CaptureTarget.region.rawValue
    }

    func snapshot() -> [String: Any] {
        var value = details
        value["id"] = id
        value["phase"] = phase.rawValue
        return value
    }

    private func update(_ next: CapturePhase, _ values: [String: Any] = [:]) {
        if next == .recording, let requested = recordingRequestedAt {
            CaptureStartupLog.record("recording-ready", since: requested)
            recordingRequestedAt = nil
        }
        if [.idle, .failed].contains(next) { recordingRequestedAt = nil }
        phase = next
        details.merge(values) { _, new in new }
        onChange?(snapshot())
    }

    func select(_ selection: Region) throws {
        guard !isBusy else { throw GIFExporter.ExportError(message: "请先结束当前采集。") }
        region = selection
        update(phase)
    }

    func sources(preferredApplicationID: String?) async throws -> [[String: Any]] {
        guard await ScreenCaptureService.requestAccess() else {
            throw GIFExporter.ExportError(message: AppConstants.screenRecordingRequiredMessage)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let visible = Set(content.windows.filter {
            $0.frame.width > 0 && $0.frame.height > 0 && $0.isOnScreen
        }.compactMap { $0.owningApplication?.bundleIdentifier })
        var applications: [String: [String: Any]] = [:]
        for app in content.applications where visible.contains(app.bundleIdentifier) && app.bundleIdentifier != Bundle.main.bundleIdentifier {
            guard applications[app.bundleIdentifier] == nil else { continue }
            let running = NSRunningApplication(processIdentifier: app.processID)
            let icon = running?.icon ?? running?.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            var source: [String: Any] = ["kind": CaptureTarget.application.rawValue, "applicationID": app.bundleIdentifier,
                "name": app.applicationName,
                "windows": content.windows.filter { $0.isOnScreen && $0.owningApplication?.bundleIdentifier == app.bundleIdentifier }
                    .map { ["x": $0.frame.minX, "y": $0.frame.minY, "width": $0.frame.width, "height": $0.frame.height] }]
            if let png = Self.applicationIconPNG(icon) { source["icon"] = FlutterStandardTypedData(bytes: png) }
            applications[app.bundleIdentifier] = source
        }
        return applications.values.sorted { lhs, rhs in
            let left = lhs["applicationID"] as! String, right = rhs["applicationID"] as! String
            if left == preferredApplicationID { return true }
            if right == preferredApplicationID { return false }
            let order = (lhs["name"] as! String).localizedStandardCompare(rhs["name"] as! String)
            return order == .orderedSame ? left < right : order == .orderedAscending
        }
    }

    static func applicationIconPNG(_ image: NSImage?) -> Data? {
        guard let image, let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 32, height: 32))
        image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero, operation: .copy, fraction: 1)
        return bitmap.representation(using: .png, properties: [:])
    }

    private func configuration(_ args: [String: Any], video: Bool) async throws -> (SCContentFilter, SCStreamConfiguration) {
        try DisplayCapture.requireAuthorization()
        let token = id
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard token == id else { throw CancellationError() }
        guard let kind = args["kind"] as? String else { throw GIFExporter.ExportError(message: "缺少采集方式。") }
        let filter: SCContentFilter
        var crop: CGRect?
        var targetFrame: CGRect
        do {
            let displayID = kind == CaptureTarget.region.rawValue ? region?.displayID : (args["sourceID"] as? NSNumber)?.uint32Value
            guard [CaptureTarget.display.rawValue, CaptureTarget.region.rawValue].contains(kind) else {
                throw GIFExporter.ExportError(message: "捕获目标已不可用，请重新选择。")
            }
            let display = try DisplayCapture.display(displayID, in: content)
            if video {
                filter = SCContentFilter(display: display, excludingWindows: try await DisplayCapture.controlWindows())
            } else {
                let own = try DisplayCapture.ownApplications(in: content)
                filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            }
            targetFrame = display.frame
            if kind == CaptureTarget.region.rawValue, let region {
                crop = try DisplayCapture.crop(region, in: filter)
            }
        }
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let size = crop?.size ?? filter.contentRect.size
        var width = Int((size.width * scale).rounded(video ? .down : .toNearestOrAwayFromZero))
        var height = Int((size.height * scale).rounded(video ? .down : .toNearestOrAwayFromZero))
        if video { width -= width % 2; height -= height % 2 }
        try DisplayCapture.requireMinimumSize(width: width, height: height)
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: AppConstants.recordingFramesPerSecond)
        config.showsCursor = video
        let clickConfig = RecordingClickOverlay.resolvedConfig(preferences: AppPreferences.current)
        config.showMouseClicks = video && clickConfig.effect == .system
        config.capturesAudio = false
        config.captureMicrophone = false
        config.scalesToFit = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        if video {
            config.sourceRect = CGRect(origin: crop?.origin ?? .zero,
                size: CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
        } else if let crop { config.sourceRect = crop }
        let actualCrop = video ? config.sourceRect : crop ?? CGRect(origin: .zero, size: filter.contentRect.size)
        targetFrame.origin.x += actualCrop.minX
        targetFrame.origin.y += actualCrop.minY
        targetFrame.size = actualCrop.size
        captureFrame = CaptureGeometry.appKitRect(fromCGWindowBounds: targetFrame)
        return (filter, config)
    }

    private func begin() throws {
        if phase == .failed { clear() }
        guard !isBusy, video == nil, details["imageBytes"] == nil else {
            throw GIFExporter.ExportError(message: "请先保存或丢弃当前结果。")
        }
        id = UUID().uuidString
        details = [:]
        captureFrame = nil
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TranSnap-Capture-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        temporaryDirectory = directory
        update(.preparing)
        onActiveChanged?(true)
    }

    func startRecording(_ args: [String: Any], delay: Int) async throws {
        let started = ContinuousClock.now
        defer { CaptureStartupLog.record("start-recording-await", since: started) }
        try begin()
        recordingArguments = args
        details["kind"] = "recording"
        let token = id
        for remaining in stride(from: delay, to: 0, by: -1) {
            update(.preparing, ["countdown": remaining])
            try await Task.sleep(for: .seconds(1))
            guard token == id else { throw CancellationError() }
        }
        details.removeValue(forKey: "countdown")
        try await startRecordingSegment()
    }

    private func startRecordingSegment() async throws {
        let token = id
        var startingStream: SCStream?
        recordingRequestedAt = .now
        let previousFrame = captureFrame
        details.removeValue(forKey: "error")
        update(.preparing)
        do {
            if recordingArguments["kind"] as? String == CaptureTarget.application.rawValue {
                try await startApplicationSegment()
                return
            }
            let configurationStarted = ContinuousClock.now
            let (filter, config) = try await configuration(recordingArguments, video: true)
            CaptureStartupLog.record("screen-configuration-await", since: configurationStarted)
            guard token == id else { throw CancellationError() }
            if !recordingSegments.isEmpty,
               (details["width"] as? Int != config.width || details["height"] as? Int != config.height) {
                throw GIFExporter.ExportError(message: "目标尺寸已改变，请结束并保存当前录制后重新开始。")
            }
            let outputURL = temporaryDirectory!.appendingPathComponent("segment-\(UUID().uuidString).mp4")
            let resourceStarted = ContinuousClock.now
            let outputConfig = SCRecordingOutputConfiguration()
            outputConfig.outputURL = outputURL
            outputConfig.videoCodecType = .h264
            outputConfig.outputFileType = .mp4
            let output = SCRecordingOutput(configuration: outputConfig, delegate: self)
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addRecordingOutput(output)
            startingStream = stream
            CaptureStartupLog.record("screen-resources-sync", since: resourceStarted)
            self.stream = stream
            recordingOutput = output
            video = outputURL
            discardRecording = false
            recordingFailure = nil
            details["width"] = config.width
            details["height"] = config.height
            let captureStarted = ContinuousClock.now
            try await stream.startCapture()
            CaptureStartupLog.record("screen-start-await", since: captureStarted)
        } catch {
            guard token == id else { throw error }
            if let startingStream, stream !== startingStream { throw error }
            if recordingSegments.isEmpty {
                await fail(error)
                throw error
            }
            if let recorder = applicationRecorder {
                try? await recorder.finish(discard: true)
                guard token == id, applicationRecorder === recorder else { throw error }
                applicationRecorder = nil
            }
            let active = stream
            stream = nil
            recordingOutput = nil
            try? await active?.stopCapture()
            guard token == id else { throw error }
            video = recordingSegments.last
            captureFrame = previousFrame
            update(.paused, ["error": error.localizedDescription])
            throw error
        }
    }

    private func startApplicationSegment() async throws {
        let started = ContinuousClock.now
        defer { CaptureStartupLog.record("application-segment-await", since: started) }
        let token = id
        try DisplayCapture.requireAuthorization()
        guard let applicationID = recordingArguments["applicationID"] as? String else {
            throw GIFExporter.ExportError(message: "捕获目标已不可用，请重新选择。")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard token == id else { throw CancellationError() }
        let url = temporaryDirectory!.appendingPathComponent("application-\(UUID().uuidString).mp4")
        let segmentID = UUID()
        applicationSegmentID = segmentID
        let recorder = try await ApplicationRecorder(content: content, applicationID: applicationID,
            expected: applicationCanvas, url: url) { [weak self] error in
            guard let self, self.id == token, self.applicationSegmentID == segmentID, self.phase == .recording else { return }
            Task { @MainActor in
                guard self.id == token, self.applicationSegmentID == segmentID else { return }
                await self.finishApplicationSegment(paused: false, warning: error.localizedDescription)
            }
        }
        guard token == id, applicationSegmentID == segmentID else {
            try? await recorder.finish(discard: true)
            throw CancellationError()
        }
        applicationRecorder = recorder
        applicationCanvas = recorder.canvas
        captureFrame = CaptureGeometry.appKitRect(fromCGWindowBounds: recorder.canvas.bounds)
        video = url
        details["width"] = Int(recorder.canvas.size.width)
        details["height"] = Int(recorder.canvas.size.height)
        try await recorder.start()
        guard token == id, applicationRecorder === recorder else { throw CancellationError() }
        startedAt = Date()
        update(.recording, ["elapsed": recordedElapsed])
        var validating = false
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.id == token, self.phase == .recording,
                      self.applicationRecorder === recorder, !validating else { return }
                validating = true
                defer { validating = false }
                do {
                    try await recorder.validate()
                    guard self.id == token, self.applicationRecorder === recorder, self.phase == .recording, let start = self.startedAt else { return }
                    self.update(.recording, ["elapsed": self.recordedElapsed + Date().timeIntervalSince(start)])
                } catch {
                    guard self.id == token, self.applicationRecorder === recorder, self.phase == .recording else { return }
                    await self.finishApplicationSegment(paused: false, warning: error.localizedDescription)
                }
            }
        }
    }

    private func finishApplicationSegment(paused: Bool, warning: String? = nil) async {
        guard let recorder = applicationRecorder, phase == .recording else { return }
        let token = id
        timer?.invalidate()
        timer = nil
        if let startedAt { recordedElapsed += Date().timeIntervalSince(startedAt) }
        startedAt = nil
        update(paused ? .pausing : .finalizing, ["elapsed": recordedElapsed])
        if let warning { details["error"] = warning }
        do {
            try await recorder.finish(discard: false)
            guard id == token, applicationRecorder === recorder, let video else { return }
            applicationRecorder = nil
            recordingSegments.append(video)
            if paused { update(.paused) }
            else { finishRecording() }
        } catch {
            guard id == token, applicationRecorder === recorder else { return }
            applicationRecorder = nil
            if recordingSegments.isEmpty { await fail(error); return }
            details["error"] = error.localizedDescription
            finishRecording()
        }
    }

    func setPaused(_ paused: Bool) async throws {
        if paused, phase == .scrolling {
            update(.pausing)
            return
        }
        if !paused, phase == .paused {
            if details["kind"] as? String == "scrolling" {
                autoScrollActive = autoScrollAvailable
                update(.scrolling)
                return
            }
            try await startRecordingSegment()
            return
        }
        if paused, phase == .recording, applicationRecorder != nil {
            await finishApplicationSegment(paused: true)
            return
        }
        guard paused, phase == .recording, let stream else {
            throw GIFExporter.ExportError(message: "当前采集状态不能切换暂停。")
        }
        let token = id
        clickOverlay.stop()
        if let startedAt { recordedElapsed += Date().timeIntervalSince(startedAt) }
        startedAt = nil
        timer?.invalidate()
        timer = nil
        update(.pausing, ["elapsed": recordedElapsed])
        do { try await stream.stopCapture() }
        catch {
            if token == id, self.stream === stream { await fail(error) }
            throw error
        }
    }

    func stop() async throws {
        if phase == .scrolling || (phase == .paused && details["kind"] as? String == "scrolling") {
            finishScroll = true
            update(.finalizing)
            return
        }
        if phase == .paused {
            finishRecording()
            return
        }
        if phase == .recording, applicationRecorder != nil {
            await finishApplicationSegment(paused: false)
            return
        }
        guard phase == .recording, let stream else { return }
        let token = id
        clickOverlay.stop()
        update(.finalizing)
        timer?.invalidate()
        timer = nil
        do { try await stream.stopCapture() }
        catch {
            if token == id, self.stream === stream { await fail(error) }
            throw error
        }
    }

    func cancel() async {
        let token = id
        let alreadyStopping = [.pausing, .finalizing].contains(phase)
        if let recorder = applicationRecorder {
            applicationRecorder = nil
            update(.finalizing)
            try? await recorder.finish(discard: true)
            guard id == token else { return }
        }
        if let exportTask {
            update(.finalizing)
            exportTask.cancel()
            await exportTask.value
            guard id == token else { return }
        }
        self.exportTask = nil
        scrollTask?.cancel()
        if let scrollTask {
            await scrollTask.value
            guard id == token else { return }
        }
        self.scrollTask = nil
        if let stream {
            discardRecording = true
            update(.finalizing)
            if !alreadyStopping {
                do { try await stream.stopCapture() }
                catch { if token == id { await fail(error) } }
            }
            if token == id, recordingOutput != nil {
                await withCheckedContinuation { recordingCompletionWaiters.append($0) }
            }
            if id == token { clear() }
            return
        }
        clear()
    }

    private func clear() {
        clickOverlay.stop()
        stopWatchingScrollTakeover()
        autoScrollAvailable = false
        autoScrollActive = false
        let waiters = recordingCompletionWaiters
        recordingCompletionWaiters = []
        timer?.invalidate()
        timer = nil
        stream = nil
        recordingOutput = nil
        video = nil
        recordingSegments = []
        recordingArguments = [:]
        applicationRecorder = nil
        applicationCanvas = nil
        applicationSegmentID = nil
        recordedElapsed = 0
        startedAt = nil
        captureFrame = nil
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
        details = [:]
        trim = nil
        id = UUID().uuidString
        onActiveChanged?(false)
        update(.idle)
        for waiter in waiters { waiter.resume() }
    }

    private func fail(_ error: Error) async {
        let token = id
        clickOverlay.stop()
        if let recorder = applicationRecorder {
            applicationRecorder = nil
            try? await recorder.finish(discard: true)
            guard id == token else { return }
        }
        let active = stream
        stream = nil
        recordingOutput = nil
        try? await active?.stopCapture()
        guard id == token else { return }
        clear()
        update(.failed, ["error": error.localizedDescription])
    }

    nonisolated func recordingOutputDidStartRecording(_ output: SCRecordingOutput) {
        let identity = ObjectIdentifier(output)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.recordingOutput.map(ObjectIdentifier.init) == identity, self.phase == .preparing else { return }
            self.startedAt = Date()
            self.clickOverlay.start(
                frame: self.captureFrame,
                preferences: AppPreferences.current,
                isApplicationTarget: self.recordingArguments["kind"] as? String == CaptureTarget.application.rawValue
            )
            self.update(.recording, ["elapsed": self.recordedElapsed])
            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.startedAt, self.phase == .recording else { return }
                    self.update(.recording, ["elapsed": self.recordedElapsed + Date().timeIntervalSince(start)])
                }
            }
        }
    }

    nonisolated func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.recordingOutput === output else { return }
            await self.fail(error)
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            guard let self, self.recordingOutput === output, let video = self.video else { return }
            self.stream = nil
            self.recordingOutput = nil
            self.clickOverlay.stop()
            self.timer?.invalidate()
            self.timer = nil
            if self.discardRecording { self.clear(); return }
            if let failure = self.recordingFailure {
                await self.fail(GIFExporter.ExportError(message: failure)); return
            }
            self.recordingSegments.append(video)
            if self.phase == .pausing {
                self.update(.paused)
                return
            }
            self.finishRecording()
        }
    }

    private func finishRecording() {
        let token = id
        let segments = recordingSegments
        let destination = temporaryDirectory!.appendingPathComponent("recording.mp4")
        update(.finalizing)
        exportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await Self.joinRecordingSegments(segments, destination: destination)
                try await self.publishFinishedRecording(result, token: token)
            } catch is CancellationError { return }
            catch { if self.id == token { await self.fail(error) } }
        }
    }

    func publishFinishedRecording(_ source: URL, token: String) async throws {
        try Task.checkCancellation()
        guard id == token else { return }
        let info = try await GIFExporter.metadata(source)
        try Task.checkCancellation()
        guard id == token else { return }
        video = source
        onActiveChanged?(false)
        update(.videoReady, ["duration": info.duration, "width": info.width, "height": info.height])
    }

    static func joinRecordingSegments(_ sources: [URL], destination: URL) async throws -> URL {
        guard let first = sources.first else { throw GIFExporter.ExportError(message: "没有可保留的录制内容。") }
        if sources.count == 1 { return first }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw GIFExporter.ExportError(message: "无法建立录制视频轨道。")
        }
        var cursor = CMTime.zero
        for url in sources {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else {
                throw GIFExporter.ExportError(message: "录制分段缺少视频轨道。")
            }
            let range = try await source.load(.timeRange)
            guard range.duration.isNumeric, range.duration > .zero else {
                throw GIFExporter.ExportError(message: "录制分段没有有效画面。")
            }
            if cursor == .zero { track.preferredTransform = try await source.load(.preferredTransform) }
            try track.insertTimeRange(range, of: source, at: cursor)
            cursor = CMTimeAdd(cursor, range.duration)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw GIFExporter.ExportError(message: "无法完成录制分段合并。")
        }
        try await exporter.export(to: destination, as: .mp4)
        try Task.checkCancellation()
        return destination
    }

    nonisolated func stream(_ stopped: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stopped else { return }
            self.recordingFailure = error.localizedDescription
            await self.fail(error)
        }
    }

    func startScrolling() async throws {
        try begin()
        let token = id
        details["kind"] = "scrolling"
        do {
            guard let region else { throw GIFExporter.ExportError(message: "请先明确框选长截图区域。") }
            let (filter, config) = try await configuration(["kind": CaptureTarget.region.rawValue], video: false)
            guard token == id else { throw CancellationError() }
            let edges = region.edges
            let pointScale = region.scale
            guard edges.top >= 0, edges.bottom >= 0, edges.top <= config.height - 64,
                  edges.bottom <= config.height - 64 - edges.top else {
                throw GIFExporter.ExportError(message: "固定区域须为非负整数，正文至少保留64像素。")
            }
            let stitcher = ScrollStitcher(edges: edges)
            finishScroll = false
            let automatic = AppPreferences.current[
                AppConstants.scrollCaptureModeKey
            ] as? String == ScrollCaptureMode.automatic.rawValue
            autoScrollAvailable = automatic
            autoScrollActive = automatic
            scrollHintSerial = 0
            if automatic { watchScrollTakeover() }
            let center = CaptureGeometry.cgPoint(fromAppKitPoint: NSPoint(x: captureFrame!.midX, y: captureFrame!.midY))
            update(.scrolling, ["height": config.height, "width": config.width, "frames": 0])
            scrollTask = Task.detached { [weak self] in
                guard let self else { return }
                var warning: String?
                var unmatched: String?
                var lastHint: ContinuousClock.Instant?
                var plan = AutoScrollPlan(height: config.height)
                var target: AutoScrollTarget?
                var driving = false
                var previousValue: Double?
                var keys: AutoScrollKeys?
                var barRejected = false
                var previewFrames = 0
                var previewMarked = false
                let clock = ContinuousClock()
                do {
                    while !Task.isCancelled {
                        let state = await MainActor.run {
                            if self.phase == .pausing { self.update(.paused) }
                            return (self.finishScroll, self.phase == .paused, self.autoScrollActive)
                        }
                        if state.0 { break }
                        if state.1 || !state.2 { driving = false }
                        if state.1 {
                            try await Task.sleep(for: .milliseconds(100))
                            continue
                        }
                        let nextCapture = clock.now.advanced(by: .milliseconds(100))
                        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                        try Task.checkCancellation()
                        let accept = await MainActor.run { self.id == token && self.phase == .scrolling }
                        if accept {
                            var hint: (text: String, isError: Bool)?
                            var action = AutoScrollPlan.Action.wait
                            let heightBefore = stitcher.height
                            let framesBefore = stitcher.acceptedFrames
                            do {
                                if try stitcher.append(image), !driving, stitcher.lastShiftRatio > 0.6 {
                                    hint = ("滚动较快，请放慢", false)
                                }
                                unmatched = nil
                                if driving { action = plan.frame(shift: framesBefore > 0 ? stitcher.height - heightBefore : 0, now: clock.now) }
                            } catch let failure as ScrollStitcher.Failure where failure.recoverable {
                                unmatched = failure.message
                                if driving { action = plan.mismatch(now: clock.now) }
                                else { hint = ("请往回滚，直到右下角红框里的内容回到选区", true) }
                            }
                            if hint != nil, let last = lastHint, clock.now - last < .milliseconds(1000) { hint = nil }
                            if hint != nil { lastHint = clock.now }
                            let shown = hint
                            var preview: ScrollStitcher.Preview?
                            let marked = unmatched != nil && !driving
                            if stitcher.acceptedFrames != previewFrames || marked != previewMarked {
                                previewFrames = stitcher.acceptedFrames
                                previewMarked = marked
                                preview = stitcher.preview(
                                    width: Int(((AppConstants.scrollPreviewWidth - AppConstants.scrollPreviewInset * 2) * pointScale).rounded()),
                                    maxHeight: Int((AppConstants.scrollPreviewMaxImageHeight * pointScale).rounded()),
                                    markTarget: previewMarked)
                            }
                            let thumbnail = preview
                            await MainActor.run {
                                guard self.id == token else { return }
                                var values: [String: Any] = ["height": stitcher.height, "frames": stitcher.acceptedFrames]
                                if let shown {
                                    self.scrollHintSerial += 1
                                    values["hint"] = shown.text
                                    values["hintIsError"] = shown.isError
                                    values["hintSerial"] = self.scrollHintSerial
                                }
                                if let thumbnail { self.onScrollPreview?(thumbnail, pointScale) }
                                self.update(self.phase, values)
                            }
                            if state.2, !driving, stitcher.acceptedFrames > 0 {
                                let trusted = AXIsProcessTrusted()
                                if target == nil, keys == nil, !barRejected, trusted { target = AutoScrollTarget(point: center) }
                                if target == nil, keys == nil, trusted,
                                   let pid = AutoScrollTarget.sourceProcess(at: center) {
                                    keys = AutoScrollKeys(pid: pid)
                                    plan = .keys(height: config.height)
                                }
                                if let target {
                                    driving = true
                                    action = (target.value ?? 0) >= 0.999 ? .bottom : plan.start(now: clock.now)
                                } else if keys != nil {
                                    driving = true
                                    action = plan.start(now: clock.now)
                                } else {
                                    await self.endAutoScroll(token: token, hint: trusted
                                        ? MediaCaptureService.unsupportedScrollHint : "自动滚动需要辅助功能权限，已改为手动滚动")
                                }
                            }
                            switch action {
                            case .wait:
                                break
                            case .scroll(let step):
                                if keys != nil {
                                    if keys?.scroll(by: step) != true {
                                        driving = false
                                        await self.endAutoScroll(token: token, hint: MediaCaptureService.unsupportedScrollHint)
                                    }
                                    break
                                }
                                previousValue = target?.value
                                guard let target, let previousValue, target.set(previousValue + step) else {
                                    driving = false
                                    target = nil
                                    barRejected = true
                                    break
                                }
                            case .rewind:
                                if let keys {
                                    if !keys.rewind() {
                                        driving = false
                                        await self.endAutoScroll(token: token, hint: MediaCaptureService.unsupportedScrollHint)
                                    }
                                    break
                                }
                                guard let target, let previousValue, target.set(previousValue) else {
                                    driving = false
                                    await self.endAutoScroll(token: token, hint: MediaCaptureService.unsupportedScrollHint)
                                    break
                                }
                            case .bottom:
                                driving = false
                                await MainActor.run {
                                    guard self.id == token, self.phase == .scrolling else { return }
                                    self.showScrollHint("已到底部，已暂停", isError: false, phase: .paused)
                                }
                            case .unsupported:
                                driving = false
                                if target != nil {
                                    target = nil
                                    barRejected = true
                                } else {
                                    await self.endAutoScroll(token: token, hint: MediaCaptureService.unsupportedScrollHint)
                                }
                            }
                        }
                        if clock.now < nextCapture { try await clock.sleep(until: nextCapture) }
                    }
                } catch is CancellationError { return }
                catch { warning = error.localizedDescription }
                warning = warning ?? unmatched
                guard !Task.isCancelled else { return }
                let delivered: (png: Data, width: Int, height: Int, frames: Int)?
                do {
                    let result = try stitcher.finish()
                    if result.frames < 2 && warning == nil { warning = "未检测到有效滚动，当前结果只有一屏。" }
                    delivered = result
                } catch {
                    warning = warning ?? error.localizedDescription
                    delivered = stitcher.acceptedFrames > 0 ? try? stitcher.confirmedFrame() : nil
                }
                let note = warning
                let image = delivered
                await MainActor.run {
                    self.publishFinishedScroll(png: image?.png, width: image?.width ?? 0, height: image?.height ?? 0,
                        frames: image?.frames ?? 0, failure: note, token: token)
                }
            }
        } catch { if token == id { await fail(error) }; throw error }
    }

    func publishFinishedScroll(png: Data?, width: Int, height: Int, frames: Int, failure: String?, token: String) {
        guard id == token else { return }
        stopWatchingScrollTakeover()
        onActiveChanged?(false)
        guard let png else {
            update(.failed, ["error": failure ?? "无法完成长截图。"])
            return
        }
        var values: [String: Any] = ["imageBytes": FlutterStandardTypedData(bytes: png),
            "width": width, "height": height, "frames": frames, "kind": "scrolling"]
        if let failure { values["warning"] = failure }
        update(.imageReady, values)
    }

    private func showScrollHint(_ text: String, isError: Bool, phase target: CapturePhase? = nil) {
        scrollHintSerial += 1
        update(target ?? phase, ["hint": text, "hintIsError": isError, "hintSerial": scrollHintSerial])
    }

    private static let unsupportedScrollHint = "该区域无法自动滚动，已改为手动滚动"

    private func endAutoScroll(token: String, hint: String) {
        guard id == token else { return }
        autoScrollAvailable = false
        autoScrollActive = false
        stopWatchingScrollTakeover()
        showScrollHint(hint, isError: true)
    }

    private func watchScrollTakeover() {
        scrollWheelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, self.autoScrollActive, self.phase == .scrolling,
                      self.captureFrame?.contains(location) == true else { return }
                self.autoScrollActive = false
                self.showScrollHint("已切换为手动滚动", isError: false)
            }
        }
    }

    private func stopWatchingScrollTakeover() {
        if let scrollWheelMonitor { NSEvent.removeMonitor(scrollWheelMonitor) }
        scrollWheelMonitor = nil
    }

    func noteSavedScroll(_ path: String) {
        guard phase == .imageReady else { return }
        update(.imageReady, ["savedPath": path])
    }

    func recordingURL() throws -> URL {
        guard phase == .videoReady, let video else { throw GIFExporter.ExportError(message: "请先完成录制。") }
        return video
    }

    func previewURL() throws -> URL {
        guard [.videoReady, .converting].contains(phase), let video else {
            throw GIFExporter.ExportError(message: "当前没有可预览的录制。")
        }
        return video
    }

    func setTrim(_ range: CMTimeRange?) throws {
        _ = try recordingURL()
        trim = range
    }

    func saveVideo(to target: URL) throws {
        let source = try recordingURL()
        guard let trim else {
            try convert(.mp4, source: source, to: target, pathKey: "savedPath")
            return
        }
        try convert(.mp4, source: source, to: target, pathKey: "savedPath") { destination, progress in
            try await Self.trimVideo(source: source, range: trim, destination: destination, progress: progress)
        }
    }

    static func trimVideo(source: URL, range: CMTimeRange, destination: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source),
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw GIFExporter.ExportError(message: "无法创建视频导出，请重试。")
        }
        session.timeRange = range
        let observer = Task {
            for await state in session.states(updateInterval: 0.1) {
                if case .exporting(let value) = state { progress(value.fractionCompleted) }
            }
        }
        defer { observer.cancel() }
        try await session.export(to: destination, as: .mp4)
    }

    func exportAnimation(_ format: GIFExporter.Format, options: GIFExporter.Options, to target: URL) throws {
        let source = try recordingURL()
        let range = trim
        try convert(format.kind, source: source, to: target, pathKey: format.pathKey) { destination, progress in
            _ = try await GIFExporter.export(source: source, destination: destination, options: options,
                                             format: format, range: range, progress: progress)
        }
    }

    func exportWebM(to target: URL) throws {
        let source = try recordingURL()
        let range = trim
        try convert(.webm, source: source, to: target, pathKey: "webmPath") { destination, progress in
            _ = try await WebMExporter.export(source: source, destination: destination, range: range, progress: progress)
        }
    }

    private func convert(_ kind: RecordingExport, source: URL, to target: URL, pathKey: String,
                         work: (@Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> Void)? = nil) throws {
        let token = id
        let destination: URL
        if work != nil {
            guard let temporaryDirectory else { throw GIFExporter.ExportError(message: "录制会话已失效。") }
            destination = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).\(kind.fileExtension)")
        } else {
            destination = source
        }
        details.removeValue(forKey: "error")
        details.removeValue(forKey: "progress")
        var values: [String: Any] = ["exporting": kind.rawValue]
        if work != nil { values["progress"] = 0.0 }
        update(.converting, values)
        exportTask = Task.detached { [weak self] in
            guard let self else { return }
            defer { if work != nil { try? FileManager.default.removeItem(at: destination) } }
            let outcome: (key: String, value: String)
            do {
                if let work {
                    try await work(destination) { progress in
                        DispatchQueue.main.async {
                            guard self.id == token, self.phase == .converting else { return }
                            self.update(.converting, ["progress": progress])
                        }
                    }
                }
                try Task.checkCancellation()
                outcome = (pathKey, try ScreenshotStorage.publish(source: destination, target: target).path)
            } catch {
                let cancelled = work == nil ? "保存已取消，源视频保持不变。" : "转换已取消，源视频保持不变。"
                outcome = ("error", error is CancellationError ? cancelled : error.localizedDescription)
            }
            await MainActor.run {
                guard self.id == token, self.phase == .converting else { return }
                self.details.removeValue(forKey: "exporting")
                self.update(.videoReady, [outcome.key: outcome.value])
            }
        }
    }

    func cancelExport() { exportTask?.cancel() }
}
