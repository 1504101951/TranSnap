import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    private let settingsWindow = SettingsWindowController()
    private let permissionWizard = AuxiliaryWindowController(
        engineName: AppConstants.permissionWizardEngineName,
        entrypoint: AppConstants.permissionWizardEntrypoint,
        title: "授权",
        size: NSSize(width: 480, height: 360),
        minSize: AppConstants.permissionWizardMinSize,
        refreshMethod: AppConstants.permissionStatusChangedMethod,
        refreshesOnFocus: true
    )
    private let historyWindow = AuxiliaryWindowController(
        engineName: AppConstants.historyEngineName,
        entrypoint: AppConstants.historyEntrypoint,
        title: "翻译历史",
        size: NSSize(width: 520, height: 640),
        minSize: AppConstants.historyWindowMinSize,
        autosaveName: AppConstants.historyWindowAutosaveName,
        refreshMethod: AppConstants.historyChangedMethod,
        compactTitlebar: true
    )
    private var launchedAtLogin = false
    private var historyObserver: NSObjectProtocol?

    override func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = event?.eventID == kAEOpenApplication &&
            event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
    private var flutterViewController: FlutterViewController?
    private let overlay = OverlayPanelController()
    private let selectionMonitor = SelectionMonitor()

    override func applicationDidFinishLaunching(_ notification: Notification) {
        let launchStart = ContinuousClock.now
        defer { PerformanceLog.record("launch-finish", since: launchStart) }
        let flutter = FlutterViewController()
        flutterViewController = flutter
        _ = flutter.view
        _ = flutter.engine.run(withEntrypoint: nil)
        PerformanceLog.record("launch-engine-run", since: launchStart)
        RegisterGeneratedPlugins(registry: flutter)
        NativeGlassFactory.register(with: flutter)
        overlay.attachFlutter(flutter)
        let bridge = MacPlatformBridge.register(
            with: flutter.engine.binaryMessenger,
            overlay: overlay,
            selectionMonitor: selectionMonitor
        )

        hideMainWindowOnly()
        StatusBarController.shared.showSettings = { [weak self] in self?.settingsWindow.show() }
        StatusBarController.shared.refreshSettings = { [weak self] in self?.settingsWindow.refresh() }
        StatusBarController.shared.showHistory = { [weak self] in self?.historyWindow.show() }
        StatusBarController.shared.install()
        bridge.closePermissionWizard = { [weak self] in self?.permissionWizard.close() }
        historyObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.historyChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.historyWindow.refresh() }
        bridge.onReady = { [weak self, weak bridge] in
            bridge?.screenshot.prewarm()
            ScreenCaptureService.prewarmTextRecognition()
            let access = AccessibilitySelection.isTrusted(prompt: false)
            let screen = ScreenCaptureService.isAuthorized()
            if access && screen {
                UserDefaults.standard.set(true, forKey: AppConstants.permissionWizardFinishedKey)
                if self?.launchedAtLogin == false { self?.settingsWindow.show() }
                return
            }
            self?.permissionWizard.show()
        }
        selectionMonitor.start()
        Task.detached(priority: .utility) {
            CaptureWindowController.clearRecordingClipboardDirectory()
        }
        bridge.mcp.start(path: MCPSocket.defaultURL.path)
    }

    override func applicationDidBecomeActive(_ notification: Notification) {
        permissionWizard.refresh()
    }

    override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let capture = MacPlatformBridge.Shared.instance?.capture else { return .terminateNow }
        if capture.hasPendingCapture {
            let alert = NativeGlassFactory.applyAppearance(to: NSAlert())
            alert.messageText = "退出并丢弃当前采集？"
            alert.informativeText = "未保存的录制或长图将被删除。已经保存的文件会保留。"
            alert.addButton(withTitle: "返回采集")
            alert.addButton(withTitle: "退出并丢弃")
            guard alert.runModal() == .alertSecondButtonReturn else {
                capture.present(force: true)
                return .terminateCancel
            }
        }
        settingsWindow.shutdown()
        permissionWizard.close()
        historyWindow.close()
        Task { @MainActor in
            await capture.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    override func applicationWillTerminate(_ notification: Notification) {
        MacPlatformBridge.Shared.instance?.screenshot.shutdown()
    }

    override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    private func hideMainWindowOnly() {
        for window in NSApp.windows where window is MainFlutterWindow {
            window.orderOut(nil)
        }
    }
}
