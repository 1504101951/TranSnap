import AppKit
import AVKit
import FlutterMacOS
import QuartzCore

@MainActor
final class CaptureWindowController: NSObject, NSWindowDelegate {
    let service = MediaCaptureService()
    private let screenshot: ScreenshotWindowController
    private var engine: FlutterEngine?
    private var channel: FlutterMethodChannel?
    private var pendingStartup: WindowEngine.Startup?
    private var window: NSWindow?
    private var player: AVPlayer?
    private weak var playerView: AVPlayerView?
    private var playerSession: String?
    private var playerTimeObserver: Any?
    private var playerEndObserver: NSObjectProtocol?
    private var playerStatusObservation: NSKeyValueObservation?
    private var preparingScreenshot = false
    private var shuttingDown = false
    private var discarding = false
    private var compactPresentation: Bool?
    private var lastPhase = CapturePhase.idle
    private var originScreen: NSScreen?
    private var captureShades: [CGDirectDisplayID: NSWindow] = [:]
    var onActiveChanged: ((Bool) -> Void)?
    var onLivePause: ((Bool) -> Void)?
    var onLiveStop: (() -> Void)?
    var onLiveCancel: (() -> Void)?
    private var liveControlID: String?
    private var livePaused = false
    private var liveDetail = ""
    private var liveShadeFrame: NSRect?
    private var shownScrollHint: String?
    private var scrollPreviewWindow: NSPanel?

    var canStop: Bool {
        liveControlID != nil || service.isCountingDown || [.recording, .scrolling, .paused].contains(service.phase)
    }

    func cancelCountdown() {
        guard service.isCountingDown else { return }
        preparingScreenshot = false
        Task { @MainActor in await discard() }
    }

    var hasPendingCapture: Bool { discarding || ![.idle, .failed].contains(service.phase) }

