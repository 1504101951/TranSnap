import AppKit
import ScreenCaptureKit

private struct LiveCaptureSlice: @unchecked Sendable {
    let filter: SCContentFilter
    let config: SCStreamConfiguration
    let bounds: NSRect
}

@MainActor
final class LiveRegionCapture {
    var onRecognized: ((Int, [ScreenCaptureService.OCRBlock]?, String?) -> Void)?
    var onUnavailable: ((String) -> Void)?
    var onFrame: ((NSRect) -> Void)?

    private let background = CGColor(gray: 0, alpha: 1)
    private var acceptedGeneration = 0
    private var captureTask: Task<Void, Never>?
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
        captureTask?.cancel()
        captureTask = nil
        acceptedGeneration = generation
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let kind = source["kind"] as? String else {
            throw GIFExporter.ExportError(message: "缺少采集方式。")
        }
        let built = try build(kind: kind, source: source, region: region, content: content)
        targetDisplayID = built.displayID
        onFrame?(built.shade)
        running = true
        observeSystem()
        let slices = built.slices
        captureTask = Task.detached { [weak self] in
            let clock = ContinuousClock()
            var recognizedFrames: [Data]?
            while !Task.isCancelled {
                let started = clock.now
                let nextCapture = started.advanced(by: .milliseconds(AppConstants.liveCaptureMinIntervalMs))
                do {
                    var captured: [(slice: LiveCaptureSlice, image: CGImage)] = []
                    for slice in slices {
                        try Task.checkCancellation()
                        let image = try await SCScreenshotManager.captureImage(
                            contentFilter: slice.filter,
                            configuration: slice.config
                        )
                        guard image.width > 0, image.height > 0 else { continue }
                        captured.append((slice, image))
                    }
                    try Task.checkCancellation()
                    let frames = captured.compactMap { $0.image.dataProvider?.data as Data? }
                    let unchanged = frames.count == captured.count && frames == recognizedFrames
                    if !unchanged {
                        var blocks: [ScreenCaptureService.OCRBlock] = []
                        var pixels = 0
                        for (slice, image) in captured {
                            try Task.checkCancellation()
                            let found = try await ScreenCaptureService.recognizeParagraphs(image: image)
                            pixels += image.width * image.height
                            blocks += Self.screenBlocks(
                                found,
                                pixelSize: CGSize(width: image.width, height: image.height),
                                bounds: slice.bounds
                            )
                        }
                        let ordered = Self.readingOrder(blocks)
                        let elapsed = started.duration(to: clock.now).components
                        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                        LiveRegionLog.note("ocr ms=\(Int(milliseconds)) pixels=\(pixels) paragraphs=\(ordered.count)")
                        let active = await MainActor.run { [weak self] () -> Bool in
                            guard let self,
                                  generation == self.acceptedGeneration,
                                  self.running else { return false }
                            self.onRecognized?(generation, ordered, nil)
                            return true
                        }
                        guard active else { break }
                        recognizedFrames = frames
                    }
                } catch is CancellationError {
                    break
                } catch {
                    recognizedFrames = nil
                    let active = await MainActor.run { [weak self] () -> Bool in
                        guard let self,
                              generation == self.acceptedGeneration,
                              self.running else { return false }
                        self.onRecognized?(generation, nil, error.localizedDescription)
                        return true
                    }
                    guard active else { break }
                }
                let remaining = clock.now.duration(to: nextCapture)
                if remaining > .zero {
                    do {
                        try await Task.sleep(for: remaining)
                    } catch {
                        break
                    }
                }
            }
        }
    }

    nonisolated static func screenBlocks(
        _ found: [ScreenCaptureService.OCRBlock],
        pixelSize: CGSize,
        bounds: NSRect
    ) -> [ScreenCaptureService.OCRBlock] {
        let scaleX = bounds.width / pixelSize.width
        let scaleY = bounds.height / pixelSize.height
        let screen = { (rect: CGRect) in
            NSRect(
                x: bounds.minX + rect.minX * scaleX,
                y: bounds.maxY - rect.maxY * scaleY,
                width: rect.width * scaleX,
                height: rect.height * scaleY
            )
        }
        return found.map { block in
            ScreenCaptureService.OCRBlock(
                text: block.text,
                rect: screen(block.rect),
                segments: block.segments.map {
                    ScreenCaptureService.OCRSegment(start: $0.start, end: $0.end, rect: screen($0.rect))
                }
            )
        }
    }

    nonisolated static func readingOrder(_ blocks: [ScreenCaptureService.OCRBlock]) -> [ScreenCaptureService.OCRBlock] {
        blocks.sorted { lhs, rhs in
            if abs(lhs.rect.maxY - rhs.rect.maxY) > 1 { return lhs.rect.maxY > rhs.rect.maxY }
            return lhs.rect.minX < rhs.rect.minX
        }
    }

    func pause(generation: Int) async {
        acceptedGeneration = generation
        running = false
        captureTask?.cancel()
        captureTask = nil
    }

    func resume(source: [String: Any], region: MediaCaptureService.Region?, generation: Int) async throws {
        try await start(source: source, region: region, generation: generation)
    }

    func stop() async {
        running = false
        acceptedGeneration += 1
        captureTask?.cancel()
        captureTask = nil
        removeObservers()
    }

    private func fail(_ message: String) {
        guard running else { return }
        running = false
        captureTask?.cancel()
        captureTask = nil
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

    private func build(
        kind: String,
        source: [String: Any],
        region: MediaCaptureService.Region?,
        content: SCShareableContent
    ) throws -> (slices: [LiveCaptureSlice], shade: NSRect, displayID: CGDirectDisplayID) {
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
            var slices: [LiveCaptureSlice] = []
            for (display, filter) in filters {
                filter.includeMenuBar = false
                let config = baseConfig(
                    width: max(1, Int((display.frame.width * CGFloat(filter.pointPixelScale)).rounded())),
                    height: max(1, Int((display.frame.height * CGFloat(filter.pointPixelScale)).rounded()))
                )
                config.backgroundColor = background
                slices.append(
                    LiveCaptureSlice(
                        filter: filter,
                        config: config,
                        bounds: CaptureGeometry.appKitRect(fromCGWindowBounds: display.frame)
                    )
                )
            }
            let sourceID = (source["sourceID"] as? NSNumber)?.uint32Value ?? filters[0].0.displayID
            return (slices, CaptureGeometry.appKitRect(fromCGWindowBounds: canvas.bounds), sourceID)
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
        let config = baseConfig(width: width, height: height)
        if let crop { config.sourceRect = crop }
        var target = display.frame
        let actual = crop ?? CGRect(origin: .zero, size: filter.contentRect.size)
        target.origin.x += actual.minX
        target.origin.y += actual.minY
        target.size = actual.size
        let bounds = CaptureGeometry.appKitRect(fromCGWindowBounds: target)
        return ([LiveCaptureSlice(filter: filter, config: config, bounds: bounds)], bounds, display.displayID)
    }

    private func baseConfig(width: Int, height: Int) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.showsCursor = false
        config.capturesAudio = false
        config.captureMicrophone = false
        config.scalesToFit = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }
}
