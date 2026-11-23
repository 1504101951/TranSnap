import AppKit
import ApplicationServices
import Carbon

/// MCP 电脑操控（#140）：执行点击、输入、按键、滚动与拖动，并管理操控会话。
/// 执行分档：无障碍动作（按下、显示菜单、插入文字）优先在后台完成；需要真实键鼠事件时，目标已在前台则直接发送，
/// 否则短暂借用前台，结束后恢复前台应用与指针位置。按进程投递的键盘事件在多数应用中不触发快捷键与输入，故不采用；
/// 用户刚有真实输入时先等待其静止。所有注入事件经 SyntheticEvent 标记，选区监听与本会话的用户输入检测都忽略它们。
@MainActor
final class MCPControl {
    static let shared = MCPControl()

    /// 操作的落点：所属应用、无障碍元素（按 ref 操作时）与全局点坐标（原点主显示器左上角）。
    private struct Target {
        let app: NSRunningApplication
        let appName: String
        let element: AXUIElement?
        let point: CGPoint?
        let displayIndex: Int?
    }

    /// 会话开始与最近一次操作的时刻；startedAt 为 nil 表示没有进行中的会话。
    private var startedAt: Date?
    private var lastActionAt = Date.distantPast
    /// 用户最近一次真实输入（不带本应用标记）的时刻。
    private var lastUserInputAt = Date.distantPast
    /// 本会话已允许操作的应用（包标识，没有时为进程号文本）。
    private var approved: Set<String> = []
    /// 是否有操作正在执行（含等待授权）；同一时刻只执行一个，避免并发请求的真实点击落在授权面板上。
    private var busy = false
    private var inputMonitor: Any?
    private var sessionTimer: Timer?
    private var borders: [NSWindow] = []

    /// 无参数；返回操控边框窗口的 ID，MCP 截图排除它们（#67「电脑操控提示」）。
    var indicatorWindowIDs: [CGWindowID] { borders.map { CGWindowID($0.windowNumber) } }