    init(screenshot: ScreenshotWindowController) {
        self.screenshot = screenshot
        super.init()
        service.onChange = { [weak self] _ in
            guard let self else { return }
            let started = ContinuousClock.now
            let transition = self.service.phase != self.lastPhase
            let phase = self.service.phase
            let preparationFinished = [.recording, .scrolling, .failed].contains(self.service.phase)
                || (self.service.phase == .idle && self.lastPhase == .preparing)
            if self.preparingScreenshot && preparationFinished {
                self.preparingScreenshot = false
                if [.recording, .scrolling].contains(self.service.phase) { self.screenshot.closeForCapture() }
                else if !self.shuttingDown { self.screenshot.restoreAfterCapturePreparation() }
            }
            StatusBarController.shared.showCountdown(self.service.snapshot()["countdown"] as? Int)
            self.present()
            self.showScrollHintIfNeeded()
            if phase != .preparing {
                self.channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: self.captureState())
            }
            if transition && [.preparing, .recording].contains(phase) {
                CaptureStartupLog.record("ui-\(phase.rawValue)-sync", since: started)
            }
        }
        service.onActiveChanged = { [weak self] active in self?.onActiveChanged?(active) }
        service.onScrollPreview = { [weak self] preview, scale in self?.showScrollPreview(preview, scale: scale) }
    }

    func shutdown() async {
        shuttingDown = true
        pendingStartup?.cancel()
        pendingStartup = nil
        updateCaptureShades()
        screenshot.cancelCapture()
        releasePlayer()
        await service.cancel()
        window?.delegate = nil
        window?.close()
        DockPresence.leave(self)
        channel?.setMethodCallHandler(nil)
        engine?.shutDownEngine()
        engine = nil
        channel = nil
        window = nil
    }

    func prepare(source: [String: Any], scrolling: Bool, region: MediaCaptureService.Region?) throws {
        guard !shuttingDown, !hasPendingCapture else {
            throw GIFExporter.ExportError(message: "请先结束或放弃当前采集。")
        }
        guard source["kind"] as? String != CaptureTarget.region.rawValue || region != nil else {
            throw GIFExporter.ExportError(message: "请先选择有效录制区域。")
        }
        start(source, scrolling: scrolling, region: region)
    }

    func sources(preferredApplicationID: String?) async throws -> [[String: Any]] {
        try await service.sources(preferredApplicationID: preferredApplicationID)
    }

    func prepareControls() {
        guard !shuttingDown else { return }
        createPanel()
    }

    private func start(_ source: [String: Any], scrolling: Bool, region: MediaCaptureService.Region? = nil) {
        let token = service.id
        guard let screenshotID = screenshot.liveCaptureID else { return }
        Task { @MainActor in
            guard !shuttingDown, token == service.id, !hasPendingCapture,
                  screenshotID == screenshot.liveCaptureID else { return }
            do {
                if let region { try service.select(region) }
                preparingScreenshot = true
                screenshot.hideForCapture()
                if let id = source["sourceID"] as? NSNumber {
                    originScreen = NSScreen.screens.first { $0.displayID == id.uint32Value }
                }
                if scrolling { try await service.startScrolling() }
                else { try await service.startRecording(source, delay: source["delay"] as! Int) }
            } catch is CancellationError {
            } catch {
                if preparingScreenshot {
                    preparingScreenshot = false
                    screenshot.restoreAfterCapturePreparation()
                }
                if service.phase != .failed { showError(error) }
            }
        }
    }

    private func createPanel() {
        guard window == nil, pendingStartup == nil, !shuttingDown, !discarding else { return }
        let started = ContinuousClock.now
        defer { CaptureStartupLog.record("capture-ui-create-sync", since: started) }
        pendingStartup = WindowEngine.start(
            name: AppConstants.captureEntrypoint, entrypoint: AppConstants.captureEntrypoint,
            channel: AppConstants.captureChannel,
            handler: { [weak self] call, result in self?.handle(call, result: result) },
            completion: { [weak self] started in
                guard let self else { return }
                self.pendingStartup = nil
                guard let started else {
                    self.discarding = true
                    if self.liveControlID != nil {
                        self.onLiveCancel?()
                        self.hideLiveControls()
                        self.setLiveShade(nil)
                    }
                    Task { @MainActor in
                        self.releasePlayer()
                        await self.service.cancel()
                        if self.preparingScreenshot {
                            self.preparingScreenshot = false
                            if !self.shuttingDown { self.screenshot.restoreAfterCapturePreparation() }
                        }
                        self.discarding = false
                        self.present()
                        guard !self.shuttingDown else { return }
                        WindowEngine.reportStartFailure("采集窗口")
                    }
                    return
                }
                self.engine = started.engine
                self.channel = started.channel
                let flutter = started.flutter
                flutter.registrar(forPlugin: "CaptureVideoPreview").register(
                    CapturePreviewFactory(owner: self), withId: AppConstants.captureVideoPreview)
                let panel = Self.makeWindow(compact: true)
                panel.delegate = self
                NativeGlassFactory.installContent(flutter, in: panel)
                self.window = panel
                self.present()
                self.channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: self.captureState())
            })
    }

    static func makeWindow(compact: Bool) -> NSWindow {
        let frame = NSRect(origin: .zero, size: AppConstants.captureControlSize)
        let window: NSWindow
        if compact {
            let panel = CaptureControlPanel(contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            panel.becomesKeyOnlyIfNeeded = true
            panel.identifier = AppConstants.captureControlWindowIdentifier
            window = panel
        } else {
            window = NSWindow(contentRect: frame, styleMask: AppConstants.captureResultWindowStyle,
                backing: .buffered, defer: false)
            window.title = "录制结果"
            window.contentMinSize = AppConstants.recordingResultMinimumSize
        }
        window.isReleasedWhenClosed = false
        window.isOpaque = !compact
        window.backgroundColor = compact ? .clear : .windowBackgroundColor
        window.hasShadow = !compact
        window.hidesOnDeactivate = false
        window.level = compact ? .statusBar : .normal
        window.collectionBehavior = compact ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.fullScreenPrimary]
        return window
    }

    static func resultFrame(pixels: NSSize, scale: CGFloat, visible: NSRect) -> NSRect {
        let logical = NSSize(width: pixels.width / scale, height: pixels.height / scale)
        let available = NSWindow.contentRect(forFrameRect: visible, styleMask: AppConstants.captureResultWindowStyle).size
        let reservedWidth = AppConstants.resultWindowCanvasPadding * 2
        let reservedHeight = AppConstants.resultWindowCanvasPadding * 2 + AppConstants.resultWindowBarHeight
        let fit = min(1, min((available.width - reservedWidth) / logical.width,
                             (available.height - reservedHeight) / logical.height))
        let contentSize = NSSize(
            width: min(available.width, max(logical.width * fit + reservedWidth, AppConstants.recordingResultMinimumSize.width)),
            height: min(available.height, max(logical.height * fit + reservedHeight, AppConstants.recordingResultMinimumSize.height)))
        let frame = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: AppConstants.captureResultWindowStyle)
        let size = NSSize(width: min(visible.width, frame.width), height: min(visible.height, frame.height))
        return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    private func captureState() -> [String: Any] {
        if let liveControlID {
            let recording = [.preparing, .recording, .pausing, .paused].contains(service.phase)
            return [
                "id": liveControlID,
                "phase": livePaused ? CapturePhase.paused.rawValue : CapturePhase.recording.rawValue,
                "kind": "liveTranslation",
                "recording": recording,
                "elapsed": recording ? service.snapshot()["elapsed"] ?? 0 : 0,
                "detail": liveDetail,
                "previewScale": originScreen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1,
            ]
        }
        var state = service.snapshot()
        state["previewScale"] = originScreen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        if [.videoReady, .converting].contains(service.phase) {
            state["playing"] = player?.timeControlStatus == .playing
            state["position"] = currentPlaybackPosition()
        }
        return state
    }

    func showLiveControls(id: String, screen: NSScreen?) {
        liveControlID = id
        livePaused = false
        if let screen { originScreen = screen }
        present()
    }

    func setLiveDetail(_ text: String) {
        guard liveControlID != nil, liveDetail != text else { return }
        liveDetail = text
        channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: captureState())
    }

    func setLivePaused(_ paused: Bool) {
        guard liveControlID != nil else { return }
        livePaused = paused
        channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: captureState())
    }

    func hideLiveControls() {
        liveControlID = nil
        livePaused = false
        liveDetail = ""
        present()
        channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: captureState())
    }

    func setLiveShade(_ frame: NSRect?) {
        liveShadeFrame = frame
        updateCaptureShades()
    }

    func present(force: Bool = false) {
        guard !shuttingDown, !discarding else { return }
        let previous = lastPhase
        let live = liveControlID != nil
        if !(live && service.phase == .failed) { lastPhase = service.phase }
        let showingResult = !live && [.videoReady, .converting, .imageReady].contains(service.phase)
        if !showingResult { updateCaptureShades() }
        if !live, [.idle, .failed].contains(service.phase) {
            window?.orderOut(nil)
            compactPresentation = nil
            releasePlayer()
            if previous != service.phase, service.phase == .failed, let message = service.snapshot()["error"] as? String {
                let alert = NSObject()
                DockPresence.enter(alert)
                NSApp.activate(ignoringOtherApps: true)
                showError(GIFExporter.ExportError(message: message))
                DockPresence.leave(alert)
            }
            DockPresence.leave(self)
            return
        }
        createPanel()
        guard pendingStartup == nil else { return }
        let compact = live || [.preparing, .recording, .scrolling, .pausing, .paused, .finalizing].contains(service.phase)
        if let old = window, old.styleMask.contains(.nonactivatingPanel) != compact {
            let content = old.contentViewController
            old.contentViewController = nil
            old.delegate = nil
            old.close()
            let replacement = Self.makeWindow(compact: compact)
            replacement.contentViewController = content
            replacement.delegate = self
            NativeGlassFactory.applyAppearance(to: replacement)
            window = replacement
        }
        guard let window else { return }
        let changed = compactPresentation != compact
        let controlSize = AppConstants.captureControlSize
        let sizeChanged = compact && window.contentView?.frame.size != controlSize
        if changed {
            compactPresentation = compact
            (window.contentViewController as? NativeGlassWindowContent)?.windowCanvas.isHidden = compact
        }
        if live || service.phase == .preparing {
            channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: captureState())
        }
        if !compact { applyResultChrome(to: window) }
        if changed || sizeChanged {
            if compact { window.setContentSize(controlSize) }
            else if let screen = originScreen ?? NSScreen.main {
                let state = service.snapshot()
                guard let width = state["width"] as? Int, let height = state["height"] as? Int else { return }
                let pixels = NSSize(width: width, height: height)
                let visible = screen.visibleFrame
                let frame = service.phase == .imageReady
                    ? ScreenshotWindowController.imageResultFrame(pixels: pixels, scale: screen.backingScaleFactor, visible: visible)
                    : Self.resultFrame(pixels: pixels, scale: screen.backingScaleFactor, visible: visible)
                window.setFrame(frame, display: true)
            }
        }
        if compact {
            placeControls()
            window.orderFrontRegardless()
        } else if changed || force {
            orderResultFront(window)
        }
        if showingResult { updateCaptureShades() }
    }

    private func orderResultFront(_ window: NSWindow) {
        DockPresence.enter(self)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func applyResultChrome(to window: NSWindow) {
        let state = service.snapshot()
        let image = service.phase == .imageReady
        if let width = state["width"] as? Int, let height = state["height"] as? Int {
            if image {
                window.title = "长截图 · \(width) × \(height)"
            } else {
                let duration = (state["duration"] as? Double) ?? 0
                window.title = "录制 · \(Self.formattedDuration(duration)) · \(width) × \(height)"
            }
        } else {
            window.title = image ? "长截图结果" : "录制结果"
        }
        window.contentMinSize = image ? AppConstants.longScreenshotResultMinimumSize : AppConstants.recordingResultMinimumSize
    }

    private static func formattedDuration(_ seconds: Double) -> String {
        let total = Int(floor(max(0, seconds.isFinite ? seconds : 0)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func placeControls() {
        guard let window, let screen = originScreen ?? NSScreen.main else { return }
        window.setFrameOrigin(Self.controlOrigin(visible: screen.visibleFrame, size: window.frame.size))
    }

    static func controlOrigin(visible: NSRect, size: NSSize) -> NSPoint {
        NSPoint(x: max(visible.minX, visible.maxX - size.width - AppConstants.captureControlGap),
                y: visible.minY + AppConstants.captureControlGap)
    }

    private func showScrollHintIfNeeded() {
        let state = service.snapshot()
        guard [.scrolling, .paused].contains(service.phase), let serial = state["hintSerial"] as? Int,
              let text = state["hint"] as? String, let frame = service.captureFrame else { return }
        let key = "\(state["id"] as? String ?? "")#\(serial)"
        guard key != shownScrollHint else { return }
        shownScrollHint = key
        let center = NSPoint(x: frame.midX, y: frame.midY)
        guard let shade = captureShades.values.first(where: { $0.frame.contains(center) }) ?? captureShades.values.first,
              let view = shade.contentView as? CaptureShadeView,
              let screen = NSScreen.screens.first(where: { $0.frame == shade.frame }) ?? shade.screen else { return }
        let origin = shade.frame.origin
        let local = { (rect: NSRect) in rect.offsetBy(dx: -origin.x, dy: -origin.y) }
        let avoiding = [window?.isVisible == true ? window?.frame : nil, scrollPreviewWindow?.frame].compactMap { $0 }.map(local)
        view.showHint(text, isError: state["hintIsError"] as? Bool == true,
                      visible: local(screen.visibleFrame), avoiding: avoiding)
    }

    private func showScrollPreview(_ preview: ScrollStitcher.Preview, scale: CGFloat) {
        guard [.scrolling, .pausing, .paused].contains(service.phase),
              let screen = originScreen ?? NSScreen.main else { return }
        let panel: NSPanel
        if let current = scrollPreviewWindow { panel = current } else {
            panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.identifier = AppConstants.captureControlWindowIdentifier
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = ScrollPreviewView()
            NativeGlassFactory.applyAppearance(to: panel)
            scrollPreviewWindow = panel
        }
        guard let view = panel.contentView as? ScrollPreviewView else { return }
        let size = view.update(preview, scale: scale)
        let control = window?.frame ?? NSRect(origin: Self.controlOrigin(visible: screen.visibleFrame, size: AppConstants.captureControlSize),
                                              size: AppConstants.captureControlSize)
        panel.setFrame(Self.scrollPreviewFrame(size: size, control: control, visible: screen.visibleFrame), display: true)
        panel.orderFrontRegardless()
    }

    static func scrollPreviewFrame(size: NSSize, control: NSRect, visible: NSRect) -> NSRect {
        let x = min(max(control.maxX - size.width, visible.minX), visible.maxX - size.width)
        let y = min(control.maxY + AppConstants.captureControlGap, visible.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func updateCaptureShades() {
        let mediaFrame = !shuttingDown && [.preparing, .recording, .scrolling, .pausing, .paused].contains(service.phase)
            ? service.captureFrame : nil
        if shuttingDown || ![.scrolling, .pausing, .paused].contains(service.phase) {
            scrollPreviewWindow?.close()
            scrollPreviewWindow = nil
        }
        guard let frame = liveShadeFrame ?? mediaFrame else {
            for window in captureShades.values { window.close() }
            captureShades.removeAll()
            return
        }
        var active = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens where screen.frame.intersects(frame) {
            guard let displayID = screen.displayID else { continue }
            active.insert(displayID)
            let shade: NSWindow
            if let current = captureShades[displayID] {
                shade = current
            } else {
                shade = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                shade.identifier = AppConstants.captureControlWindowIdentifier
                shade.isReleasedWhenClosed = false
                shade.isOpaque = false
                shade.backgroundColor = .clear
                shade.hasShadow = false
                shade.ignoresMouseEvents = true
                shade.level = .floating
                shade.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                shade.contentView = CaptureShadeView(frame: NSRect(origin: .zero, size: screen.frame.size))
                NativeGlassFactory.applyAppearance(to: shade)
                captureShades[displayID] = shade
                shade.orderFrontRegardless()
            }
            NativeGlassFactory.applyAppearance(to: shade)
            shade.setFrame(screen.frame, display: false)
            let view = shade.contentView as! CaptureShadeView
            view.selection = frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                .intersection(NSRect(origin: .zero, size: screen.frame.size))
            view.flowsBorder = liveShadeFrame == nil
                && service.isRegionRecording
                && [.recording, .pausing, .paused].contains(service.phase)
            view.flowPaused = [.pausing, .paused].contains(service.phase)
        }
        for displayID in Set(captureShades.keys).subtracting(active) {
            captureShades.removeValue(forKey: displayID)?.close()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if liveControlID != nil {
            onLiveCancel?()
            return false
        }
        Task { @MainActor in
            await discard()
        }
        return false
    }

    private func discard() async {
        guard !discarding else { return }
        discarding = true
        pendingStartup?.cancel()
        pendingStartup = nil
        defer {
            discarding = false
            present()
        }
        releasePlayer()
        await service.cancel()
    }

    func stop() {
        if liveControlID != nil {
            onLiveStop?()
            return
        }
        if service.isCountingDown {
            Task { @MainActor in await discard() }
            return
        }
        Task { @MainActor in
            do { try await service.stop() }
            catch { if service.phase != .failed { showError(error) } }
        }
    }

    private func showError(_ error: Error) {
        guard !shuttingDown else { return }
        let alert = NativeGlassFactory.applyAppearance(to: NSAlert())
        alert.alertStyle = .warning
        alert.messageText = "无法完成采集操作"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func releasePlayer() {
        if let playerTimeObserver {
            player?.removeTimeObserver(playerTimeObserver)
            self.playerTimeObserver = nil
        }
        if let playerEndObserver {
            NotificationCenter.default.removeObserver(playerEndObserver)
            self.playerEndObserver = nil
        }
        playerStatusObservation?.invalidate()
        playerStatusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerView?.player = nil
        player = nil
        playerSession = nil
    }

    private func currentPlaybackPosition() -> Double {
        guard let player else { return 0 }
        let seconds = player.currentTime().seconds
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private func installPlayerObservers(on target: AVPlayer) {
        let sessionId = playerSession
        playerTimeObserver = target.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.player === target, self.playerSession == sessionId,
                      [.videoReady, .converting].contains(self.service.phase) else { return }
                self.channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: self.captureState())
            }
        }
        playerStatusObservation = target.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.player === target, self.playerSession == sessionId,
                      [.videoReady, .converting].contains(self.service.phase) else { return }
                self.channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: self.captureState())
            }
        }
        playerEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.player === target, self.playerSession == sessionId,
                      let item = notification.object as? AVPlayerItem, item === target.currentItem,
                      [.videoReady, .converting].contains(self.service.phase) else { return }
                target.pause()
                self.channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: self.captureState())
            }
        }
    }

    private func scrollPNG() -> Data? {
        guard service.phase == .imageReady,
              let bytes = service.snapshot()["imageBytes"] as? FlutterStandardTypedData else { return nil }
        return bytes.data
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        Task { @MainActor in
            do {
                if let liveControlID {
                    guard call.method == AppConstants.getCaptureStateMethod || args["id"] as? String == liveControlID else {
                        throw GIFExporter.ExportError(message: "采集会话已改变，请重试。")
                    }
                    switch call.method {
                    case AppConstants.getCaptureStateMethod:
                        break
                    case AppConstants.setCapturePausedMethod:
                        guard let paused = args["paused"] as? Bool else {
                            throw GIFExporter.ExportError(message: "缺少暂停状态。")
                        }
                        livePaused = paused
                        onLivePause?(paused)
                    case AppConstants.stopCaptureMethod:
                        onLiveStop?()
                    case AppConstants.cancelCaptureMethod:
                        onLiveCancel?()
                    default:
                        throw GIFExporter.ExportError(message: "实时翻译没有这个媒体操作。")
                    }
                    result(captureState())
                    return
                }
                guard call.method == AppConstants.getCaptureStateMethod || args["id"] as? String == service.id else {
                    throw GIFExporter.ExportError(message: "采集会话已改变，请重试。")
                }
                let token = service.id
                switch call.method {
                case AppConstants.getCaptureStateMethod:
                    break
                case AppConstants.setCapturePausedMethod:
                    guard let paused = args["paused"] as? Bool else {
                        throw GIFExporter.ExportError(message: "缺少暂停状态。")
                    }
                    try await service.setPaused(paused)
                case AppConstants.stopCaptureMethod:
                    try await service.stop()
                case AppConstants.cancelCaptureMethod:
                    await discard()
                case AppConstants.saveRecordingMethod:
                    let target = try outputURL(.mp4, date: Date())
                    try service.saveVideo(to: target)
                case AppConstants.copyRecordingMethod:
                    try await copyRecording()
                case AppConstants.previewRecordingMethod:
                    try await preview()
                case AppConstants.toggleRecordingPlaybackMethod:
                    try await togglePlayback()
                case AppConstants.seekRecordingMethod:
                    guard let seconds = (args["seconds"] as? NSNumber)?.doubleValue else {
                        throw GIFExporter.ExportError(message: "缺少播放位置。")
                    }
                    try await seek(to: seconds)
                case AppConstants.trimRecordingMethod:
                    try await trim()
                case AppConstants.exportRecordingGIFMethod, AppConstants.exportRecordingAPNGMethod:
                    let format: GIFExporter.Format = call.method == AppConstants.exportRecordingGIFMethod ? .gif : .apng
                    let requestedAt = Date()
                    let source = try service.recordingURL()
                    let info = try await GIFExporter.metadata(source)
                    guard token == service.id else { throw GIFExporter.ExportError(message: "录制会话已失效。") }
                    let settings = AppPreferences.current
                    let options = GIFExporter.Options(
                        framesPerSecond: settings[AppConstants.gifFramesPerSecondKey] as? Int ?? 10,
                        maximumWidth: settings[AppConstants.gifMaximumWidthKey] as? Int)
                    _ = try options.validate(duration: service.trim?.duration.seconds ?? info.duration, sourceWidth: info.width)
                    let target = try outputURL(format.kind, date: requestedAt)
                    try service.exportAnimation(format, options: options, to: target)
                case AppConstants.exportRecordingWebMMethod:
                    let target = try outputURL(.webm, date: Date())
                    try service.exportWebM(to: target)
                case AppConstants.cancelRecordingExportMethod:
                    service.cancelExport()
                case AppConstants.copyScreenshotMethod:
                    guard let png = scrollPNG() else {
                        throw GIFExporter.ExportError(message: "当前没有可复制的长图。")
                    }
                    guard PNGPasteboard.write(png) else {
                        throw GIFExporter.ExportError(message: "无法复制长图，请重试。")
                    }
                case AppConstants.saveScreenshotMethod:
                    guard let png = scrollPNG() else {
                        throw GIFExporter.ExportError(message: "当前没有可保存的长图。")
                    }
                    let name = args["name"] as? String ?? "长截图.png"
                    let basePath = UserDefaults.standard.string(forKey: AppConstants.screenshotSaveDirectoryKey)
                    let token = service.id
                    let url = try await Task.detached {
                        let directory = try ScreenshotStorage.datedDirectory(basePath: basePath, category: .screenshot)
                        return try ScreenshotStorage.save(png, directory: directory, name: name)
                    }.value
                    if token == service.id { service.noteSavedScroll(url.path) }
                default:
                    result(FlutterMethodNotImplemented); return
                }
                result(captureState())
            } catch {
                result(FlutterError(code: AppConstants.captureFailedError, message: error.localizedDescription, details: nil))
            }
        }
    }

    private func outputURL(_ kind: RecordingExport, date: Date) throws -> URL {
        let directory = try ScreenshotStorage.datedDirectory(
            basePath: UserDefaults.standard.string(forKey: AppConstants.screenshotSaveDirectoryKey),
            category: ScreenshotStorage.Category(kind), date: date)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return directory.appendingPathComponent("录屏-\(formatter.string(from: date)).\(kind.fileExtension)")
    }

    fileprivate func makePreview(id: String) -> NSView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        guard id == service.id, [.videoReady, .converting].contains(service.phase) else { return view }
        do {
            let url = try service.previewURL()
            if playerSession != id {
                releasePlayer()
                let nextPlayer = AVPlayer(url: url)
                player = nextPlayer
                playerSession = id
                installPlayerObservers(on: nextPlayer)
            }
            view.player = player
            playerView = view
        } catch { showError(error) }
        return view
    }

    private func preview() async throws {
        let token = service.id
        let url = try service.recordingURL()
        let info = try await GIFExporter.metadata(url)
        guard token == service.id else { throw GIFExporter.ExportError(message: "录制会话已失效。") }
        let range = service.trim ?? CMTimeRange(start: .zero, duration: CMTime(seconds: info.duration, preferredTimescale: 60000))
        let item = AVPlayerItem(url: url)
        item.reversePlaybackEndTime = range.start
        item.forwardPlaybackEndTime = range.end
        if player == nil {
            let nextPlayer = AVPlayer()
            player = nextPlayer
            playerSession = token
            installPlayerObservers(on: nextPlayer)
        }
        player?.replaceCurrentItem(with: item)
        playerView?.player = player
        await player?.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero)
        guard token == service.id else { return }
        player?.play()
    }

    private func togglePlayback() async throws {
        let token = service.id
        let url = try service.recordingURL()
        let info = try await GIFExporter.metadata(url)
        guard token == service.id else { throw GIFExporter.ExportError(message: "录制会话已失效。") }
        if player == nil || playerSession != token {
            releasePlayer()
            let nextPlayer = AVPlayer(url: url)
            player = nextPlayer
            playerSession = token
            playerView?.player = nextPlayer
            installPlayerObservers(on: nextPlayer)
        }
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            return
        }
        let range = service.trim ?? CMTimeRange(start: .zero, duration: CMTime(seconds: info.duration, preferredTimescale: 60000))
        if player.currentItem == nil {
            let item = AVPlayerItem(url: url)
            item.reversePlaybackEndTime = range.start
            item.forwardPlaybackEndTime = range.end
            player.replaceCurrentItem(with: item)
        } else {
            player.currentItem?.reversePlaybackEndTime = range.start
            player.currentItem?.forwardPlaybackEndTime = range.end
        }
        let current = currentPlaybackPosition()
        let startSec = range.start.seconds.isFinite ? max(0, range.start.seconds) : 0
        let endSec = range.end.seconds.isFinite ? max(startSec, range.end.seconds) : info.duration
        if current < startSec - 0.05 || current >= endSec - 0.05 {
            await player.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        guard token == service.id else { return }
        player.play()
    }

    private func seek(to seconds: Double) async throws {
        let token = service.id
        let url = try service.recordingURL()
        let info = try await GIFExporter.metadata(url)
        guard token == service.id else { throw GIFExporter.ExportError(message: "录制会话已失效。") }
        if player == nil || playerSession != token {
            releasePlayer()
            let nextPlayer = AVPlayer(url: url)
            player = nextPlayer
            playerSession = token
            playerView?.player = nextPlayer
            installPlayerObservers(on: nextPlayer)
        }
        let clamped = min(max(0, seconds.isFinite ? seconds : 0), max(0, info.duration))
        await player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func trim() async throws {
        let token = service.id
        _ = try service.recordingURL()
        guard let playerView, let item = player?.currentItem, playerView.canBeginTrimming else {
            throw GIFExporter.ExportError(message: "播放器尚未就绪，请稍后再试。")
        }
        player?.pause()
        playerView.controlsStyle = .inline
        defer { playerView.controlsStyle = .none }
        let result = await playerView.beginTrimming()
        guard token == service.id, result == .okButton else { return }
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
        try service.setTrim(start <= .zero && end >= item.duration ? nil : CMTimeRange(start: start, end: end))
    }

    nonisolated static func recordingClipboardDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(AppConstants.recordingClipboardDirectoryName, isDirectory: true)
    }

    nonisolated static func clearRecordingClipboardDirectory(at directory: URL = recordingClipboardDirectory()) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for entry in entries {
            try? fileManager.removeItem(at: entry)
        }
    }

    nonisolated static func clipboardVideoURL(date: Date, in directory: URL = recordingClipboardDirectory()) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "录屏-\(formatter.string(from: date))"
        let first = directory.appendingPathComponent("\(stem).mp4")
        if !fileManager.fileExists(atPath: first.path) { return first }
        var index = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem)-\(index).mp4")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func copyRecording() async throws {
        let token = service.id
        let source = try service.recordingURL()
        let range = service.trim
        let target = try await Task.detached {
            let destination = try Self.clipboardVideoURL(date: Date())
            do {
                if let range {
                    try await MediaCaptureService.trimVideo(source: source, range: range, destination: destination) { _ in }
                } else {
                    try FileManager.default.copyItem(at: source, to: destination)
                }
                return destination
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }.value
        guard token == service.id else {
            try? FileManager.default.removeItem(at: target)
            throw GIFExporter.ExportError(message: "录制会话已失效。")
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([target as NSURL]) else {
            try? FileManager.default.removeItem(at: target)
            throw GIFExporter.ExportError(message: "无法复制视频，请重试。")
        }
    }
}

