import AppKit
import FlutterMacOS

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
    private var displayMenu: NSMenu?
    private var countdown: Int?
    private var liveAbort = false
    private var captureActive = false
    private var automaticEnabled = true
    private var mcpCaptures = 0
    private var stopControl: (() -> Void)?
    private var abortLiveTranslation: (() -> Void)?
    var showSettings: (() -> Void)?
    var refreshSettings: (() -> Void)?
    var showHistory: (() -> Void)?

    func install() {
        if installed { return }
        installed = true

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        item.button?.imagePosition = .imageOnly
        item.button?.title = ""
        statusItem = item
        syncStatusButton()
        reloadMenu()
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.isVisible = true
        }
    }

    func reloadMenu() {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        if liveAbort {
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

    func setLiveAbort(_ active: Bool, abort: (() -> Void)? = nil) {
        liveAbort = active
        abortLiveTranslation = abort
        syncStatusButton()
        reloadMenu()
    }

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

    func setControlActive(_ active: Bool, stop: (() -> Void)?) {
        stopControl = active ? stop : nil
        syncStatusButton()
        reloadMenu()
    }

    @objc private func stopComputerControl() {
        stopControl?()
    }

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

    func updateAutomatic(_ enabled: Bool) {
        automaticEnabled = enabled
        automaticItem?.state = enabled ? .off : .on
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard !liveAbort else { return }
        stopCaptureItem?.isEnabled = MacPlatformBridge.Shared.instance?.capture.canStop == true
        applyScreenshotShortcut()
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

    private func applyAccessState(to item: NSMenuItem, trusted: Bool) {
        item.title = trusted ? "辅助功能已开启" : "授予辅助功能权限…"
        item.isEnabled = !trusted
    }

    private func applyScreenCaptureState(to item: NSMenuItem, authorized: Bool) {
        item.title = authorized ? "屏幕录制已开启" : "授予屏幕录制权限…"
        item.isEnabled = !authorized
    }

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

    @objc private func openSettings() { showSettings?() }

    @objc private func openHistory() { showHistory?() }

    @objc private func captureScreenshot() {
        DispatchQueue.main.async { MacPlatformBridge.Shared.instance?.screenshot.capture() }
    }

    @objc private func openImage() {
        DispatchQueue.main.async { MacPlatformBridge.Shared.instance?.screenshot.openImage() }
    }

    @objc private func openClipboardImage() {
        DispatchQueue.main.async { MacPlatformBridge.Shared.instance?.screenshot.openClipboardImage() }
    }

    @objc private func captureDisplay(_ sender: NSMenuItem) {
        let id = CGDirectDisplayID(sender.tag)
        DispatchQueue.main.async { MacPlatformBridge.Shared.instance?.screenshot.capture(.display(id)) }
    }

    func showCountdown(_ remaining: Int?) {
        guard countdown != remaining else { return }
        countdown = remaining
        syncStatusButton()
    }

    func setCaptureActive(_ active: Bool) {
        captureActive = active
        syncStatusButton()
        stopCaptureItem?.isEnabled = MacPlatformBridge.Shared.instance?.capture.canStop == true
    }

    @objc private func stopCapture() { MacPlatformBridge.Shared.instance?.capture.stop() }

    @objc private func toggleAutomatic() {
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

    @objc private func requestAccess() {
        if AccessibilitySelection.isTrusted(prompt: false) {
            reloadMenu()
            return
        }
        _ = AccessibilitySelection.isTrusted(prompt: true)
        AccessibilitySelection.openSettings()
    }

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