    /// 作用：执行一次操作类请求。参数 request：已通过参数校验的操作请求。
    /// 返回：done 或 failed；会话在首次操作时开始。
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
            // 等界面更新后再截图，截到操作的结果。
            try? await Task.sleep(for: .seconds(AppConstants.controlSettleDelay))
            let png = await screenshot(displayIndex: result.target.displayIndex ?? 0)
            return .done(message: png == nil ? result.message + " " + AppConstants.mcpScreenshotUnavailableMessage : result.message, png: png)
        }
    }

    // MARK: - 目标解析与授权

    /// 作用：解析目标、校验禁止名单、开始会话并取得授权后执行动作。
    /// 参数 target：ref 或坐标，nil 表示前台应用的焦点元素；displays：显示器几何；action：写入日志的动作名；
    /// body：在目标上执行的动作，返回说明文字，抛出 MCPFailure 表示失败。
    /// 返回：说明与目标，或失败原因。
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

    /// 作用：把 ref 或坐标解析为落点。参数 target：操作目标，nil 为前台应用焦点元素；displays：显示器几何。
    /// 返回：落点；ref 失效、坐标越界、坐标处无窗口或应用被禁止时为失败。
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

    /// 作用：取全局点下最上层普通窗口所属的应用。参数 point：全局点坐标。返回：应用；没有窗口时为 nil。
    /// 按窗口列表判断，不依赖无障碍信息，自绘界面同样可用；操控边框不是普通层级，不会被选中。
    private static func application(at point: CGPoint) -> NSRunningApplication? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where window[kCGWindowLayer as String] as? Int == 0 {
            guard let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.contains(point), let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            return NSRunningApplication(processIdentifier: pid)
        }
        return nil
    }

    /// 作用：开始或续用会话，并在本会话首次操作该应用时请用户授权。参数 target：落点。
    /// 返回：允许时为 nil；用户拒绝或超时为失败原因。
    private func admit(_ target: Target) async -> MCPFailure? {
        beginSessionIfNeeded()
        let key = target.app.bundleIdentifier ?? "pid \(target.app.processIdentifier)"
        if approved.contains(key) { return nil }
        let allowed = await MCPControlApproval.ask(appName: target.appName, detail: description(of: target), near: target.point)
        guard allowed else { return MCPFailure(AppConstants.mcpDeniedMessage(target.appName)) }
        approved.insert(key)
        return nil
    }

    /// 作用：生成授权面板正文中的目标描述。参数 target：落点。返回：元素角色与名称，或坐标。
    private func description(of target: Target) -> String {
        if let element = target.element {
            let role = AXWalk.string(element, kAXRoleAttribute).map(AXWalk.normalizedRole) ?? "element"
            let name = AXWalk.string(element, kAXTitleAttribute) ?? AXWalk.string(element, kAXDescriptionAttribute) ?? ""
            return name.isEmpty ? role : "\(role)「\(name)」"
        }
        guard let point = target.point else { return "焦点元素" }
        return "坐标 (\(Int(point.x)), \(Int(point.y)))"
    }

    // MARK: - 动作

    /// 作用：点击。ref 的左键单击先用无障碍按下、右键先用显示菜单，在后台完成；失败或双击时借用前台发真实点击。
    /// 参数 target：落点；button：左右键；count：1 或 2。返回：说明文字；没有坐标可点时抛出失败。
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

    /// 作用：输入文字。目标可插入选中文字时在后台插入；否则聚焦后发送 Unicode 键盘事件（见 deliver）；坐标目标先点击再输入。
    /// 参数 text：要输入的文字；target：落点。返回：说明文字；密码框抛出失败。
    private func type(_ text: String, into target: Target) async throws -> String {
        var element = target.element
        if element == nil, let point = target.point {
            // 坐标目标先真实点击，让该处输入框获得焦点，再取焦点元素。
            try await borrowForeground(of: target.app) { try self.postClick(at: point, button: .left, count: 1) }
            element = AXWalk.element(AXUIElementCreateApplication(target.app.processIdentifier), kAXFocusedUIElementAttribute)
        }
        if let element {
            guard AXWalk.string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else {
                throw MCPFailure(AppConstants.mcpSecureFieldMessage)
            }
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            var settable = DarwinBoolean(false)
            // 插入选中文字等同在光标处输入，原生文本控件在后台即可完成。
            if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue,
               AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
                return "Typed \(text.count) characters into \(target.appName) via accessibility (background)."
            }
        }
        try await deliver(Self.unicodeEvents(text), to: target.app)
        return "Typed \(text.count) characters into \(target.appName) with key events."
    }

    /// 作用：按键。解析组合并拒绝退出、注销、锁屏与强制退出类组合，经 deliver 发给目标应用。
    /// 参数 keys：形如 cmd+s；app：目标应用名称或包标识，nil 为前台应用。返回：说明与目标，或失败原因。
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

    /// 作用：滚动。把指针临时移到落点，发出带标记的滚轮事件后移回原位；滚轮事件作用于指针下的窗口，无需激活应用。
    /// 参数 target：落点；direction：方向；amount：行数。返回：说明文字。
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

    /// 作用：拖动。参数 from：起点坐标；toX、toY：同一参考截图中的终点；displays：显示器几何。
    /// 返回：说明与目标，或失败原因。
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
                // 分步移动，让目标应用识别为拖动；按下后总会松开。
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

    // MARK: - 借用前台

    /// 本次借用前台期间是否收到用户真实输入。
    private var userInterrupted = false
    private var borrowingSince: Date?

    /// 作用：等待用户静止后激活目标应用执行 body，结束后恢复原前台应用与指针位置。
    /// 参数 app：目标应用；body：发送真实事件，可抛出打断。被用户输入打断时抛出 MCPFailure。
    private func borrowForeground(of app: NSRunningApplication, _ body: () throws -> Void) async throws {
        try await waitForUserIdle()
        let previous = NSWorkspace.shared.frontmostApplication
        let original = CGEvent(source: nil)?.location
        // 从激活前开始计入打断：等待激活期间的用户输入同样中止本次动作。
        userInterrupted = false
        borrowingSince = Date()
        if previous?.processIdentifier != app.processIdentifier {
            app.activate()
            try? await Task.sleep(for: .seconds(AppConstants.controlActivationDelay))
        }
        defer {
            borrowingSince = nil
            if let original { Self.post(Self.mouseEvent(.mouseMoved, at: original, button: .left)) }
            // 恢复用户原来的前台应用；原前台是本应用时保持不变，避免激活设置等窗口。
            if let previous, previous.processIdentifier != app.processIdentifier,
               previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previous.activate()
            }
        }
        try body()
        if userInterrupted { throw MCPFailure(AppConstants.mcpInterruptedMessage) }
    }

    /// 作用：把键盘事件发给应用。参数 events：已标记的事件；app：目标应用。
    /// 目标已在前台时直接发到系统事件流；否则借用前台发送后恢复。被用户打断时抛出。
    private func deliver(_ events: [CGEvent], to app: NSRunningApplication) async throws {
        let send = { for event in events { event.post(tap: .cghidEventTap) } }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier else {
            try await waitForUserIdle()
            return send()
        }
        try await borrowForeground(of: app) { send() }
    }

    /// 作用：用户最近有真实输入时等待其静止。无参数；超过 controlUserWaitLimit 仍未静止时抛出用户忙。
    private func waitForUserIdle() async throws {
        let deadline = Date().addingTimeInterval(AppConstants.controlUserWaitLimit)
        while Date().timeIntervalSince(lastUserInputAt) < AppConstants.controlUserIdleInterval {
            guard Date() < deadline else { throw MCPFailure(AppConstants.mcpUserBusyMessage) }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - 会话

    /// 无参数；没有进行中的会话时开始一个：显示边框与菜单栏状态、监听用户输入并启动时限检查。
    private func beginSessionIfNeeded() {
        guard startedAt == nil else { return }
        startedAt = Date()
        lastActionAt = Date()
        approved = []
        borders = NSScreen.screens.map(MCPControlBorder.window)
        borders.forEach { $0.orderFrontRegardless() }
        StatusBarController.shared.setControlActive(true) { [weak self] in self?.endSession() }
        // 只看不带本应用标记的输入：Esc 立即终止，其余输入记为用户正在使用，借用前台期间则打断当前动作。
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
                        // 授权弹窗可见时，Esc 只拒绝本次应用授权而不直接销毁整个操控会话（#144 U-26）。
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

    /// 无参数；会话超过时长上限或空闲上限时结束会话。
    private func checkLimits() {
        guard let startedAt else { return }
        let now = Date()
        if MCPControlLimits.expired(startedAt: startedAt, lastActionAt: lastActionAt, now: now) { endSession() }
    }

    /// 无参数；结束会话：撤下边框与菜单栏状态、停止监听并清空授权，之后的操作会开始新会话并重新请求授权。
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

    // MARK: - 事件与记录

    /// 作用：发出一次单击或双击。参数 point：全局点；button：左右键；count：1 或 2。被用户打断时抛出。
    private func postClick(at point: CGPoint, button: MCPMouseButton, count: Int) throws {
        let (down, up): (CGEventType, CGEventType) = button == .left ? (.leftMouseDown, .leftMouseUp) : (.rightMouseDown, .rightMouseUp)
        Self.post(Self.mouseEvent(.mouseMoved, at: point, button: .left))
        for click in 1...count {
            guard !userInterrupted else { throw MCPFailure(AppConstants.mcpInterruptedMessage) }
            for type in [down, up] {
                let event = Self.mouseEvent(type, at: point, button: button)
                // 点击次数字段让目标应用把第二次点击识别为双击。
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                Self.post(event)
            }
        }
    }

    /// 作用：构造鼠标事件。参数 type：事件类型；point：全局点；button：鼠标键。返回：事件，创建失败为 nil。
    private static func mouseEvent(_ type: CGEventType, at point: CGPoint, button: MCPMouseButton) -> CGEvent? {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button == .left ? .left : .right)
    }

    /// 作用：标记并发到系统事件流。参数 event：要发送的事件，nil 时忽略。
    private static func post(_ event: CGEvent?) {
        guard let event else { return }
        SyntheticEvent.mark(event)
        event.post(tap: .cghidEventTap)
    }

    /// 作用：把文字拆成带标记的 Unicode 键盘事件。参数 text：文字。
    /// 返回：按下与抬起事件；每个事件最多携带 20 个 UTF-16 单元（系统上限）。
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

    /// 作用：截取显示器的 standard 图像，排除操控边框。参数 displayIndex：显示器序号。返回：PNG；无屏幕录制权限或失败时为 nil。
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

    /// 作用：追加一行本地操作日志。参数 action：工具名；app：目标应用；target：ref 或坐标。不记录输入文字。
    private func log(action: String, app: NSRunningApplication, target: MCPPointTarget?) {
        let where_: String = switch target {
        case .none: "focused"
        case .ref(let ref): ref
        case .point(let index, let x, let y, let reference): "display \(index) (\(x),\(y)) \(reference.rawValue)"
        }
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(app.bundleIdentifier ?? app.localizedName ?? "")\t\(action)\t\(where_)\n"
        let url = AppConstants.applicationSupportURL.appendingPathComponent(AppConstants.controlLogFileName)
        // 日志只追加；写入失败不影响操作结果。
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

/// 会话时限判断（#140：最长 30 分钟、空闲 5 分钟）。
enum MCPControlLimits {
    /// 作用：判断会话是否应结束。参数 startedAt：会话开始；lastActionAt：最近一次操作；now：当前时刻。
    /// 返回：超过时长上限或空闲上限时为 true。
    static func expired(startedAt: Date, lastActionAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startedAt) >= AppConstants.controlSessionLimit
            || now.timeIntervalSince(lastActionAt) >= AppConstants.controlIdleLimit
    }
}

/// press_key 的按键组合（#140）：修饰键 cmd、shift、opt、ctrl 与一个主键，以 + 连接，忽略大小写。
struct MCPKeyCombo: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags

    /// 主键名称到虚拟键码（美式键位）。
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

    /// 修饰键名称到事件标志。
    private static let modifiers: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "shift": .maskShift, "opt": .maskAlternate,
        "option": .maskAlternate, "alt": .maskAlternate, "ctrl": .maskControl, "control": .maskControl,
    ]

    /// 参数 text：形如 cmd+shift+s；解析失败（无主键、多个主键或未知名称）时为 nil。
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

    /// 无参数；返回是否为禁止的组合：Command+Q 系列（退出、注销、锁屏）与 Command+Option+Esc（强制退出）。
    var isForbidden: Bool {
        guard flags.contains(.maskCommand) else { return false }
        return keyCode == CGKeyCode(kVK_ANSI_Q) || (keyCode == CGKeyCode(kVK_Escape) && flags.contains(.maskAlternate))
    }

    /// 无参数；返回带标记的按下与抬起事件。
    func events() -> [CGEvent] {
        [true, false].compactMap { down in
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return nil }
            event.flags = flags
            SyntheticEvent.mark(event)
            return event
        }
    }
}