private final class CapturePreviewFactory: NSObject, FlutterPlatformViewFactory {
    private weak var owner: CaptureWindowController?

    init(owner: CaptureWindowController) { self.owner = owner }

    func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? { FlutterStandardMessageCodec.sharedInstance() }

    func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
        MainActor.assumeIsolated {
            guard let id = (args as? [String: Any])?["id"] as? String, let owner else { return NSView() }
            return owner.makePreview(id: id)
        }
    }
}

private final class CaptureControlPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class CaptureShadeView: NSView {
    private static let flowAnimationKey = "recordingBorderFlow"

    var contentRects: [NSRect]? {
        didSet {
            guard contentRects != oldValue else { return }
            needsDisplay = true
            syncFlowLayer()
        }
    }
    var selection = NSRect.zero {
        didSet {
            guard selection != oldValue else { return }
            needsDisplay = true
            syncFlowLayer()
        }
    }
    var flowsBorder = false {
        didSet {
            guard flowsBorder != oldValue else { return }
            syncFlowLayer()
        }
    }
    var flowPaused = false {
        didSet {
            guard flowPaused != oldValue else { return }
            syncFlowPause()
        }
    }
    var isReduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private(set) var flowLayer: CAShapeLayer?
    private var flowSize = NSSize.zero
    private(set) var hintView: NativeGlassContainerView?
    private var hintGeneration = 0

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let flowLayer { applyFlowAppearance(to: flowLayer) }
    }

    private func applyFlowAppearance(to layer: CAShapeLayer) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NativeGlassFactory.resolvedAccentNSColor(for: effectiveAppearance).cgColor
            layer.strokeColor = accent
            layer.shadowColor = accent
        }
    }

    func syncFlowLayer() {
        let rect = selection.insetBy(dx: 0.5, dy: 0.5)
        let enabled = flowsBorder
            && contentRects == nil
            && !isReduceMotion()
            && rect.width > 0
            && rect.height > 0
        guard enabled else {
            flowLayer?.removeAllAnimations()
            flowLayer?.removeFromSuperlayer()
            flowLayer = nil
            flowSize = .zero
            return
        }
        wantsLayer = true
        let shape: CAShapeLayer
        if let existing = flowLayer {
            shape = existing
        } else {
            shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineWidth = AppConstants.recordingFlowStroke
            shape.lineCap = .round
            shape.shadowOffset = .zero
            shape.shadowRadius = AppConstants.recordingFlowGlow / 2
            shape.shadowOpacity = AppConstants.recordingFlowShadowOpacity
            layer?.insertSublayer(shape, at: 0)
            flowLayer = shape
        }
        shape.frame = bounds
        shape.path = CGPath(rect: rect, transform: nil)
        applyFlowAppearance(to: shape)
        let perimeter = 2 * (rect.width + rect.height)
        let dash = Double(perimeter * AppConstants.recordingFlowArc)
        let gap = Double(perimeter) - dash
        shape.lineDashPattern = [NSNumber(value: dash), NSNumber(value: gap)]
        if flowSize != rect.size || shape.animation(forKey: Self.flowAnimationKey) == nil {
            flowSize = rect.size
            shape.speed = 1
            shape.timeOffset = 0
            shape.beginTime = 0
            let animation = CABasicAnimation(keyPath: "lineDashPhase")
            animation.fromValue = 0
            animation.toValue = -perimeter
            animation.duration = AppConstants.recordingFlowPeriod
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            shape.add(animation, forKey: Self.flowAnimationKey)
        }
        syncFlowPause()
    }

    private func syncFlowPause() {
        guard let shape = flowLayer else { return }
        if flowPaused {
            guard shape.speed != 0 else { return }
            let pausedTime = shape.convertTime(CACurrentMediaTime(), from: nil)
            shape.speed = 0
            shape.timeOffset = pausedTime
        } else {
            guard shape.speed == 0 else { return }
            let pausedTime = shape.timeOffset
            shape.speed = 1
            shape.timeOffset = 0
            shape.beginTime = 0
            shape.beginTime = shape.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
        }
    }

    func showHint(_ text: String, isError: Bool, visible: NSRect? = nil, avoiding: [NSRect] = []) {
        hintView?.removeFromSuperview()
        let padding = AppConstants.scrollHintPadding
        let iconSize = isError ? AppConstants.inputFailureIconSize : 0
        let iconSpacing = isError ? AppConstants.inputFailureIconSpacing : 0
        let iconExtra = isError ? (iconSize + iconSpacing) : 0
        let outsideMaxTextWidth = max(1, AppConstants.scrollHintMaxWidth - padding.width * 2 - iconExtra)
        let outside = Self.hintTextSize(text, width: outsideMaxTextWidth)
        let outsideSize = NSSize(
            width: min(AppConstants.scrollHintMaxWidth, outside.width + padding.width * 2 + iconExtra),
            height: max(outside.height, iconSize) + padding.height * 2
        )

        let effectiveVisible = visible ?? bounds
        let rawInside = selection.width - AppConstants.captureControlGap * 2
        let centeredWidth = rawInside >= AppConstants.scrollHintMinCenteredWidth
            ? min(AppConstants.scrollHintMaxWidth, rawInside)
            : min(AppConstants.scrollHintMaxWidth, max(AppConstants.scrollHintMinCenteredWidth, effectiveVisible.width - AppConstants.captureControlGap * 2))
        let insideMaxTextWidth = max(1, centeredWidth - padding.width * 2 - iconExtra)
        let inside = Self.hintTextSize(text, width: insideMaxTextWidth)
        let insideSize = NSSize(
            width: min(centeredWidth, inside.width + padding.width * 2 + iconExtra),
            height: max(inside.height, iconSize) + padding.height * 2
        )

        let frame = Self.hintFrame(outside: outsideSize, inside: insideSize, selection: selection, visible: effectiveVisible, avoiding: avoiding)
        let textSize = NSSize(
            width: max(1, frame.width - padding.width * 2 - iconExtra),
            height: max(18, frame.height - padding.height * 2)
        )
        let label = NSTextField(wrappingLabelWithString: text)
        if isError {
            let styled = NSMutableAttributedString(attributedString: Self.hintText(text, isError: true))
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = 18
            paragraph.maximumLineHeight = 18
            paragraph.alignment = .left
            styled.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: styled.length))
            label.attributedStringValue = styled
        } else {
            label.attributedStringValue = Self.hintText(text, isError: false)
        }
        label.frame = NSRect(
            origin: NSPoint(x: padding.width + iconExtra, y: ((frame.height - textSize.height) / 2).rounded()),
            size: textSize
        )
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        if isError {
            let icon = NSImageView(frame: NSRect(
                x: padding.width,
                y: ((frame.height - iconSize) / 2).rounded(),
                width: iconSize,
                height: iconSize
            ))
            icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "错误")
            icon.contentTintColor = .systemRed
            icon.imageScaling = .scaleProportionallyDown
            content.addSubview(icon)
        }
        content.addSubview(label)
        let container = NativeGlassFactory.makeGlassContainer(
            content: content,
            size: frame.size,
            cornerRadius: AppConstants.scrollHintRadius
        )
        container.frame = frame
        addSubview(container)
        hintView = container
        let priority = isError ? NSAccessibilityPriorityLevel.high.rawValue : NSAccessibilityPriorityLevel.medium.rawValue
        NSAccessibility.post(element: container, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: priority])
        hintGeneration += 1
        let generation = hintGeneration
        let durationMs = isError ? AppConstants.scrollErrorHintDurationMs : AppConstants.scrollHintDurationMs
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(durationMs))
            guard let self, self.hintGeneration == generation else { return }
            self.hintView?.removeFromSuperview()
            self.hintView = nil
        }
    }

    static func hintFrame(outside: NSSize, inside: NSSize, selection: NSRect, visible: NSRect, avoiding: [NSRect]) -> NSRect {
        let gap = AppConstants.captureControlGap
        let width = outside.width
        let height = outside.height
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(max(value, low), high) }
        let candidates = [
            NSRect(x: clamp(selection.midX - width / 2, visible.minX, visible.maxX - width), y: selection.maxY + gap,
                   width: width, height: height),
            NSRect(x: clamp(selection.midX - width / 2, visible.minX, visible.maxX - width), y: selection.minY - gap - height,
                   width: width, height: height),
            NSRect(x: selection.minX - gap - width, y: clamp(selection.midY - height / 2, visible.minY, visible.maxY - height),
                   width: width, height: height),
            NSRect(x: selection.maxX + gap, y: clamp(selection.midY - height / 2, visible.minY, visible.maxY - height),
                   width: width, height: height),
        ]
        for candidate in candidates.map({ NSRect(x: $0.minX.rounded(), y: $0.minY.rounded(), width: $0.width, height: $0.height) }) where visible.contains(candidate)
            && !avoiding.contains(where: { $0.intersects(candidate) }) {
            return candidate
        }
        let maxX = max(visible.minX, visible.maxX - inside.width)
        let maxY = max(visible.minY, visible.maxY - inside.height)
        return NSRect(
            x: min(max((selection.midX - inside.width / 2).rounded(), visible.minX), maxX),
            y: min(max((selection.midY - inside.height / 2).rounded(), visible.minY), maxY),
            width: inside.width,
            height: inside.height
        )
    }

    static func hintText(_ text: String, isError: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 18
        paragraph.maximumLineHeight = 18
        paragraph.alignment = .center
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: isError ? NSColor.systemRed : NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
    }

    static func hintTextSize(_ text: String, width: CGFloat) -> NSSize {
        let bounds = hintText(text, isError: false).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(min(bounds.width, width)), height: max(18, ceil(bounds.height)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        if let contentRects {
            NSColor.black.withAlphaComponent(AppConstants.captureShadeOpacity).setFill()
            bounds.fill()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            for rect in contentRects { rect.fill() }
            NSGraphicsContext.restoreGraphicsState()
            NativeGlassFactory.resolvedAccentNSColor(for: effectiveAppearance).setStroke()
            for rect in contentRects { NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke() }
        } else {
            path.appendRect(selection)
            path.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(AppConstants.captureShadeOpacity).setFill()
            path.fill()
        }
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        NativeGlassFactory.resolvedAccentNSColor(for: effectiveAppearance).setStroke()
        border.stroke()
    }
}

