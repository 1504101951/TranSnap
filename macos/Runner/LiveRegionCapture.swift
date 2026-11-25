import AppKit
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

private struct LiveCaptureSlice: @unchecked Sendable {
    let filter: SCContentFilter
    let config: SCStreamConfiguration
    let bounds: NSRect
}

@MainActor
final class LiveRegionCapture {
    var onRecognized: ((Int, [[String: Any]]?, String?) -> Void)?
    var onUnavailable: ((String) -> Void)?
    var onFrame: ((NSRect) -> Void)?

    private let background = CGColor(gray: 0, alpha: 1)
    private var slot = LiveOcrSlot()
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
        slot.adopt(generation)
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
            while !Task.isCancelled {
                let started = clock.now
                let nextCapture = started.advanced(by: .milliseconds(AppConstants.liveCaptureMinIntervalMs))
                var pixels = 0.0
                do {
                    var blocks: [[String: Any]] = []
                    for slice in slices {
                        try Task.checkCancellation()
                        let image = try await SCScreenshotManager.captureImage(
                            contentFilter: slice.filter,
                            configuration: slice.config
                        )
                        try Task.checkCancellation()
                        let found = try await ScreenCaptureService.recognizeParagraphs(image: image)
                        let pixelWidth = Double(image.width)
                        let pixelHeight = Double(image.height)
                        guard pixelWidth > 0, pixelHeight > 0 else { continue }
                        pixels += pixelWidth * pixelHeight
                        for item in found {
                            guard let text = item["text"] as? String,
                                  let x = item["x"] as? Double,
                                  let y = item["y"] as? Double,
                                  let width = item["width"] as? Double,
                                  let height = item["height"] as? Double else { continue }
                            let rect = NSRect(
                                x: slice.bounds.minX + x / pixelWidth * slice.bounds.width,
                                y: slice.bounds.maxY - (y + height) / pixelHeight * slice.bounds.height,
                                width: width / pixelWidth * slice.bounds.width,
                                height: height / pixelHeight * slice.bounds.height
                            )
                            blocks.append([
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
                    let elapsed = started.duration(to: clock.now).components
                    let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
                    LiveRegionLog.note("ocr ms=\(Int(milliseconds)) pixels=\(Int(pixels)) paragraphs=\(blocks.count)")
                    let active = await MainActor.run { [weak self] () -> Bool in
                        guard let self,
                              generation == self.slot.acceptedGeneration,
                              self.running else { return false }
                        self.onRecognized?(generation, blocks, nil)
                        return true
                    }
                    guard active else { break }
                } catch is CancellationError {
                    break
                } catch {
                    let active = await MainActor.run { [weak self] () -> Bool in
                        guard let self,
                              generation == self.slot.acceptedGeneration,
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

    func pause(generation: Int) async {
        slot.adopt(generation)
        running = false
        captureTask?.cancel()
        captureTask = nil
    }

    func resume(source: [String: Any], region: MediaCaptureService.Region?, generation: Int) async throws {
        try await start(source: source, region: region, generation: generation)
    }

    func stop() async {
        running = false
        slot.adopt(slot.acceptedGeneration + 1)
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
