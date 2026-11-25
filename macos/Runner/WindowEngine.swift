import AppKit
import FlutterMacOS

enum WindowEngine {
    typealias Started = (engine: FlutterEngine, flutter: FlutterViewController, channel: FlutterMethodChannel)

    final class Startup {
        private enum State { case waiting, succeeded, failed, cancelled }
        private var state = State.waiting
        private var resources: Started?
        private var acknowledgement: FlutterMethodChannel?
        private var deadline: DispatchWorkItem?
        private var completion: ((Started?) -> Void)?

        fileprivate init(name: String, entrypoint: String, channel: String,
                         handler: @escaping FlutterMethodCallHandler,
                         completion: @escaping (Started?) -> Void) {
            precondition(Thread.isMainThread)
            self.completion = completion
            let engine = FlutterEngine(name: name, project: nil, allowHeadlessExecution: false)
            let methods = FlutterMethodChannel(name: channel, binaryMessenger: engine.binaryMessenger)
            methods.setMethodCallHandler(handler)
            let flutter = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
            resources = (engine, flutter, methods)
            let acknowledgement = FlutterMethodChannel(
                name: AppConstants.windowStartupChannel, binaryMessenger: engine.binaryMessenger)
            self.acknowledgement = acknowledgement
            acknowledgement.setMethodCallHandler { [weak self] call, reply in
                guard call.method == AppConstants.windowReadyMethod else {
                    reply(FlutterMethodNotImplemented)
                    return
                }
                reply(nil)
                DispatchQueue.main.async { [weak self] in self?.finish(succeeded: true) }
            }
            DispatchQueue.main.async { [weak self] in self?.run(entrypoint: entrypoint) }
        }

        private func run(entrypoint: String) {
            guard state == .waiting, let resources else { return }
            let deadline = DispatchWorkItem { [weak self] in self?.finish(succeeded: false) }
            self.deadline = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + AppConstants.windowStartupTimeout, execute: deadline)
            guard resources.engine.run(withEntrypoint: entrypoint) else {
                finish(succeeded: false)
                return
            }
            RegisterGeneratedPlugins(registry: resources.flutter)
            NativeGlassFactory.register(with: resources.flutter)
        }

        private func finish(succeeded: Bool) {
            precondition(Thread.isMainThread)
            guard state == .waiting else { return }
            state = succeeded ? .succeeded : .failed
            deadline?.cancel()
            deadline = nil
            acknowledgement?.setMethodCallHandler(nil)
            acknowledgement = nil
            let delivered = succeeded ? resources : nil
            if !succeeded { releaseResources() }
            resources = nil
            let callback = completion
            completion = nil
            callback?(delivered)
        }

        func cancel() {
            precondition(Thread.isMainThread)
            guard state == .waiting else { return }
            state = .cancelled
            deadline?.cancel()
            deadline = nil
            acknowledgement?.setMethodCallHandler(nil)
            acknowledgement = nil
            completion = nil
            releaseResources()
        }

        private func releaseResources() {
            resources?.channel.setMethodCallHandler(nil)
            resources?.engine.shutDownEngine()
            resources = nil
        }

        deinit { cancel() }
    }

    static func start(name: String, entrypoint: String, channel: String,
                      handler: @escaping FlutterMethodCallHandler,
                      completion: @escaping (Started?) -> Void) -> Startup {
        Startup(name: name, entrypoint: entrypoint, channel: channel, handler: handler, completion: completion)
    }

    static func beginDrag(_ window: NSWindow?) {
        guard let window, let event = NSApp.currentEvent else { return }
        window.performDrag(with: event)
    }

    static func makeWindow(flutter: FlutterViewController, title: String, size: NSSize, minSize: NSSize?,
                           delegate: NSWindowDelegate,
                           autosaveName: NSWindow.FrameAutosaveName? = nil,
                           fullSizeTitlebar: Bool = false,
                           compactToolbar: Bool = false) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.delegate = delegate
        window.title = title
        if fullSizeTitlebar {
            window.titleVisibility = .hidden
        }
        if compactToolbar {
            window.toolbar = NSToolbar()
            window.toolbarStyle = .unifiedCompact
        }
        if let minSize { window.minSize = minSize }
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        NativeGlassFactory.installContent(flutter, in: window, edgeToEdgeTop: fullSizeTitlebar)
        window.setContentSize(size)
        if let autosaveName {
            let restored = window.setFrameUsingName(autosaveName)
            window.setFrameAutosaveName(autosaveName)
            if !restored { window.center() }
        } else {
            window.center()
        }
        return window
    }

    static func present(_ window: NSWindow) {
        DockPresence.enter(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func reportStartFailure(_ name: String) {
        let alert = NativeGlassFactory.applyAppearance(to: NSAlert())
        alert.alertStyle = .warning
        alert.messageText = "\(name)启动失败"
        let supportURL = AppConstants.applicationSupportURL
        alert.informativeText = """
        无法在 \(Int(AppConstants.windowStartupTimeout)) 秒内完成\(name)初始化。

        请退出并重新打开 TranSnap；若问题反复出现，可打开数据目录查看日志：
        \(supportURL.path)
        """
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "打开数据目录")
        if alert.runModal() == .alertSecondButtonReturn {
            let target = FileManager.default.fileExists(atPath: supportURL.path)
                ? supportURL
                : supportURL.deletingLastPathComponent()
            NSWorkspace.shared.open(target)
        }
    }
}