final class ScrollPreviewView: NSView {
    private let glassContainer: NativeGlassContainerView
    private let content = NSView()
    let imageView = NSImageView()
    let targetView = NSView()

    init() {
        glassContainer = NativeGlassFactory.makeGlassContainer(
            content: content,
            size: .zero,
            cornerRadius: AppConstants.scrollHintRadius
        )
        super.init(frame: .zero)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = AppConstants.scrollPreviewImageRadius
        imageView.layer?.masksToBounds = true
        targetView.wantsLayer = true
        targetView.layer?.borderWidth = AppConstants.scrollPreviewTargetLine
        targetView.isHidden = true
        content.addSubview(imageView)
        content.addSubview(targetView)
        addSubview(glassContainer)
    }

    required init?(coder: NSCoder) { fatalError("ScrollPreviewView requires programmatic initialization") }

    @discardableResult
    func update(_ preview: ScrollStitcher.Preview, scale: CGFloat) -> NSSize {
        let inset = AppConstants.scrollPreviewInset
        let size = NSSize(width: CGFloat(preview.image.width) / scale, height: CGFloat(preview.image.height) / scale)
        setFrameSize(NSSize(width: size.width + inset * 2, height: size.height + inset * 2))
        glassContainer.frame = bounds
        glassContainer.layoutSubtreeIfNeeded()
        imageView.frame = NSRect(x: inset, y: inset, width: size.width, height: size.height)
        imageView.image = NSImage(cgImage: preview.image, size: size)
        if let target = preview.target, !target.isEmpty {
            targetView.layer?.borderColor = NSColor.systemRed.cgColor
            targetView.frame = NSRect(x: inset + target.minX / scale, y: inset + size.height - target.maxY / scale,
                                      width: target.width / scale, height: target.height / scale)
            targetView.isHidden = false
        } else { targetView.isHidden = true }
        return frame.size
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
