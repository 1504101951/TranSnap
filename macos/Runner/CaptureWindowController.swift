import AppKit
import AVKit
import FlutterMacOS
import QuartzCore

/// 采集工具协调者；截图层确认选区，采集与暂停时显示实时阴影与四气泡控制条，完成后展示结果。
@MainActor
final class CaptureWindowController: NSObject, NSWindowDelegate {
    let service = MediaCaptureService()
    private let screenshot: ScreenshotWindowController
    private var engine: FlutterEngine?
    private var channel: FlutterMethodChannel?
    /// 启动期间合并预热和展示请求，退出或丢弃时撤销，避免迟到创建旧面板。
    private var pendingStartup: WindowEngine.Startup?
    private var window: NSWindow?
    private var player: AVPlayer?
    private weak var playerView: AVPlayerView?
    private var playerSession: String?
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
    /// 已显示的长截图过程提示（会话身份#序号）；新序号才在选区中央再显示一次。
    private var shownScrollHint: String?
    /// 长截图实时缩略图窗口；只在滚动、暂停中存在，属于本应用而不进入采集像素。
    private var scrollPreviewWindow: NSPanel?

    /// 无参数；返回菜单与悬浮条停止可作用的真实资源阶段，录制倒计时也可停止（#129）。
    var canStop: Bool {
        liveControlID != nil || service.isCountingDown || [.recording, .scrolling, .paused].contains(service.phase)
    }

    /// 无参数；新截图开始时结束录制倒计时，不恢复旧截图草稿，没有倒计时时保持原状，无返回值（#129）。
    func cancelCountdown() {
        guard service.isCountingDown else { return }
        // 先放弃旧草稿的恢复权，discard回到idle时不再显示被替换的截图。
        preparingScreenshot = false
        Task { @MainActor in await discard() }
    }

    /// 无参数；有资源或结果时必须明确处理，不能被另一工具入口覆盖。
    var hasPendingCapture: Bool { discarding || ![.idle, .failed].contains(service.phase) }

