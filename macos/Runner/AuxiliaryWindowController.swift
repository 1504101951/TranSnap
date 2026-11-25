import Cocoa
import FlutterMacOS

final class AuxiliaryWindowController: NSObject, NSWindowDelegate {
    private var engine: FlutterEngine?
    private var window: NSWindow?
    private var channel: FlutterMethodChannel?
    private var pendingStartup: WindowEngine.Startup?
    private let engineName: String
    private let entrypoint: String
    private let title: String
    private let size: NSSize
    private let minSize: NSSize?
    private let autosaveName: NSWindow.FrameAutosaveName?
    private let refreshMethod: String?
    private let refreshesOnFocus: Bool
    private let compactTitlebar: Bool

    init(engineName: String, entrypoint: String, title: String, size: NSSize,
         minSize: NSSize? = nil, autosaveName: NSWindow.FrameAutosaveName? = nil,
         refreshMethod: String? = nil, refreshesOnFocus: Bool = false, compactTitlebar: Bool = false) {
        self.engineName = engineName
        self.entrypoint = entrypoint
        self.title = title
        self.size = size
        self.minSize = minSize
        self.autosaveName = autosaveName
        self.refreshMethod = refreshMethod
        self.refreshesOnFocus = refreshesOnFocus
        self.compactTitlebar = compactTitlebar
        super.init()
    }

    func show() {
        if let window {
            refresh()
            WindowEngine.present(window)
            return
        }
        guard pendingStartup == nil else { return }
        pendingStartup = WindowEngine.start(
            name: engineName, entrypoint: entrypoint, channel: AppConstants.settingsChannel,
            handler: { [weak self] call, result in
                if call.method == AppConstants.setWindowTitleMethod {
                    guard let arguments = call.arguments as? [String: Any],
                          let title = arguments["title"] as? String else {
                        result(FlutterError(code: AppConstants.badArgsError, message: "缺少窗口标题", details: nil))
                        return
                    }
                    self?.window?.title = title
                    result(nil)
                    return
                }
                if call.method == AppConstants.startWindowDragMethod {
                    WindowEngine.beginDrag(self?.window)
                    result(nil)
                    return
                }
                let bridge = MacPlatformBridge.Shared.instance!
                bridge.routeWindowRequest(call, result: result)
            }, completion: { [weak self] started in
                guard let self else { return }
                self.pendingStartup = nil
                guard let started else {
                    WindowEngine.reportStartFailure("\(self.title)窗口")
                    return
                }
                self.engine = started.engine
                self.channel = started.channel
                let window = WindowEngine.makeWindow(
                    flutter: started.flutter, title: self.title, size: self.size,
                    minSize: self.minSize, delegate: self, autosaveName: self.autosaveName,
                    fullSizeTitlebar: self.compactTitlebar, compactToolbar: self.compactTitlebar)
                self.window = window
                WindowEngine.present(window)
            })
    }

    func refresh() {
        guard let refreshMethod else { return }
        channel?.invokeMethod(refreshMethod, arguments: nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard refreshesOnFocus else { return }
        refresh()
    }

    func close() {
        pendingStartup?.cancel()
        pendingStartup = nil
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let window { DockPresence.leave(window) }
        pendingStartup?.cancel()
        pendingStartup = nil
        channel?.setMethodCallHandler(nil)
        engine?.shutDownEngine()
        engine = nil
        channel = nil
        window = nil
    }

    deinit {
        pendingStartup?.cancel()
        channel?.setMethodCallHandler(nil)
        engine?.shutDownEngine()
    }
}
