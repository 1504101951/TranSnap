import AppKit
import ApplicationServices
import Carbon

@MainActor
final class MCPControl {
    static let shared = MCPControl()

    private struct Target {
        let app: NSRunningApplication
        let appName: String
        let element: AXUIElement?
        let point: CGPoint?
        let displayIndex: Int?
    }

    private var startedAt: Date?
    private var lastActionAt = Date.distantPast
    private var lastUserInputAt = Date.distantPast
    private var approved: Set<String> = []
    private var busy = false
    private var inputMonitor: Any?
    private var sessionTimer: Timer?
    private var borders: [NSWindow] = []

    var indicatorWindowIDs: [CGWindowID] { borders.map { CGWindowID($0.windowNumber) } }

    func perform(_ request: MCPToolRequest) async -> MCPToolReply {
        guard AXIsProcessTrusted() else { return .failed(message: AppConstants.mcpAccessibilityPermissionMessage) }
        guard !busy else { return .failed(message: AppConstants.mcpControlBusyMessage) }
        busy = true
        defer { busy = false }
        let displays = MCPToolRunner.displays()
        let outcome: Result<(message: String, target: Target, screenshot: Bool), MCPFailure>
        switch request {
        case .click(let target, let button, let count, let screenshot):
            outcome = await act(on: target, displays: displays, action: "click") { [self] found in
                try await click(found, button: button, count: count)
            }.map { ($0.message, $0.target, screenshot) }
        case .typeText(let text, let target, let screenshot):
            outcome = await act(on: target, displays: displays, action: "type_text") { [self] found in
                try await type(text, into: found)
            }.map { ($0.message, $0.target, screenshot) }
        case .pressKey(let keys, let app, let screenshot):
            outcome = await pressKeys(keys, app: app).map { ($0.message, $0.target, screenshot) }
        case .scroll(let target, let direction, let amount, let screenshot):
            outcome = await act(on: target, displays: displays, action: "scroll") { [self] found in
                try await scroll(found, direction: direction, amount: amount)
            }.map { ($0.message, $0.target, screenshot) }
        case .drag(let from, let toX, let toY, let screenshot):
            outcome = await drag(from: from, toX: toX, toY: toY, displays: displays).map { ($0.message, $0.target, screenshot) }
        default:
            preconditionFailure("MCPControl 只执行操作类请求")
        }
        switch outcome {
        case .failure(let failure):
            return .failed(message: failure.message)
        case .success(let result):
            lastActionAt = Date()
            guard result.screenshot else { return .done(message: result.message, png: nil) }
            try? await Task.sleep(for: .seconds(AppConstants.controlSettleDelay))
            let png = await screenshot(displayIndex: result.target.displayIndex ?? 0)
            return .done(message: png == nil ? result.message + " " + AppConstants.mcpScreenshotUnavailableMessage : result.message, png: png)
        }
    }

    private func act(
        on target: MCPPointTarget?, displays: [MCPToolRunner.Display], action: String,
        body: (Target) async throws -> String
    ) async -> Result<(message: String, target: Target), MCPFailure> {
        let found: Target
        switch resolve(target, displays: displays) {
        case .success(let value): found = value
        case .failure(let failure): return .failure(failure)
        }
        if let denied = await admit(found) { return .failure(denied) }
        do {
            let message = try await body(found)
            log(action: action, app: found.app, target: target)
            return .success((message, found))
        } catch let failure as MCPFailure {
            return .failure(failure)
        } catch {
            return .failure(MCPFailure(AppConstants.mcpInterruptedMessage))
        }
    }