/// 操控边框（#67「电脑操控提示」）：每块显示器四边 3pt #FF9500，不拦截点击、不抢焦点、出现在所有桌面。
enum MCPControlBorder {
    /// 作用：为一块显示器创建边框窗口。参数 screen：显示器。返回：未显示的窗口。
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

    /// 只绘制四边描边的透明视图。
    private final class BorderView: NSView {
        /// dirtyRect 为重画区域；沿视图边缘内侧描 controlBorderWidth 宽的边框。
        override func draw(_ dirtyRect: NSRect) {
            AppConstants.controlBorderColor.setStroke()
            let inset = AppConstants.controlBorderWidth / 2
            let path = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
            path.lineWidth = AppConstants.controlBorderWidth
            path.stroke()
        }
    }
}

/// 授权面板（#67「电脑操控提示」、#144 U-18/U-26）：非激活原生玻璃浮动面板，「拒绝」与「本次会话允许」，带 30 秒倒计时提示，超时或 Esc 按拒绝处理。
@MainActor
enum MCPControlApproval {
    private static var panel: NSPanel?
    private static var pending: CheckedContinuation<Bool, Never>?
    private static var countdownTask: Task<Void, Never>?

    /// 无参数；返回当前是否正在展示授权确认面板。
    static var isAsking: Bool { panel != nil }

