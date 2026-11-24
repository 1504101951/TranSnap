import AppKit
import FlutterMacOS

/// 菜单栏入口，提供设置、仅使用快捷键开关、辅助功能授权和退出操作。
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var installed = false
    private var automaticItem: NSMenuItem?
    private var accessItem: NSMenuItem?
    private var screenRecordingItem: NSMenuItem?
    private var screenshotItem: NSMenuItem?
    private var stopCaptureItem: NSMenuItem?
    /// 显示器子菜单在菜单打开时重建（#105）。
    private var displayMenu: NSMenu?
    /// 录制倒计时的剩余秒数；没有倒计时时为 nil（#129）。
    private var countdown: Int?
    private var liveAbort = false
    private var captureActive = false
    private var automaticEnabled = true
    /// 执行中或仍在最短保持时间内的 MCP 截图数；大于 0 时显示采集图标。
    private var mcpCaptures = 0
    /// MCP 操控会话进行中时的终止回调；非 nil 时显示操控图标，菜单首项为「停止操控」（#140）。
    private var stopControl: (() -> Void)?
    private var abortLiveTranslation: (() -> Void)?
    var showSettings: (() -> Void)?
    var refreshSettings: (() -> Void)?
    var showHistory: (() -> Void)?

    /// 无参数；首次调用创建菜单栏图标与菜单，重复调用保持现有实例，无返回值。
    func install() {
        if installed { return }
        installed = true

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        item.button?.imagePosition = .imageOnly
        // 图标独占菜单栏方形位置，名称仍通过悬停与辅助功能提供。
        item.button?.title = ""
        statusItem = item
        syncStatusButton()
        reloadMenu()
        // 刚创建时窗口高度可能是 0，下一拍再强制显示。
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.isVisible = true
        }
    }

    /// 无参数；按实时翻译、操控会话、双权限授权及快捷键配置重建菜单并始终挂载（#144 U-30）。
    func reloadMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        if liveAbort {
            // 实时翻译运行期间保留精简应急菜单，确保「停止操控」「设置」「历史」「退出」均可触达。
            automaticItem = nil
            accessItem = nil
            screenRecordingItem = nil
            screenshotItem = nil
            stopCaptureItem = nil
            displayMenu = nil

            let abortItem = NSMenuItem(title: "停止实时翻译", action: #selector(abortLive), keyEquivalent: "")
            abortItem.target = self
            abortItem.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "停止实时翻译")
            menu.addItem(abortItem)

            if stopControl != nil {
                let stop = NSMenuItem(title: "停止操控", action: #selector(stopComputerControl), keyEquivalent: "")
                stop.target = self
                stop.image = NSImage(systemSymbolName: AppConstants.controlSymbol, accessibilityDescription: "停止操控")
                menu.addItem(stop)
            }

            menu.addItem(.separator())
            let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
            settings.target = self
            menu.addItem(settings)
            let history = NSMenuItem(title: "翻译历史…", action: #selector(openHistory), keyEquivalent: "")
            history.target = self
            menu.addItem(history)
            menu.addItem(.separator())
            let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
            statusItem?.menu = menu
            return
        }

        if stopControl != nil {
            // 操控期间菜单首项为「停止操控」（#67「电脑操控提示」）。
            let stop = NSMenuItem(title: "停止操控", action: #selector(stopComputerControl), keyEquivalent: "")
            stop.target = self
            stop.image = NSImage(systemSymbolName: AppConstants.controlSymbol, accessibilityDescription: "停止操控")
            menu.addItem(stop)
            menu.addItem(.separator())
        }
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        // 截图编辑工具栏承载媒体工具，菜单栏保留普通截图、捕获选项和采集停止。
        let screenshot = NSMenuItem(title: "区域截图…", action: #selector(captureScreenshot), keyEquivalent: "")
        screenshot.target = self
        screenshotItem = screenshot
        applyScreenshotShortcut()
        menu.addItem(screenshot)

        let displays = NSMenuItem(title: "截取显示器", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        displayMenu.autoenablesItems = false
        displays.submenu = displayMenu
        self.displayMenu = displayMenu
        menu.addItem(displays)
        let image = NSMenuItem(title: "打开图片…", action: #selector(openImage), keyEquivalent: "")
        image.target = self
        menu.addItem(image)
        let clipboard = NSMenuItem(title: "从剪贴板打开图片", action: #selector(openClipboardImage), keyEquivalent: "")
        clipboard.target = self
        menu.addItem(clipboard)
        let stop = NSMenuItem(title: "停止采集", action: #selector(stopCapture), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = MacPlatformBridge.Shared.instance?.capture.canStop == true
        stopCaptureItem = stop
        menu.addItem(stop)
        menu.addItem(.separator())
        let history = NSMenuItem(title: "翻译历史…", action: #selector(openHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(history)
        let automatic = NSMenuItem(title: "仅使用快捷键", action: #selector(toggleAutomatic), keyEquivalent: "")
        automatic.target = self
        automatic.state = automaticEnabled ? .off : .on
        automaticItem = automatic
        menu.addItem(automatic)
        menu.addItem(.separator())

        let trusted = AccessibilitySelection.isTrusted(prompt: false)
        let access = NSMenuItem(title: "", action: #selector(requestAccess), keyEquivalent: "")
        accessItem = access
        access.target = self
        applyAccessState(to: access, trusted: trusted)
        menu.addItem(access)

        let screenAuthorized = ScreenCaptureService.isAuthorized()
        let screenItem = NSMenuItem(title: "", action: #selector(requestScreenCapture), keyEquivalent: "")
        screenRecordingItem = screenItem
        screenItem.target = self
        applyScreenCaptureState(to: screenItem, authorized: screenAuthorized)
        menu.addItem(screenItem)

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    /// active 为实时翻译正在运行，abort 为结束并保留结果回调；保留精简菜单并将图标切换为停止样式，无返回值（#144 U-30）。
    func setLiveAbort(_ active: Bool, abort: (() -> Void)? = nil) {
        liveAbort = active
        abortLiveTranslation = abort
        syncStatusButton()
        reloadMenu()
    }

    /// 无参数。菜单栏中止执行结束语义，不放弃本次结果。
    /// 作用：MCP 截图开始，菜单栏图标换为采集图标（#96 待确认值：camera.viewfinder，至少保持 1000ms）。
    /// 实时翻译的中止图标优先，期间不切换图标。
    /// 返回：截图结束时调用的回调；到达最短保持时间后计数减一，无进行中截图时恢复普通图标。
    func beginMCPCapture() -> () -> Void {
        mcpCaptures += 1
        syncStatusButton()
        let started = ContinuousClock.now
        return { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(until: started + AppConstants.mcpCaptureIndicatorMinimum, clock: .continuous)
                guard let self else { return }
                self.mcpCaptures = max(0, self.mcpCaptures - 1)
                self.syncStatusButton()
            }
        }
    }

    /// active 为 MCP 操控会话是否进行中，stop 为「停止操控」执行的终止；更新图标与菜单，无返回值（#140）。
    func setControlActive(_ active: Bool, stop: (() -> Void)?) {
        stopControl = active ? stop : nil
        syncStatusButton()
        reloadMenu()
    }

    @objc private func stopComputerControl() {
        stopControl?()
    }

    /// 无参数；统一根据当前优先级状态同步菜单栏图标、悬停提示与无障碍名称，避免状态切换遗漏（#144 U-30）。
    private func syncStatusButton() {
        guard let button = statusItem?.button else { return }
        button.title = ""
        button.action = nil
        button.target = nil

        let symbolName: String
        let description: String
        if liveAbort {
            symbolName = "stop.circle"
            description = stopControl != nil
                ? "TranSnap，实时翻译与操控运行中"
                : "TranSnap，实时翻译运行中"
        } else if let countdown {
            symbolName = "\(countdown).circle"
            description = "TranSnap，录制倒计时 \(countdown) 秒"
        } else if stopControl != nil {
            symbolName = AppConstants.controlSymbol
            description = "TranSnap，模型操控中"
        } else if captureActive {
            symbolName = mcpCaptures > 0 ? AppConstants.mcpCaptureSymbol : "translate"
            description = "TranSnap，采集中"
        } else if mcpCaptures > 0 {
            symbolName = AppConstants.mcpCaptureSymbol
            description = "TranSnap，agent 截图中"
        } else {
            symbolName = "translate"
            description = "TranSnap"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    @objc private func abortLive() {
        abortLiveTranslation?()
    }

    /// enabled 为主 Dart 已成功保存的自动按钮设置；更新菜单状态，无返回值。
    func updateAutomatic(_ enabled: Bool) {
        automaticEnabled = enabled
        // 菜单勾选表示仅使用快捷键，与底层自动捕获状态相反。
        automaticItem?.state = enabled ? .off : .on
    }

    /// menu 为即将展示的菜单；即时读取双权限、快捷键、采集停止能力与显示器列表，无返回值（#144 U-30）。
    func menuWillOpen(_ menu: NSMenu) {
        guard !liveAbort else { return }
        stopCaptureItem?.isEnabled = MacPlatformBridge.Shared.instance?.capture.canStop == true
        applyScreenshotShortcut()
        // 显示器可能在两次打开菜单之间接入或断开，按当前系统顺序重建。
        displayMenu?.removeAllItems()
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let item = NSMenuItem(title: screen.localizedName, action: #selector(captureDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(id)
            displayMenu?.addItem(item)
        }
        let trusted = AccessibilitySelection.isTrusted(prompt: false)
        if let accessItem { applyAccessState(to: accessItem, trusted: trusted) }
        let screenAuthorized = ScreenCaptureService.isAuthorized()
        if let screenRecordingItem { applyScreenCaptureState(to: screenRecordingItem, authorized: screenAuthorized) }
    }

    /// item 为辅助功能菜单项，trusted 为是否已获得辅助功能权限；已授权时显示已开启且不可点，无返回值。
    private func applyAccessState(to item: NSMenuItem, trusted: Bool) {
        item.title = trusted ? "辅助功能已开启" : "授予辅助功能权限…"
        item.isEnabled = !trusted
    }

    /// item 为屏幕录制菜单项，authorized 为是否已获得屏幕录制权限；已授权时显示已开启且不可点，无返回值（#144 U-30）。
    private func applyScreenCaptureState(to item: NSMenuItem, authorized: Bool) {
        item.title = authorized ? "屏幕录制已开启" : "授予屏幕录制权限…"
        item.isEnabled = !authorized
    }

    /// 无参数；将已保存的区域截图快捷键同步到菜单项标题或原生键等效符，刷新前先还原基础标题避免重复拼接。
    private func applyScreenshotShortcut() {
        guard let screenshotItem else { return }
        screenshotItem.title = "区域截图…"
        screenshotItem.keyEquivalent = ""
        screenshotItem.keyEquivalentModifierMask = []
        guard let formatted = GlobalHotKey.screenshot.formattedShortcut(in: AppPreferences.current) else {
            return
        }
        if !formatted.titleSuffix.isEmpty {
            screenshotItem.title = "区域截图…\(formatted.titleSuffix)"
        } else {
            screenshotItem.keyEquivalent = formatted.keyEquivalent
            screenshotItem.keyEquivalentModifierMask = formatted.modifiers
        }
    }

    /// 无参数；打开普通设置窗口，无返回值。
    @objc private func openSettings() { showSettings?() }

    /// 无参数；打开翻译历史窗口，无返回值。
    @objc private func openHistory() { showHistory?() }

    /// 无参数；菜单关闭后进入系统区域框选，不触发翻译，无返回值。
    @objc private func captureScreenshot() {
        DispatchQueue.main.async { MacPlatformBridge.Shared.instance?.screenshot.capture() }
    }

    /// 无参数；菜单关闭后选择图片并交给现有编辑器，无返回值。
    @objc private func openImage() {
        DispatchQueue.main.async { MacPlatformBridge.Shared.instance?.screenshot.openImage() }
    }

    /// 无参数；菜单关闭后把剪贴板图片交给现有编辑器，无返回值。
    @objc private func openClipboardImage() {
        DispatchQueue.main.async { MacPlatformBridge.Shared.instance?.screenshot.openClipboardImage() }
    }

    /// sender 的 tag 为显示器 ID；冻结该显示器并选中整屏，无返回值（#105）。
    @objc private func captureDisplay(_ sender: NSMenuItem) {
        let id = CGDirectDisplayID(sender.tag)
        DispatchQueue.main.async { MacPlatformBridge.Shared.instance?.screenshot.capture(.display(id)) }
    }

    /// remaining 为录制倒计时剩余秒数，nil 表示没有倒计时；同步更新图标、悬停提示与无障碍文本，无返回值（#129、#144 U-30）。
    func showCountdown(_ remaining: Int?) {
        guard countdown != remaining else { return }
        countdown = remaining
        syncStatusButton()
    }

    /// active 为连续采集状态；记录采集标志并经统一出口更新图标提示与停止能力，保持入口宽度不变（#144 U-30）。
    func setCaptureActive(_ active: Bool) {
        captureActive = active
        syncStatusButton()
        stopCaptureItem?.isEnabled = MacPlatformBridge.Shared.instance?.capture.canStop == true
    }

    /// 无参数；请求当前采集正常结束，编码完成前不发布文件。
    @objc private func stopCapture() { MacPlatformBridge.Shared.instance?.capture.stop() }

    /// 无参数；经主 Dart 修改全局开关，成功后刷新设置窗口，失败弹窗继承当前应用明暗外观（#144 U-18）。
    @objc private func toggleAutomatic() {
        // requestApplication把菜单开关交给主引擎唯一设置队列。
        MacPlatformBridge.Shared.instance?.requestApplication(AppConstants.toggleAutomaticMethod) { [weak self] value in
            if let error = value as? FlutterError {
                let alert = NativeGlassFactory.applyAppearance(to: NSAlert())
                alert.alertStyle = .warning
                alert.messageText = "设置未保存"
                alert.informativeText = error.message ?? error.code
                alert.runModal()
                return
            }
            self?.refreshSettings?()
        }
    }

    /// 无参数；已授权则只刷新菜单，未授权才弹出系统提示并打开设置。
    @objc private func requestAccess() {
        if AccessibilitySelection.isTrusted(prompt: false) {
            reloadMenu()
            return
        }
        _ = AccessibilitySelection.isTrusted(prompt: true)
        AccessibilitySelection.openSettings()
    }

    /// 无参数；申请或打开系统「屏幕录制」授权设置，并刷新菜单项状态（#144 U-30）。
    @objc private func requestScreenCapture() {
        if ScreenCaptureService.isAuthorized() {
            reloadMenu()
            return
        }
        Task { @MainActor [weak self] in
            _ = await ScreenCaptureService.requestAccess(promoteToRegularApp: true)
            if !ScreenCaptureService.isAuthorized() {
                ScreenCaptureService.openScreenRecordingSettings()
            }
            self?.reloadMenu()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

}