    private func resolve(_ target: MCPPointTarget?, displays: [MCPToolRunner.Display]) -> Result<Target, MCPFailure> {
        switch target {
        case .none:
            guard let app = NSWorkspace.shared.frontmostApplication else {
                return .failure(MCPFailure(AppConstants.mcpAppNotRunningMessage("frontmost")))
            }
            let focused = AXWalk.element(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute)
            return MCPAccessibility.allowed(app).map { Target(app: app, appName: $0, element: focused, point: nil, displayIndex: nil) }
        case .ref(let ref):
            return MCPAccessibility.resolve(ref).flatMap { found in
                guard let app = NSRunningApplication(processIdentifier: found.pid) else {
                    return .failure(MCPFailure(AppConstants.mcpStaleRefMessage(ref)))
                }
                let frame = AXWalk.frame(found.element)
                let center = frame.map { CGPoint(x: $0.midX, y: $0.midY) }
                let index = frame.flatMap { MCPToolRunner.standardRect($0, displays: displays)?.displayIndex }
                return MCPAccessibility.allowed(app).map {
                    Target(app: app, appName: $0, element: found.element, point: center, displayIndex: index)
                }
            }
        case .point(let index, let x, let y, let reference):
            guard displays.indices.contains(index) else {
                return .failure(MCPFailure(AppConstants.mcpDisplayOutOfRangeMessage(index: index, count: displays.count)))
            }
            guard let point = MCPToolRunner.globalPoint(x: x, y: y, reference: reference, display: displays[index]) else {
                let size = reference == .standard
                    ? (displays[index].info.standardWidth, displays[index].info.standardHeight)
                    : (displays[index].info.lowWidth, displays[index].info.lowHeight)
                return .failure(MCPFailure(AppConstants.mcpRectangleOutOfRangeMessage(
                    reference: reference.rawValue, display: index, width: size.0, height: size.1
                )))
            }
            guard let app = Self.application(at: point) else { return .failure(MCPFailure(AppConstants.mcpNoWindowAtPointMessage)) }
            return MCPAccessibility.allowed(app).map { Target(app: app, appName: $0, element: nil, point: point, displayIndex: index) }
        }
    }