    /// screenshot为唯一截图选择/编辑控制器；监听资源状态以切换承载面板。
    init(screenshot: ScreenshotWindowController) {
        self.screenshot = screenshot
        super.init()
        service.onChange = { [weak self] _ in
            guard let self else { return }
            let started = ContinuousClock.now
            let transition = self.service.phase != self.lastPhase
            let phase = self.service.phase
            // 真正进入采集后才释放截图草稿；准备失败或取消恢复同一编辑会话。
            let preparationFinished = [.recording, .scrolling, .failed].contains(self.service.phase)
                || (self.service.phase == .idle && self.lastPhase == .preparing)
            if self.preparingScreenshot && preparationFinished {
                self.preparingScreenshot = false
                if [.recording, .scrolling].contains(self.service.phase) { self.screenshot.closeForCapture() }
                else if !self.shuttingDown { self.screenshot.restoreAfterCapturePreparation() }
            }
            // 菜单栏图标跟随录制倒计时剩余秒数，会话清理后快照不含倒计时即恢复（#129）。
            StatusBarController.shared.showCountdown(self.service.snapshot()["countdown"] as? Int)
            // 准备态由present在缩放前发布，提供可提交的新帧；媒体结果待窗口几何就绪后再布局。
            self.present()
            self.showScrollHintIfNeeded()
            if phase != .preparing {
                self.channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: self.captureState())
            }
            // 只记录启动阶段切换的同步UI工作，录制计时通知不产生逐秒诊断日志。
            if transition && [.preparing, .recording].contains(phase) {
                CaptureStartupLog.record("ui-\(phase.rawValue)-sync", since: started)
            }
        }
        service.onActiveChanged = { [weak self] active in self?.onActiveChanged?(active) }
        service.onScrollPreview = { [weak self] preview, scale in self?.showScrollPreview(preview, scale: scale) }
    }

    /// 无参数；终止任务并释放播放器文件引用，再关闭本工具的面板和引擎。
    func shutdown() async {
        shuttingDown = true
        pendingStartup?.cancel()
        pendingStartup = nil
        // 退出立即撤下可见遮罩，再等待媒体资源清理。
        updateCaptureShades()
        // 在等待媒体资源清理前，先阻止选区冻结任务创建新的窗口。
        screenshot.cancelCapture()
        releasePlayer()
        await service.cancel()
        window?.delegate = nil
        window?.close()
        // 结果窗口随采集界面关闭，撤销 Dock 与 ⌘Tab 登记。
        DockPresence.leave(self)
        channel?.setMethodCallHandler(nil)
        engine?.shutDownEngine()
        engine = nil
        channel = nil
        window = nil
    }

    /// source为截图工具栏确认的来源，scrolling指定长截图，region为已校验的选区；返回后异步启动。
    func prepare(source: [String: Any], scrolling: Bool, region: MediaCaptureService.Region?) throws {
        guard !shuttingDown, !hasPendingCapture else {
            throw GIFExporter.ExportError(message: "请先结束或放弃当前采集。")
        }
        guard source["kind"] as? String != CaptureTarget.region.rawValue || region != nil else {
            throw GIFExporter.ExportError(message: "请先选择有效录制区域。")
        }
        // start负责保持会话身份并在资源层重新验证目标，工具栏不直接持有捕获流。
        start(source, scrolling: scrolling, region: region)
    }

    /// preferredApplicationID为截图前台应用；返回应用图标行所需的去重有序来源。
    func sources(preferredApplicationID: String?) async throws -> [[String: Any]] {
        try await service.sources(preferredApplicationID: preferredApplicationID)
    }

    /// 无参数/返回值；选择录制目标时准备隐藏的采集界面，避免开始采集时同步初始化Flutter引擎。
    func prepareControls() {
        guard !shuttingDown else { return }
        // createPanel只初始化并复用界面，不显示窗口、不申请或启动媒体资源。
        createPanel()
    }

    /// source为明确目标，scrolling决定静帧或视频，region为本次选区；返回后异步启动资源。
    private func start(_ source: [String: Any], scrolling: Bool, region: MediaCaptureService.Region? = nil) {
        let token = service.id
        guard let screenshotID = screenshot.liveCaptureID else { return }
        Task { @MainActor in
            guard !shuttingDown, token == service.id, !hasPendingCapture,
                  screenshotID == screenshot.liveCaptureID else { return }
            do {
                // 先提交选区；其idle通知只是选区更新，不是采集准备被取消。
                if let region { try service.select(region) }
                // 准备期间隐藏冻结层，实际采集就绪后才销毁草稿。
                preparingScreenshot = true
                screenshot.hideForCapture()
                if let id = source["sourceID"] as? NSNumber {
                    originScreen = NSScreen.screens.first { $0.displayID == id.uint32Value }
                }
                if scrolling { try await service.startScrolling() }
                // delay已由截图通道校验为录制选项中的秒数（#129）。
                else { try await service.startRecording(source, delay: source["delay"] as! Int) }
            } catch is CancellationError {
                // 准备期间用户停止已清理会话，不把明确取消显示成采集故障。
            } catch {
                if preparingScreenshot {
                    preparingScreenshot = false
                    screenshot.restoreAfterCapturePreparation()
                }
                if service.phase != .failed { showError(error) }
            }
        }
    }

    /// 无参数；等待 Dart 就绪后懒建透明 Flutter 面板，按当前状态展示，idle 预热保持隐藏，无返回值。
    private func createPanel() {
        guard window == nil, pendingStartup == nil, !shuttingDown, !discarding else { return }
        let started = ContinuousClock.now
        // 记录真实采集引擎初始化，便于区分界面准备与ScreenCaptureKit启动耗时。
        defer { CaptureStartupLog.record("capture-ui-create-sync", since: started) }
        // WindowEngine 等待 Dart 确认；采集窗口就绪后再注册视频预览平台视图。
        pendingStartup = WindowEngine.start(
            name: AppConstants.captureEntrypoint, entrypoint: AppConstants.captureEntrypoint,
            channel: AppConstants.captureChannel,
            handler: { [weak self] call, result in self?.handle(call, result: result) },
            completion: { [weak self] started in
                guard let self else { return }
                self.pendingStartup = nil
                guard let started else {
                    // 清理期间阻止资源通知重新启动面板；真实采集资源必须在失败提示前结束。
                    self.discarding = true
                    if self.liveControlID != nil {
                        self.onLiveCancel?()
                        // hideLiveControls/setLiveShade 立即撤销失去控制条的实时展示状态。
                        self.hideLiveControls()
                        self.setLiveShade(nil)
                    }
                    Task { @MainActor in
                        // releasePlayer 先解除文件引用，再由 cancel 释放流与临时媒体。
                        self.releasePlayer()
                        await self.service.cancel()
                        if self.preparingScreenshot {
                            self.preparingScreenshot = false
                            // restoreAfterCapturePreparation 恢复尚未开始采集的同一截图草稿。
                            if !self.shuttingDown { self.screenshot.restoreAfterCapturePreparation() }
                        }
                        self.discarding = false
                        // present 同步清理后的空闲状态，撤下采集遮罩并恢复激活策略。
                        self.present()
                        guard !self.shuttingDown else { return }
                        // reportStartFailure 使用附属窗口统一的启动失败提示。
                        WindowEngine.reportStartFailure("采集窗口")
                    }
                    return
                }
                self.engine = started.engine
                self.channel = started.channel
                let flutter = started.flutter
                flutter.registrar(forPlugin: "CaptureVideoPreview").register(
                    CapturePreviewFactory(owner: self), withId: AppConstants.captureVideoPreview)
                // makeWindow 从创建时就明确非激活类型，随后 present 按当前媒体状态调整窗口。
                let panel = Self.makeWindow(compact: true)
                panel.delegate = self
                NativeGlassFactory.installContent(flutter, in: panel)
                self.window = panel
                // present 读取确认时的真实阶段；预热完成仍处于 idle 时保持隐藏。
                self.present()
                self.channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: self.captureState())
            })
    }

    /// compact指定采集控制条或视频结果；返回非激活顶层面板或带系统控制的普通窗口。
    static func makeWindow(compact: Bool) -> NSWindow {
        let frame = NSRect(origin: .zero, size: AppConstants.captureControlSize)
        let window: NSWindow
        if compact {
            let panel = CaptureControlPanel(contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
            // 平台包装视图可能不接受首鼠标；无需键盘的按钮不先消耗一次点击来取得窗口焦点。
            panel.becomesKeyOnlyIfNeeded = true
            // 控制气泡不进入录制画面。
            panel.identifier = AppConstants.captureControlWindowIdentifier
            window = panel
        } else {
            window = NSWindow(contentRect: frame, styleMask: AppConstants.captureResultWindowStyle,
                backing: .buffered, defer: false)
            window.title = "录制结果"
            window.contentMinSize = Self.recordingResultMinimumSize()
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

    /// pixels 为源视频像素，scale 为来源显示倍率，visible 为屏幕可用区；返回包含系统标题栏、等比媒体与底部 356×48 工具栏的窗口（#67、#142）。
    static func resultFrame(pixels: NSSize, scale: CGFloat, visible: NSRect) -> NSRect {
        let logical = NSSize(width: pixels.width / scale, height: pixels.height / scale)
        let inset = AppConstants.captureControlGap
        // 系统标题栏和边框占用真实窗口空间，Flutter 只布局标题栏下方的可用内容。
        let available = NSWindow.contentRect(forFrameRect: visible, styleMask: AppConstants.captureResultWindowStyle).size
        // 上边距和左右边距 8pt；视频下方隔 8pt 是 48pt 厚的横排工具栏（宽 356pt），纵向预留 64pt。
        let reservedWidth = inset * 2
        let reservedHeight = inset * 2 + AppConstants.captureResultToolbarThickness
        let fit = min(1, min((available.width - reservedWidth) / logical.width,
                             (available.height - reservedHeight) / logical.height))
        // 浮点缩放可能在恰好铺满时多出亚像素；窗口宽度至少容纳 356pt 工具栏并限制在可用屏幕内。
        let contentSize = NSSize(width: min(available.width, max(logical.width * fit + reservedWidth, AppConstants.captureResultToolbarLength)),
                                 height: min(available.height, logical.height * fit + reservedHeight))
        let frame = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: AppConstants.captureResultWindowStyle)
        let size = NSSize(width: min(visible.width, frame.width), height: min(visible.height, frame.height))
        return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// 无参数；在资源快照中补充实际采集状态，Flutter与原生窗口使用同一生命周期。
    private func captureState() -> [String: Any] {
        if let liveControlID {
            // 实时翻译同步录制时带上录制时长；未录制时媒体阶段为 idle。
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
        return state
    }

    /// id 为本次实时翻译控制身份，screen 为来源所在显示器。显示既有悬浮条，不启动录屏。
    func showLiveControls(id: String, screen: NSScreen?) {
        liveControlID = id
        livePaused = false
        if let screen { originScreen = screen }
        // present 按紧凑控制条显示面板并通知界面，与录制、长截图是同一段流程。
        present()
    }

    /// text 为运行中的状态。暂停和结束后清空，悬浮条回到「实时翻译」。
    func setLiveDetail(_ text: String) {
        guard liveControlID != nil, liveDetail != text else { return }
        liveDetail = text
        channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: captureState())
    }

    /// paused 为悬浮条上的暂停或恢复。只更新实时翻译控制，不改变录屏阶段。
    func setLivePaused(_ paused: Bool) {
        guard liveControlID != nil else { return }
        livePaused = paused
        channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: captureState())
    }

    /// 无参数。撤下实时翻译悬浮条。录屏结果仍由媒体阶段决定。
    func hideLiveControls() {
        liveControlID = nil
        livePaused = false
        liveDetail = ""
        // present 按媒体阶段收起控制条，或恢复仍在展示的采集结果。
        present()
        channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: captureState())
    }

    /// frame 为当前捕获范围。nil 表示移除区域标记。
    func setLiveShade(_ frame: NSRect?) {
        liveShadeFrame = frame
        updateCaptureShades()
    }

    /// force表示用户重新打开隐藏结果；资源通知只同步所需布局和可见录制范围。
    func present(force: Bool = false) {
        guard !shuttingDown, !discarding else { return }
        let previous = lastPhase
        // 实时翻译不占用媒体阶段；进行中时与采集中一样显示紧凑控制条。
        let live = liveControlID != nil
        // 同步录制在实时翻译期间失败时先不记为已处理，实时翻译结束后的下一次调用才提示失败。
        if !(live && service.phase == .failed) { lastPhase = service.phase }
        let showingResult = !live && [.videoReady, .converting, .imageReady].contains(service.phase)
        // 结果先就位再撤遮罩；采集中仍立即更新选区阴影。
        if !showingResult { updateCaptureShades() }
        if !live, [.idle, .failed].contains(service.phase) {
            window?.orderOut(nil)
            compactPresentation = nil
            releasePlayer()
            if previous != service.phase, service.phase == .failed, let message = service.snapshot()["error"] as? String {
                // 采集层已经撤下；提示期间临时登记为普通应用，失败说明才不会留在正在滚动的应用后面。
                let alert = NSObject()
                DockPresence.enter(alert)
                NSApp.activate(ignoringOtherApps: true)
                showError(GIFExporter.ExportError(message: message))
                DockPresence.leave(alert)
            }
            // 结果已关闭或未打开，撤销本控制器的 Dock 与 ⌘Tab 登记。
            DockPresence.leave(self)
            return
        }
        createPanel()
        // 尚在等待 Dart 确认时由完成回调继续展示，不将暂无窗口当作启动失败。
        guard pendingStartup == nil else { return }
        let compact = live || [.preparing, .recording, .scrolling, .pausing, .paused, .finalizing].contains(service.phase)
        // NSPanel的非激活标记必须在初始化时确定；仅转移内容，不重建Flutter引擎或媒体。
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
            // 隐藏的idle界面没有可提交内容；先通知准备态或实时翻译状态，再缩放，避免Flutter同步等待空白帧直到超时。
            channel?.invokeMethod(AppConstants.captureStateChangedMethod, arguments: captureState())
        }
        if !compact { applyResultChrome(to: window) }
        // 结果只占媒体、工具栏和系统边框，窗口整体限制在来源屏可用区内。
        if changed || sizeChanged {
            if compact { window.setContentSize(controlSize) }
            else if let screen = originScreen ?? NSScreen.main {
                let state = service.snapshot()
                guard let width = state["width"] as? Int, let height = state["height"] as? Int else { return }
                let pixels = NSSize(width: width, height: height)
                let visible = screen.visibleFrame
                // 长图保持逻辑宽度并可滚动；视频才按可用区等比缩小。
                let frame = service.phase == .imageReady
                    ? ScreenshotWindowController.imageResultFrame(pixels: pixels, scale: screen.backingScaleFactor, visible: visible)
                    : Self.resultFrame(pixels: pixels, scale: screen.backingScaleFactor, visible: visible)
                window.setFrame(frame, display: true)
            }
        }
        if compact {
            // placeControls把当前面板放到来源屏可用区的右下角。
            placeControls()
            window.orderFrontRegardless()
        } else if changed || force {
            // 菜单栏应用默认不能盖过正在滚动的前台应用，结果必须先显示出来。
            orderResultFront(window)
        }
        if showingResult { updateCaptureShades() }
    }

    /// window为本次要展示的结果；以本控制器登记到 Dock 与 ⌘Tab，并把它放到当前前台应用之前。
    private func orderResultFront(_ window: NSWindow) {
        // 菜单栏应用停留在 accessory 时，普通窗口会落在正在滚动的应用后面。
        DockPresence.enter(self)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // 激活尚未完成时也先显示；层级仍是普通窗口，之后允许其他应用盖住。
        window.orderFrontRegardless()
    }

    /// window为已经换成普通标题样式的结果窗；长图和视频使用不同标题与最小内容，避免工具栏被裁掉。
    private func applyResultChrome(to window: NSWindow) {
        let image = service.phase == .imageReady
        window.title = image ? "长截图结果" : "录制结果"
        window.contentMinSize = image ? AppConstants.longScreenshotResultMinimumSize : Self.recordingResultMinimumSize()
    }

    /// 无参数；返回录制结果窗的最小内容尺寸（356×65），保留底部横排八操作、间距与至少 1pt 视频，缩放不裁掉工具栏（#142）。
    private static func recordingResultMinimumSize() -> NSSize {
        NSSize(width: AppConstants.captureResultToolbarLength,
               height: AppConstants.captureControlGap * 2 + AppConstants.captureResultToolbarThickness + 1)
    }

    /// 无参数；控制条固定在发起截图显示器的右下角，不随窗口移动或采集范围跳屏。
    private func placeControls() {
        guard let window, let screen = originScreen ?? NSScreen.main else { return }
        // controlOrigin统一可用区与面板尺寸的几何约定，不受图片像素倍率影响。
        window.setFrameOrigin(Self.controlOrigin(visible: screen.visibleFrame, size: window.frame.size))
    }

    /// visible为显示器可用点坐标，size为透明面板尺寸；返回留8pt边距的右下角原点。
    static func controlOrigin(visible: NSRect, size: NSSize) -> NSPoint {
        NSPoint(x: max(visible.minX, visible.maxX - size.width - AppConstants.captureControlGap),
                y: visible.minY + AppConstants.captureControlGap)
    }

    /// 无参数；长截图的新过程提示画在选区中心所在显示器的遮罩里。遮罩属于本应用，已排除在屏幕采集之外，
    /// 且不接收鼠标，提示不会进入长图，滚动仍交给来源应用。自动滚动到底的提示随暂停发布，暂停时也显示（#112）。
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
        // 可用区、控制面板和缩略图换成遮罩视图坐标；提示避开后两者。
        let origin = shade.frame.origin
        let local = { (rect: NSRect) in rect.offsetBy(dx: -origin.x, dy: -origin.y) }
        let avoiding = [window?.isVisible == true ? window?.frame : nil, scrollPreviewWindow?.frame].compactMap { $0 }.map(local)
        view.showHint(text, isError: state["hintIsError"] as? Bool == true,
                      visible: local(screen.visibleFrame), avoiding: avoiding)
    }

    /// preview为已确认长图底部缩略图，scale为选区所在屏倍率；在控制面板正上方右对齐显示，间距8pt并限制在可用区内。
    private func showScrollPreview(_ preview: ScrollStitcher.Preview, scale: CGFloat) {
        guard [.scrolling, .pausing, .paused].contains(service.phase),
              let screen = originScreen ?? NSScreen.main else { return }
        let panel: NSPanel
        if let current = scrollPreviewWindow { panel = current } else {
            panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            // 长截图预览不进入录制画面。
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

    /// size为缩略图外框，control为控制面板，visible为可用区；返回面板正上方8pt、右边对齐且不超出可用区的框。
    static func scrollPreviewFrame(size: NSSize, control: NSRect, visible: NSRect) -> NSRect {
        let x = min(max(control.maxX - size.width, visible.minX), visible.maxX - size.width)
        let y = min(control.maxY + AppConstants.captureControlGap, visible.maxY - size.height)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 无参数；在与采集范围相交的显示器上绘制实时阴影，透明洞和全部窗口均穿透鼠标。
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
                // 选区外阴影不进入录制画面。
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
            // 仅在区域录制（且非实时翻译预览）期间叠加流动边框，暂停时冻住光段相位（#142）。
            view.flowsBorder = liveShadeFrame == nil
                && service.isRegionRecording
                && [.recording, .pausing, .paused].contains(service.phase)
            view.flowPaused = [.pausing, .paused].contains(service.phase)
        }
        for displayID in Set(captureShades.keys).subtracting(active) {
            captureShades.removeValue(forKey: displayID)?.close()
        }
    }

    /// sender为用户关闭的结果窗口；返回false，由立即放弃后的资源状态统一撤下窗口。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if liveControlID != nil {
            onLiveCancel?()
            return false
        }
        Task { @MainActor in
            // discard统一系统关闭和Flutter操作；内部窗口切换时不设delegate，不经过此入口。
            await discard()
        }
        return false
    }

    /// 无参数/返回值；单击立即停止当前任务并清理临时媒体，已经保存的文件不参与删除。
    private func discard() async {
        guard !discarding else { return }
        discarding = true
        pendingStartup?.cancel()
        pendingStartup = nil
        defer {
            discarding = false
            // present 在资源清理完成后同步空闲状态，清理中的通知不能重建窗口。
            present()
        }
        // releasePlayer先撤销文件引用，再由cancel结束任务并清理临时目录。
        releasePlayer()
        await service.cancel()
    }

    /// 无参数；由菜单发出停止请求，完成后的状态通知负责展示结果；倒计时期间停止即放弃并恢复截图编辑（#129）。
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

    /// error为实际业务或系统错误；通过原生提示展示原因并同步应用明暗外观，不创建采集准备页面（#144 U-18）。
    private func showError(_ error: Error) {
        guard !shuttingDown else { return }
        let alert = NativeGlassFactory.applyAppearance(to: NSAlert())
        alert.alertStyle = .warning
        alert.messageText = "无法完成采集操作"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    /// 无参数；暂停并释放播放器对临时文件的引用，再由资源层处理清理。
    private func releasePlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerView?.player = nil
        player = nil
        playerSession = nil
    }

    /// 无参数；返回当前长图的源像素PNG。没有可保存结果时返回nil。
    private func scrollPNG() -> Data? {
        guard service.phase == .imageReady,
              let bytes = service.snapshot()["imageBytes"] as? FlutterStandardTypedData else { return nil }
        return bytes.data
    }

    /// call为当前会话的控制或结果操作；异步入口重复检查身份，不提供准备表单协议。
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
                        // 先反映到回包，避免异步暂停完成前把界面又刷回运行中。
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
                case AppConstants.trimRecordingMethod:
                    try await trim()
                case AppConstants.exportRecordingGIFMethod, AppConstants.exportRecordingAPNGMethod:
                    let format: GIFExporter.Format = call.method == AppConstants.exportRecordingGIFMethod ? .gif : .apng
                    let requestedAt = Date()
                    let source = try service.recordingURL()
                    let info = try await GIFExporter.metadata(source)
                    guard token == service.id else { throw GIFExporter.ExportError(message: "录制会话已失效。") }
                    // 每次导出读取已提交设置；GIF与APNG共用截图设置中的GIF参数，结果窗口不缓存另一份。
                    let settings = AppPreferences.current
                    let options = GIFExporter.Options(
                        framesPerSecond: settings[AppConstants.gifFramesPerSecondKey] as? Int ?? 10,
                        maximumWidth: settings[AppConstants.gifMaximumWidthKey] as? Int)
                    // 帧数上限按裁剪后的时长校验，超限在进入转换前直接失败。
                    _ = try options.validate(duration: service.trim?.duration.seconds ?? info.duration, sourceWidth: info.width)
                    let target = try outputURL(format.kind, date: requestedAt)
                    try service.exportAnimation(format, options: options, to: target)
                case AppConstants.exportRecordingWebMMethod:
                    // WebM 保持原分辨率与原帧时间，不读取GIF设置（#110）。
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
                    // 建目录与写文件在后台执行，不阻塞主线程（#68）；datedDirectory创建截图/日期目录，save按源像素写入，不经过裁剪编码。
                    let url = try await Task.detached {
                        let directory = try ScreenshotStorage.datedDirectory(basePath: basePath, category: .screenshot)
                        return try ScreenshotStorage.save(png, directory: directory, name: name)
                    }.value
                    // 写盘期间会话已更换时文件已保存，但不记到新会话上。
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

    /// kind为导出类型，date为点击操作时刻；返回分类日期路径，文件名与目录共用同一日期，扩展名按类型（APNG为png，WebM为webm）。
    private func outputURL(_ kind: RecordingExport, date: Date) throws -> URL {
        // datedDirectory统一创建媒体分类和日期目录，最终发布再处理同名冲突。
        let directory = try ScreenshotStorage.datedDirectory(
            basePath: UserDefaults.standard.string(forKey: AppConstants.screenshotSaveDirectoryKey),
            category: ScreenshotStorage.Category(kind), date: date)
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return directory.appendingPathComponent("录屏-\(formatter.string(from: date)).\(kind.fileExtension)")
    }

    /// id为Flutter结果身份；返回绑定当前完整视频的系统播放器，迟到视图不读取新会话。
    fileprivate func makePreview(id: String) -> NSView {
        let view = AVPlayerView()
        guard id == service.id, [.videoReady, .converting].contains(service.phase) else { return view }
        do {
            let url = try service.previewURL()
            if playerSession != id {
                releasePlayer()
                player = AVPlayer(url: url)
                playerSession = id
            }
            view.player = player
            view.controlsStyle = .floating
            playerView = view
        } catch { showError(error) }
        return view
    }

    /// 无参数；在结果页播放器中从裁剪起点播放到终点（未裁剪为完整视频），不另开窗口。
    private func preview() async throws {
        let token = service.id
        let url = try service.recordingURL()
        let info = try await GIFExporter.metadata(url)
        guard token == service.id else { throw GIFExporter.ExportError(message: "录制会话已失效。") }
        let range = service.trim ?? CMTimeRange(start: .zero, duration: CMTime(seconds: info.duration, preferredTimescale: 60000))
        let item = AVPlayerItem(url: url)
        // 新播放项沿用裁剪端点，再次进入裁剪时手柄停在上次确认的位置。
        item.reversePlaybackEndTime = range.start
        item.forwardPlaybackEndTime = range.end
        if player == nil { player = AVPlayer(); playerSession = token }
        player?.replaceCurrentItem(with: item)
        playerView?.player = player
        await player?.seek(to: range.start, toleranceBefore: .zero, toleranceAfter: .zero)
        guard token == service.id else { return }
        player?.play()
    }

    /// 无参数；让结果页播放器进入系统裁剪模式并等待用户操作。点「裁剪」把区间交给资源层，
    /// 首尾都未移动时恢复完整视频；点「取消」保持原裁剪（#110）。
    private func trim() async throws {
        let token = service.id
        _ = try service.recordingURL()
        guard let playerView, let item = player?.currentItem, playerView.canBeginTrimming else {
            throw GIFExporter.ExportError(message: "播放器尚未就绪，请稍后再试。")
        }
        player?.pause()
        let result = await playerView.beginTrimming()
        guard token == service.id, result == .okButton else { return }
        // 未设置的端点为无效时间，按视频起点或终点处理。
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
        try service.setTrim(start <= .zero && end >= item.duration ? nil : CMTimeRange(start: start, end: end))
    }

    /// 无参数；返回复制录制文件专用的应用临时剪贴板子目录，位于 NSTemporaryDirectory() 下。
    nonisolated static func recordingClipboardDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(AppConstants.recordingClipboardDirectoryName, isDirectory: true)
    }

    /// directory 为剪贴板临时子目录；清空上次启动残留的复制视频临时文件，无返回值（#68 第 10 条、#142）。
    nonisolated static func clearRecordingClipboardDirectory(at directory: URL = recordingClipboardDirectory()) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for entry in entries {
            try? fileManager.removeItem(at: entry)
        }
    }

    /// date 为点击复制时刻，directory 为目标剪贴板子目录；返回不冲突的「录屏-yyyyMMdd-HHmmss.mp4」文件 URL。
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

    /// 无参数；拷贝完整视频或当前裁剪片段到应用剪贴板临时目录，并把文件 URL 写入系统剪贴板，结果窗关闭后仍可粘贴（#142）。
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