    /// 作用：显示面板并等待用户回应，每秒刷新剩余倒计时。参数 appName：目标应用名；detail：动作目标；near：落点全局点，决定显示在哪块显示器。
    /// 返回：用户点「本次会话允许」为 true；拒绝、Esc 取消、超时或会话结束为 false。
    static func ask(appName: String, detail: String, near point: CGPoint?) async -> Bool {
        dismiss()
        let screen = point.flatMap { location in
            // CGDisplayBounds 与落点同为全局点坐标（原点主显示器左上角）。
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

    /// 无参数；关闭面板并按拒绝结束等待中的询问。
    static func dismiss() { finish(false) }

    /// remaining 为剩余秒数；返回带等宽数字提示的倒计时与 Esc 指引文案，无副作用。
    private static func countdownText(_ remaining: Int) -> String {
        "将在 \(remaining) 秒后自动拒绝 · 按 Esc 拒绝本次"
    }

    /// 作用：结束询问并取消倒计时任务。参数 allowed：是否允许。
    private static func finish(_ allowed: Bool) {
        countdownTask?.cancel()
        countdownTask = nil
        panel?.orderOut(nil)
        panel = nil
        pending?.resume(returning: allowed)
        pending = nil
    }

    /// 作用：用原生玻璃容器和标准按钮搭建面板。参数 appName、detail：标题与正文内容；initialSeconds：初始倒计时秒数。
    /// 返回：未显示的面板与每秒刷新的倒计时标签。
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
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.textColor = .labelColor

        let body = NSTextField(wrappingLabelWithString: "动作：\(detail)")
        body.font = .systemFont(ofSize: NSFont.systemFontSize)
        body.textColor = .labelColor

        let countdownLabel = NSTextField(labelWithString: countdownText(initialSeconds))
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
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

    /// 无边框非激活授权面板；用户直接点击或聚焦时支持 Esc 取消。
    private final class ApprovalPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }

        /// sender 为系统取消事件；转发给「拒绝本次」路径，不销毁整个操控会话。
        override func cancelOperation(_ sender: Any?) {
            MCPControlApproval.finish(false)
        }
    }

    /// 按钮动作的接收者；NSButton 需要 Objective-C 对象作为 target，按钮动作在主线程触发。
    @MainActor
    private final class Handler: NSObject {
        static let shared = Handler()
        @objc func deny() { MCPControlApproval.finish(false) }
        @objc func allow() { MCPControlApproval.finish(true) }
    }
}