    private static func application(at point: CGPoint) -> NSRunningApplication? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where window[kCGWindowLayer as String] as? Int == 0 {
            guard let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.contains(point), let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            return NSRunningApplication(processIdentifier: pid)
        }
        return nil
    }

    private func admit(_ target: Target) async -> MCPFailure? {
        beginSessionIfNeeded()
        let key = target.app.bundleIdentifier ?? "pid \(target.app.processIdentifier)"
        if approved.contains(key) { return nil }
        let allowed = await MCPControlApproval.ask(appName: target.appName, detail: description(of: target), near: target.point)
        guard allowed else { return MCPFailure(AppConstants.mcpDeniedMessage(target.appName)) }
        approved.insert(key)
        return nil
    }

    private func description(of target: Target) -> String {
        if let element = target.element {
            let role = AXWalk.string(element, kAXRoleAttribute).map(AXWalk.normalizedRole) ?? "element"
            let name = AXWalk.string(element, kAXTitleAttribute) ?? AXWalk.string(element, kAXDescriptionAttribute) ?? ""
            return name.isEmpty ? role : "\(role)「\(name)」"
        }
        guard let point = target.point else { return "焦点元素" }
        return "坐标 (\(Int(point.x)), \(Int(point.y)))"
    }

    private func click(_ target: Target, button: MCPMouseButton, count: Int) async throws -> String {
        if let element = target.element, count == 1 {
            let action = button == .left ? kAXPressAction : kAXShowMenuAction
            if AXUIElementPerformAction(element, action as CFString) == .success {
                return "Clicked \(description(of: target)) in \(target.appName) via accessibility (background)."
            }
        }
        guard let point = target.point else { throw MCPFailure(AppConstants.mcpNoWindowAtPointMessage) }
        try await borrowForeground(of: target.app) {
            try self.postClick(at: point, button: button, count: count)
        }
        return "Clicked at (\(Int(point.x)), \(Int(point.y))) in \(target.appName) with the pointer."
    }

    private func type(_ text: String, into target: Target) async throws -> String {
        var element = target.element
        if element == nil, let point = target.point {
            try await borrowForeground(of: target.app) { try self.postClick(at: point, button: .left, count: 1) }
            element = AXWalk.element(AXUIElementCreateApplication(target.app.processIdentifier), kAXFocusedUIElementAttribute)
        }
        if let element {
            guard AXWalk.string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else {
                throw MCPFailure(AppConstants.mcpSecureFieldMessage)
            }
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue,
               AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
                return "Typed \(text.count) characters into \(target.appName) via accessibility (background)."
            }
        }
        try await deliver(Self.unicodeEvents(text), to: target.app)
        return "Typed \(text.count) characters into \(target.appName) with key events."
    }

    private func pressKeys(_ keys: String, app name: String?) async -> Result<(message: String, target: Target), MCPFailure> {
        guard let combo = MCPKeyCombo(keys) else { return .failure(MCPFailure(AppConstants.mcpInvalidKeysMessage(keys))) }
        guard !combo.isForbidden else { return .failure(MCPFailure(AppConstants.mcpForbiddenKeysMessage(keys))) }
        let root = MCPAccessibility.resolveRoot(name.map(MCPAppTarget.app) ?? .frontmost)
        guard case .success(let found) = root, let app = NSRunningApplication(processIdentifier: found.pid) else {
            if case .failure(let failure) = root { return .failure(failure) }
            return .failure(MCPFailure(AppConstants.mcpAppNotRunningMessage(name ?? "frontmost")))
        }
        let target = Target(app: app, appName: found.appName, element: nil, point: nil, displayIndex: nil)
        if let denied = await admit(target) { return .failure(denied) }
        do {
            try await deliver(combo.events(), to: app)
        } catch let failure as MCPFailure {
            return .failure(failure)
        } catch {
            return .failure(MCPFailure(AppConstants.mcpInterruptedMessage))
        }
        log(action: "press_key", app: app, target: nil)
        return .success(("Pressed \(keys) in \(found.appName).", target))
    }

    private func scroll(_ target: Target, direction: MCPScrollDirection, amount: Int) async throws -> String {
        guard let point = target.point else { throw MCPFailure(AppConstants.mcpNoWindowAtPointMessage) }
        try await waitForUserIdle()
        let original = CGEvent(source: nil)?.location ?? point
        defer { Self.post(Self.mouseEvent(.mouseMoved, at: original, button: .left)) }
        Self.post(Self.mouseEvent(.mouseMoved, at: point, button: .left))
        let lines = Int32(amount)
        let (vertical, horizontal): (Int32, Int32) = switch direction {
        case .up: (lines, 0)
        case .down: (-lines, 0)
        case .left: (0, lines)
        case .right: (0, -lines)
        }
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else {
            throw MCPFailure(AppConstants.mcpInterruptedMessage)
        }
        event.location = point
        Self.post(event)
        return "Scrolled \(direction.rawValue) \(amount) lines in \(target.appName)."
    }

    private func drag(
        from: MCPPointTarget, toX: Int, toY: Int, displays: [MCPToolRunner.Display]
    ) async -> Result<(message: String, target: Target), MCPFailure> {
        guard case .point(let index, _, _, let reference) = from, displays.indices.contains(index),
              let end = MCPToolRunner.globalPoint(x: toX, y: toY, reference: reference, display: displays[index]) else {
            return .failure(MCPFailure(AppConstants.mcpDragTargetMessage))
        }
        return await act(on: from, displays: displays, action: "drag") { [self] found in
            guard let start = found.point else { throw MCPFailure(AppConstants.mcpNoWindowAtPointMessage) }
            try await borrowForeground(of: found.app) {
                Self.post(Self.mouseEvent(.leftMouseDown, at: start, button: .left))
                let steps = 10
                for step in 1...steps {
                    let fraction = CGFloat(step) / CGFloat(steps)
                    let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
                    Self.post(Self.mouseEvent(.leftMouseDragged, at: point, button: .left))
                }
                Self.post(Self.mouseEvent(.leftMouseUp, at: end, button: .left))
            }
            return "Dragged in \(found.appName)."
        }
    }

    private var userInterrupted = false
    private var borrowingSince: Date?

    private func borrowForeground(of app: NSRunningApplication, _ body: () throws -> Void) async throws {
        try await waitForUserIdle()
        let previous = NSWorkspace.shared.frontmostApplication
        let original = CGEvent(source: nil)?.location
        userInterrupted = false
        borrowingSince = Date()
        if previous?.processIdentifier != app.processIdentifier {
            app.activate()
            try? await Task.sleep(for: .seconds(AppConstants.controlActivationDelay))
        }
        defer {
            borrowingSince = nil
            if let original { Self.post(Self.mouseEvent(.mouseMoved, at: original, button: .left)) }
            if let previous, previous.processIdentifier != app.processIdentifier,
               previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previous.activate()
            }
        }
        try body()
        if userInterrupted { throw MCPFailure(AppConstants.mcpInterruptedMessage) }
    }

    private func deliver(_ events: [CGEvent], to app: NSRunningApplication) async throws {
        let send = { for event in events { event.post(tap: .cghidEventTap) } }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier else {
            try await waitForUserIdle()
            return send()
        }
        try await borrowForeground(of: app) { send() }
    }

    private func waitForUserIdle() async throws {
        let deadline = Date().addingTimeInterval(AppConstants.controlUserWaitLimit)
        while Date().timeIntervalSince(lastUserInputAt) < AppConstants.controlUserIdleInterval {
            guard Date() < deadline else { throw MCPFailure(AppConstants.mcpUserBusyMessage) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func beginSessionIfNeeded() {
        guard startedAt == nil else { return }
        startedAt = Date()
        lastActionAt = Date()
        approved = []
        borders = NSScreen.screens.map(MCPControlBorder.window)
        borders.forEach { $0.orderFrontRegardless() }
        StatusBarController.shared.setControlActive(true) { [weak self] in self?.endSession() }
        inputMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved]
        ) { [weak self] event in
            guard !SyntheticEvent.isMarked(event) else { return }
            let escape = event.type == .keyDown && event.keyCode == AppConstants.escapeKeyCode
            Task { @MainActor in
                guard let self else { return }
                self.lastUserInputAt = Date()
                if self.borrowingSince != nil { self.userInterrupted = true }
                if escape {
                    if MCPControlApproval.isAsking {
                        MCPControlApproval.dismiss()
                    } else {
                        self.endSession()
                    }
                }
            }
        }
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkLimits() }
        }
    }

    private func checkLimits() {
        guard let startedAt else { return }
        let now = Date()
        if MCPControlLimits.expired(startedAt: startedAt, lastActionAt: lastActionAt, now: now) { endSession() }
    }

    func endSession() {
        guard startedAt != nil else { return }
        startedAt = nil
        approved = []
        borders.forEach { $0.orderOut(nil) }
        borders = []
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        sessionTimer?.invalidate()
        sessionTimer = nil
        StatusBarController.shared.setControlActive(false, stop: nil)
        MCPControlApproval.dismiss()
    }

    private func postClick(at point: CGPoint, button: MCPMouseButton, count: Int) throws {
        let (down, up): (CGEventType, CGEventType) = button == .left ? (.leftMouseDown, .leftMouseUp) : (.rightMouseDown, .rightMouseUp)
        Self.post(Self.mouseEvent(.mouseMoved, at: point, button: .left))
        for click in 1...count {
            guard !userInterrupted else { throw MCPFailure(AppConstants.mcpInterruptedMessage) }
            for type in [down, up] {
                let event = Self.mouseEvent(type, at: point, button: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                Self.post(event)
            }
        }
    }

    private static func mouseEvent(_ type: CGEventType, at point: CGPoint, button: MCPMouseButton) -> CGEvent? {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button == .left ? .left : .right)
    }

    private static func post(_ event: CGEvent?) {
        guard let event else { return }
        SyntheticEvent.mark(event)
        event.post(tap: .cghidEventTap)
    }

    static func unicodeEvents(_ text: String) -> [CGEvent] {
        let units = Array(text.utf16)
        return stride(from: 0, to: units.count, by: 20).flatMap { start -> [CGEvent] in
            let chunk = Array(units[start..<min(start + 20, units.count)])
            return [true, false].compactMap { down in
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { return nil }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                SyntheticEvent.mark(event)
                return event
            }
        }
    }

    private func screenshot(displayIndex: Int) async -> Data? {
        guard await ScreenCaptureService.requestAccess(),
              let id = NSScreen.screens.indices.contains(displayIndex) ? NSScreen.screens[displayIndex].displayID : nil,
              let image = try? await ScreenCaptureService.captureDisplayImage(
                  displayID: id, showsCursor: false, excludingWindowIDs: Set(indicatorWindowIDs)
              ).image,
              case .image(let png, _) = try? await MCPImageOutput.reply(
                  image, options: MCPCaptureOptions(output: .image, detail: .standard, includePositions: false)
              ) else { return nil }
        return png
    }

    private func log(action: String, app: NSRunningApplication, target: MCPPointTarget?) {
        let where_: String = switch target {
        case .none: "focused"
        case .ref(let ref): ref
        case .point(let index, let x, let y, let reference): "display \(index) (\(x),\(y)) \(reference.rawValue)"
        }
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(app.bundleIdentifier ?? app.localizedName ?? "")\t\(action)\t\(where_)\n"
        let url = AppConstants.applicationSupportURL.appendingPathComponent(AppConstants.controlLogFileName)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

enum MCPControlLimits {
    static func expired(startedAt: Date, lastActionAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startedAt) >= AppConstants.controlSessionLimit
            || now.timeIntervalSince(lastActionAt) >= AppConstants.controlIdleLimit
    }
}