/// Flutter结果页的系统视频视图工厂；创建视图发生在Flutter的macOS主线程。
private final class CapturePreviewFactory: NSObject, FlutterPlatformViewFactory {
    private weak var owner: CaptureWindowController?

    /// owner为媒体资源协调者；工厂不延长工具会话寿命。
    init(owner: CaptureWindowController) { self.owner = owner }

    /// 无参数；返回与Dart创建参数相同的标准编解码器。
    func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? { FlutterStandardMessageCodec.sharedInstance() }

    /// viewId由Flutter分配，args含会话id；返回主线程创建的AVPlayerView。
    func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
        MainActor.assumeIsolated {
            guard let id = (args as? [String: Any])?["id"] as? String, let owner else { return NSView() }
            return owner.makePreview(id: id)
        }
    }
}

/// 采集悬浮条的非激活面板；按钮可接收键盘，采集不抢主应用。
private final class CaptureControlPanel: NSPanel {
    /// 无参数；允许用户点击后的键盘输入，不主动将本应用变成主窗口。
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 录制中的实时选区阴影；不持有冻结图像，不处理输入，绘制内容被系统捕获过滤器排除。
final class CaptureShadeView: NSView {
    private static let flowAnimationKey = "recordingBorderFlow"

    /// 应用窗口的本屏局部矩形并集；nil表示普通区域遮罩，空数组表示本屏无应用窗口。
    var contentRects: [NSRect]? {
        didSet {
            guard contentRects != oldValue else { return }
            needsDisplay = true
            syncFlowLayer()
        }
    }
    /// selection为本显示器局部点坐标；变化后重绘阴影和1pt选区边框。
    var selection = NSRect.zero {
        didSet {
            guard selection != oldValue else { return }
            needsDisplay = true
            syncFlowLayer()
        }
    }
    /// 是否绘制区域录制流光边框（#142，#67 第 9 条）；仅区域录制开启，窗口/长截图与截图预览关闭。
    var flowsBorder = false {
        didSet {
            guard flowsBorder != oldValue else { return }
            syncFlowLayer()
        }
    }
    /// 区域录制流光是否暂停在当前位置（#142）；暂停时图层 speed 为 0，恢复时保持相位接着流动。
    var flowPaused = false {
        didSet {
            guard flowPaused != oldValue else { return }
            syncFlowPause()
        }
    }
    /// 读取系统「减少动态效果」设置；测试可覆写以隔离系统偏好。
    var isReduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private(set) var flowLayer: CAShapeLayer?
    private var flowSize = NSSize.zero
    private(set) var hintView: NativeGlassContainerView?
    private var hintGeneration = 0

