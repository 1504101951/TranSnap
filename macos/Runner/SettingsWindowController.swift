import Carbon
import Cocoa
import FlutterMacOS

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var engine: FlutterEngine?
    private var window: NSWindow?
    private var channel: FlutterMethodChannel?
    private var pendingStartup: WindowEngine.Startup?
    private var recordingMonitor: Any?
    private var recordingResult: FlutterResult?

    func show() {
        if let window {
            refresh()
            WindowEngine.present(window)
            return
        }
        guard pendingStartup == nil else { return }
        pendingStartup = WindowEngine.start(
            name: AppConstants.settingsEngineName, entrypoint: AppConstants.settingsEntrypoint,
            channel: AppConstants.settingsChannel, handler: { [weak self] call, result in
                let bridge = MacPlatformBridge.Shared.instance!
                switch call.method {
                case AppConstants.recordShortcutMethod:
                    self?.recordShortcut(result: result)
                case AppConstants.setWindowTitleMethod:
                    guard let arguments = call.arguments as? [String: Any],
                          let title = arguments["title"] as? String else {
                        result(FlutterError(code: AppConstants.badArgsError, message: "缺少窗口标题", details: nil))
                        return
                    }
                    self?.window?.title = title
                    result(nil)
                case AppConstants.startWindowDragMethod:
                    WindowEngine.beginDrag(self?.window)
                    result(nil)
                default:
                    bridge.routeWindowRequest(call, result: result)
                }
            }, completion: { [weak self] started in
                guard let self else { return }
                self.pendingStartup = nil
                guard let started else {
                    WindowEngine.reportStartFailure("设置窗口")
                    return
                }
                self.engine = started.engine
                self.channel = started.channel
                let window = WindowEngine.makeWindow(
                    flutter: started.flutter, title: "权限与启动", size: NSSize(width: 760, height: 640),
                    minSize: NSSize(width: 680, height: 480), delegate: self,
                    autosaveName: AppConstants.settingsWindowAutosaveName,
                    fullSizeTitlebar: true)
                self.window = window
                WindowEngine.present(window)
            })
    }

    private func recordShortcut(result: @escaping FlutterResult) {
        finishRecording(nil)
        recordingResult = result
        MacPlatformBridge.Shared.instance?.shortcutRecorder = { [weak self] binding in
            let preferences = AppPreferences.current
            let purpose = GlobalHotKey.allCases.first { ShortcutNames.binding(preferences[$0.preferenceKey]) == binding }
            let label = purpose.flatMap { (preferences[$0.preferenceKey] as? [String: Any])?["label"] as? String } ?? ""
            self?.finishRecording(ShortcutNames.shortcut(binding, label: label))
        }
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            if event.keyCode == AppConstants.escapeKeyCode {
                self.finishRecording(nil)
                return nil
            }
            let flags = event.modifierFlags
            let modifiers: UInt32 = (flags.contains(.command) ? UInt32(cmdKey) : 0)
                | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
                | (flags.contains(.option) ? UInt32(optionKey) : 0)
                | (flags.contains(.control) ? UInt32(controlKey) : 0)
            do {
                try SelectionMonitor.validateShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
                let special: [UInt16: String] = [
                    36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 76: "Enter",
                    115: "Home", 116: "Page Up", 117: "⌦", 119: "End", 121: "Page Down",
                    123: "←", 124: "→", 125: "↓", 126: "↑",
                    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
                    98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
                    105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
                ]
                let label = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
                self.finishRecording(ShortcutNames.shortcut(
                    SelectionMonitor.HotKeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers), label: label))
            } catch {
                self.finishRecording(FlutterError(code: AppConstants.shortcutInvalidError, message: error.localizedDescription, details: nil))
            }
            return nil
        }
    }

    private func finishRecording(_ value: Any?) {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        MacPlatformBridge.Shared.instance?.shortcutRecorder = nil
        let result = recordingResult
        recordingResult = nil
        result?(value)
    }

    func windowDidResignKey(_ notification: Notification) { finishRecording(nil) }

    func windowWillClose(_ notification: Notification) {
        DockPresence.leave(notification.object as! NSWindow)
    }

    func refresh() {
        channel?.invokeMethod(AppConstants.refreshSettingsMethod, arguments: nil)
    }

    func shutdown() {
        pendingStartup?.cancel()
        pendingStartup = nil
        finishRecording(nil)
        window?.delegate = nil
        window?.close()
        window = nil
        channel?.setMethodCallHandler(nil)
        engine?.shutDownEngine()
        channel = nil
        engine = nil
    }

    deinit { shutdown() }
}