struct MCPKeyCombo: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    private static let keys: [String: Int] = {
        var map: [String: Int] = [
            "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "esc": kVK_Escape,
            "escape": kVK_Escape, "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
            "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
        ]
        let letters: [Int] = [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I,
            kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R,
            kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
        ]
        for (offset, code) in letters.enumerated() { map[String(UnicodeScalar(UInt8(97 + offset)))] = code }
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (digit, code) in digits.enumerated() { map[String(digit)] = code }
        let functions = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (offset, code) in functions.enumerated() { map["f\(offset + 1)"] = code }
        return map
    }()

    private static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "shift": .maskShift, "opt": .maskAlternate,
        "option": .maskAlternate, "alt": .maskAlternate, "ctrl": .maskControl, "control": .maskControl,
    ]

    init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        var flags: CGEventFlags = []
        var key: Int?
        for part in parts {
            if let flag = Self.modifiers[part] {
                flags.insert(flag)
            } else if let code = Self.keys[part], key == nil {
                key = code
            } else {
                return nil
            }
        }
        guard let key else { return nil }
        self.keyCode = CGKeyCode(key)
        self.flags = flags
    }

    var isForbidden: Bool {
        guard flags.contains(.maskCommand) else { return false }
        return keyCode == CGKeyCode(kVK_ANSI_Q) || (keyCode == CGKeyCode(kVK_Escape) && flags.contains(.maskAlternate))
    }

    func events() -> [CGEvent] {
        [true, false].compactMap { down in
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return nil }
            event.flags = flags
            SyntheticEvent.mark(event)
            return event
        }
    }
}