    /// 无参数；外观变化时把最新系统强调色同步到区域录制流光层，无返回值。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let flowLayer { applyFlowAppearance(to: flowLayer) }
    }

    /// layer 为区域流光形状层；按当前有效外观写入强调色描边与外发光，无返回值。
    private func applyFlowAppearance(to layer: CAShapeLayer) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor.cgColor
            layer.strokeColor = accent
            layer.shadowColor = accent
        }
    }

    /// 无参数；按区域录制状态与减少动态效果设置创建、更新或移除 CAShapeLayer 流光边框，无返回值。
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
            // 仅在首次创建或选区尺寸改变时重建相位动画；先复原时间轴，再应用暂停状态。
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

    /// 无参数；暂停时置 speed=0 并锁定 timeOffset，恢复时从原相位继续流动，无返回值。
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

    /// text为长截图过程提示，isError选择错误语义色并附加错误图标；visible为本屏可用区、avoiding为控制面板和缩略图（均为本视图坐标）。
    /// 按选区上、下、左、右寻找距选区8pt的位置，都放不下才放在选区正中央；错误提示显示2000ms、普通提示显示1000ms，极窄选区回退可用区宽度（#144 U-32）。
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
        // 极窄选区不压成 1pt 竖条；保持常规窄选区宽度不越出选区，极端狭小则退回可用区域宽。
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
        // 常规滚动引导使用中等播报优先级避免持续打断；错误提示维持高优先级。
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

    /// outside/inside为选区外与居中时的提示外框尺寸；返回第一个完整位于可用区、离选区8pt且不压住避让区的位置，
    /// 顺序为上、下、左、右，均不可用时居中于选区并夹紧进可用区，避免极端窄选区推出屏外（#144 U-32）。
    static func hintFrame(outside: NSSize, inside: NSSize, selection: NSRect, visible: NSRect, avoiding: [NSRect]) -> NSRect {
        let gap = AppConstants.captureControlGap
        let width = outside.width
        let height = outside.height
        /// value为期望坐标；沿选区边平移进可用区，不改变与选区的8pt间距。
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

    /// text/isError为提示内容与语义；返回正文13/18、居中的富文本；输入翻译失败气泡共用（#99）。
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

    /// text为提示，width为可用文字宽；返回换行后的整点文字尺寸，宽度不超过width。
    static func hintTextSize(_ text: String, width: CGFloat) -> NSSize {
        let bounds = hintText(text, isError: false).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(min(bounds.width, width)), height: max(18, ceil(bounds.height)))
    }

    /// dirtyRect为系统重绘范围；在选区外输出60%黑色，选区内部保持透明。
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        if let contentRects {
            // 先绘制遮罩，再以clear逐个开孔，重叠窗口也保持透明。
            NSColor.black.withAlphaComponent(AppConstants.captureShadeOpacity).setFill()
            bounds.fill()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            for rect in contentRects { rect.fill() }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.controlAccentColor.setStroke()
            for rect in contentRects { NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke() }
        } else {
            path.appendRect(selection)
            path.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(AppConstants.captureShadeOpacity).setFill()
            path.fill()
        }
        let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        border.stroke()
    }
}

/// 长截图实时缩略图：统一 NativeGlassContainerView（r8，同步透明度与减少透明度降级）、4pt内边距，图像圆角4pt，回退目标用2pt错误语义色框标出；不接收鼠标（#144 U-32）。
final class ScrollPreviewView: NSView {
    private let glassContainer: NativeGlassContainerView
    private let content = NSView()
    let imageView = NSImageView()
    let targetView = NSView()

    /// 无参数；创建空缩略图容器，update后才有尺寸。
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

    /// preview为长图底部缩略图像素，scale为所在屏倍率；更新图像与回退目标框，返回含内边距的外框尺寸。
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
            // 目标框为图像像素、顶部原点；换成AppKit点坐标后叠在图像上。
            targetView.layer?.borderColor = NSColor.systemRed.cgColor
            targetView.frame = NSRect(x: inset + target.minX / scale, y: inset + size.height - target.maxY / scale,
                                      width: target.width / scale, height: target.height / scale)
            targetView.isHidden = false
        } else { targetView.isHidden = true }
        return frame.size
    }

    /// point为窗口坐标；缩略图只展示，鼠标穿透到来源应用。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