enum MCPControlBorder {
    static func window(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = BorderView(frame: CGRect(origin: .zero, size: screen.frame.size))
        return window
    }

    private final class BorderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            AppConstants.controlBorderColor.setStroke()
            let inset = AppConstants.controlBorderWidth / 2
            let path = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
            path.lineWidth = AppConstants.controlBorderWidth
            path.stroke()
        }
    }
}

@MainActor
enum MCPControlApproval {
    private static var panel: NSPanel?
    private static var pending: CheckedContinuation<Bool, Never>?
    private static var countdownTask: Task<Void, Never>?

    static var isAsking: Bool { panel != nil }

    static func ask(appName: String, detail: String, near point: CGPoint?) async -> Bool {
        dismiss()
        let screen = point.flatMap { location in
            NSScreen.screens.first { $0.displayID.map { CGDisplayBounds($0).contains(location) } ?? false }
        } ?? NSScreen.main ?? NSScreen.screens[0]
        return await withCheckedContinuation { continuation in
            pending = continuation
            let totalSeconds = max(1, Int(AppConstants.controlApprovalTimeout.rounded()))
            let built = makePanel(appName: appName, detail: detail, initialSeconds: totalSeconds)
            let panel = built.panel
            let countdownLabel = built.countdownLabel
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.maxY - AppConstants.controlPanelTopInset - panel.frame.height
            ))
            panel.orderFrontRegardless()
            self.panel = panel
            countdownTask = Task { @MainActor in
                for remaining in stride(from: totalSeconds - 1, through: 0, by: -1) {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, self.panel === panel else { return }
                    if remaining == 0 {
                        finish(false)
                        return
                    }
                    countdownLabel.stringValue = countdownText(remaining)
                }
            }
        }
    }

    static func dismiss() { finish(false) }

    private static func countdownText(_ remaining: Int) -> String {
        "将在 \(remaining) 秒后自动拒绝 · 按 Esc 拒绝本次"
    }

    private static func finish(_ allowed: Bool) {
        countdownTask?.cancel()
        countdownTask = nil
        panel?.orderOut(nil)
        panel = nil
        pending?.resume(returning: allowed)
        pending = nil
    }

    private static func makePanel(
        appName: String,
        detail: String,
        initialSeconds: Int
    ) -> (panel: NSPanel, countdownLabel: NSTextField) {
        let panel = ApprovalPanel(
            contentRect: CGRect(x: 0, y: 0, width: AppConstants.controlPanelWidth, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NativeGlassFactory.applyAppearance(to: panel)

        let title = NSTextField(labelWithString: "允许模型操作 \(appName)？")
        title.font = AppFonts.font(.title, size: NSFont.systemFontSize, weight: .bold)
        title.textColor = .labelColor

        let body = NSTextField(wrappingLabelWithString: "动作：\(detail)")
        body.font = AppFonts.font(.ui, size: NSFont.systemFontSize)
        body.textColor = .labelColor

        let countdownLabel = NSTextField(labelWithString: countdownText(initialSeconds))
        countdownLabel.font = AppFonts.font(.ui, size: 11, monospacedDigits: true)
        countdownLabel.textColor = .secondaryLabelColor

        let deny = NSButton(title: "拒绝", target: Handler.shared, action: #selector(Handler.deny))
        deny.bezelStyle = .rounded
        deny.keyEquivalent = "\u{1b}"
        let allow = NSButton(title: "本次会话允许", target: Handler.shared, action: #selector(Handler.allow))
        allow.bezelStyle = .rounded
        allow.keyEquivalent = "\r"

        let buttons = NSStackView(views: [NSView(), deny, allow])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, body, countdownLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(
            top: AppConstants.controlPanelPadding, left: AppConstants.controlPanelPadding,
            bottom: AppConstants.controlPanelPadding, right: AppConstants.controlPanelPadding
        )
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: AppConstants.controlPanelWidth),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * AppConstants.controlPanelPadding),
        ])
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        panel.contentView = NativeGlassFactory.makeGlassContainer(
            content: content,
            size: size,
            cornerRadius: AppConstants.controlPanelCornerRadius
        )
        panel.setContentSize(size)
        return (panel, countdownLabel)
    }

    private final class ApprovalPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }

        override func cancelOperation(_ sender: Any?) {
            MCPControlApproval.finish(false)
        }
    }

    @MainActor
    private final class Handler: NSObject {
        static let shared = Handler()
        @objc func deny() { MCPControlApproval.finish(false) }
        @objc func allow() { MCPControlApproval.finish(true) }
    }
}
