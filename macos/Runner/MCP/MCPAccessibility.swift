import AppKit
import ApplicationServices

/// MCP 无障碍读取（#140）：解析读取对象、遍历无障碍树、在内存中保存元素引用并生成元素清单。
/// 遍历在后台执行，目标应用响应慢时不阻塞主线程；引用不落盘，App 退出即失效。
@MainActor
enum MCPAccessibility {
    /// 一次快照：编号、所属进程与按 ref 序号（从 1 起）排列的元素。
    private struct Snapshot {
        let id: Int
        let pid: pid_t
        let elements: [AXUIElement]
    }

    /// 读取根：所属进程、应用显示名与遍历起点（应用的各个窗口，或单个窗口、单个元素）。
    struct Root {
        let pid: pid_t
        let appName: String
        let elements: [AXUIElement]
    }

    /// 最近的快照，最新在末尾；超过 mcpRefSnapshotLimit 时淘汰最早的。
    private static var snapshots: [Snapshot] = []
    private static var nextID = 1

    /// 作用：执行 snapshot 工具。
    /// 参数 target：读取对象；interactiveOnly：只输出可交互元素；maxDepth：遍历深度；displays：当前显示器几何。
    /// 返回：元素清单；对象不存在、被禁止或无权限时为 failed。
    static func snapshot(
        target: MCPAppTarget, interactiveOnly: Bool, maxDepth: Int, displays: [MCPToolRunner.Display]
    ) async -> MCPToolReply {
        let root: Root
        switch resolveRoot(target) {
        case .success(let value): root = value
        case .failure(let failure): return .failed(message: failure.message)
        }
        let walk = await Task.detached {
            AXWalk.run(roots: root.elements, maxDepth: maxDepth, limit: AppConstants.mcpSnapshotElementLimit) { node in
                !interactiveOnly || node.interactive
            }
        }.value
        return reply(walk, pid: root.pid, displays: displays)
    }

    /// 作用：执行 find 工具。
    /// 参数 target：读取对象；role：角色，忽略大小写与 AX 前缀；text：名称或值中的子串，忽略大小写；displays：当前显示器几何。
    /// 返回：匹配元素清单，最多 mcpFindLimit 个；对象不存在、被禁止或无权限时为 failed。
    static func find(target: MCPAppTarget, role: String?, text: String?, displays: [MCPToolRunner.Display]) async -> MCPToolReply {
        let root: Root
        switch resolveRoot(target) {
        case .success(let value): root = value
        case .failure(let failure): return .failed(message: failure.message)
        }
        let wantedRole = role.map(AXWalk.normalizedRole)
        let needle = text?.lowercased()
        let walk = await Task.detached {
            AXWalk.run(roots: root.elements, maxDepth: AppConstants.mcpSnapshotMaxDepth, limit: AppConstants.mcpFindLimit) { node in
                // 角色与文字条件同时给出时都要满足。
                let roleMatches = wantedRole.map { $0 == node.role } ?? true
                let textMatches = needle.map { node.name.lowercased().contains($0) || node.value.lowercased().contains($0) } ?? true
                return roleMatches && textMatches
            }
        }.value
        return reply(walk, pid: root.pid, displays: displays)
    }

    /// 作用：按 ref 取回元素。参数 ref：形如 @s3:e12。
    /// 返回：元素与所属进程；格式不合法、快照已淘汰或元素已消失时为对应错误。
    static func resolve(_ ref: String) -> Result<(element: AXUIElement, pid: pid_t), MCPFailure> {
        guard let (snapshotID, index) = parse(ref) else { return .failure(MCPFailure(AppConstants.mcpInvalidRefMessage(ref))) }
        guard let snapshot = snapshots.first(where: { $0.id == snapshotID }),
              snapshot.elements.indices.contains(index - 1) else {
            return .failure(MCPFailure(AppConstants.mcpStaleRefMessage(ref)))
        }
        let element = snapshot.elements[index - 1]
        // 元素所在界面关闭后，读取任何属性都返回 invalidUIElement。
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) != .invalidUIElement else {
            return .failure(MCPFailure(AppConstants.mcpStaleRefMessage(ref)))
        }
        return .success((element, snapshot.pid))
    }

    /// 作用：解析读取对象。参数 target：工具给出的对象。
    /// 返回：读取根；需要辅助功能权限，目标为本应用或禁止名单中的应用时拒绝。
    static func resolveRoot(_ target: MCPAppTarget) -> Result<Root, MCPFailure> {
        guard AXIsProcessTrusted() else { return .failure(MCPFailure(AppConstants.mcpAccessibilityPermissionMessage)) }
        switch target {
        case .ref(let ref):
            return resolve(ref).flatMap { found in
                application(pid: found.pid).flatMap { app in
                    allowed(app).map { Root(pid: found.pid, appName: $0, elements: [found.element]) }
                }
            }
        case .frontmost:
            guard let app = NSWorkspace.shared.frontmostApplication else {
                return .failure(MCPFailure(AppConstants.mcpAppNotRunningMessage("frontmost")))
            }
            return windows(of: app)
        case .app(let name):
            let lowered = name.lowercased()
            let matches = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier?.lowercased() == lowered || $0.localizedName?.lowercased() == lowered
            }
            guard let app = matches.first else { return .failure(MCPFailure(AppConstants.mcpAppNotRunningMessage(name))) }
            guard matches.count == 1 else {
                return .failure(MCPFailure(AppConstants.mcpAmbiguousAppMessage(name, candidates: matches.compactMap(\.bundleIdentifier))))
            }
            return windows(of: app)
        case .window(let windowID):
            return window(windowID)
        }
    }

    /// 作用：判断应用是否允许读取与操作。参数 app：目标应用。
    /// 返回：允许时为应用显示名；本应用、预置禁止应用与「排除应用」中的应用为拒绝（#140 安全基线）。
    static func allowed(_ app: NSRunningApplication) -> Result<String, MCPFailure> {
        let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
        let excluded = (AppPreferences.current[AppConstants.excludedAppsKey] as? [String: String]).map { Set($0.keys) } ?? []
        let bundle = app.bundleIdentifier ?? ""
        let blocked = app.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || AppConstants.controlBlockedBundleIDs.contains(bundle)
            || excluded.contains(bundle)
        return blocked ? .failure(MCPFailure(AppConstants.mcpBlockedAppMessage(name))) : .success(name)
    }

    /// 作用：取进程对应的运行中应用。参数 pid：进程号。返回：应用；已退出时为错误。
    private static func application(pid: pid_t) -> Result<NSRunningApplication, MCPFailure> {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return .failure(MCPFailure(AppConstants.mcpAppNotRunningMessage("pid \(pid)")))
        }
        return .success(app)
    }

    /// 作用：以应用的全部窗口为读取根。参数 app：目标应用。
    /// 返回：读取根；Chromium/Electron 应用先请求公开网页无障碍树。
    private static func windows(of app: NSRunningApplication) -> Result<Root, MCPFailure> {
        allowed(app).map { name in
            let element = AXUIElementCreateApplication(app.processIdentifier)
            // Chromium 与 Electron 默认不公开网页内容的无障碍树，设置后才生成；其他应用忽略该属性。
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            let windows = AXWalk.elements(element, kAXWindowsAttribute)
            return Root(pid: app.processIdentifier, appName: name, elements: windows)
        }
    }

    /// 作用：以 list_windows 的窗口为读取根。参数 windowID：CGWindowID。
    /// 返回：读取根；窗口不存在或在无障碍树中找不到对应窗口时为错误。
    private static func window(_ windowID: UInt32) -> Result<Root, MCPFailure> {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsInfo) else {
            return .failure(MCPFailure(AppConstants.mcpWindowNotFoundMessage(windowID: windowID)))
        }
        return application(pid: pid).flatMap { app in
            windows(of: app).flatMap { root in
                // 无障碍窗口与 CGWindow 没有公开的对应关系，按全局点坐标下的位置与尺寸匹配，容差 1pt。
                guard let match = root.elements.first(where: { AXWalk.frame($0).map { Self.same($0, bounds) } ?? false }) else {
                    return .failure(MCPFailure(AppConstants.mcpWindowNotInTreeMessage(windowID: windowID)))
                }
                return .success(Root(pid: pid, appName: root.appName, elements: [match]))
            }
        }
    }

    /// 作用：比较两个矩形是否在 1pt 容差内相同。参数 a、b：全局点坐标矩形。返回：是否相同。
    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    /// 作用：保存遍历结果为新快照并生成元素清单。
    /// 参数 walk：遍历结果；pid：所属进程；displays：当前显示器几何。返回：elements 结果。
    private static func reply(_ walk: AXWalk.Result, pid: pid_t, displays: [MCPToolRunner.Display]) -> MCPToolReply {
        let id = nextID
        nextID += 1
        snapshots.append(Snapshot(id: id, pid: pid, elements: walk.nodes.map(\.element)))
        if snapshots.count > AppConstants.mcpRefSnapshotLimit { snapshots.removeFirst() }
        let items = walk.nodes.enumerated().map { index, node in
            // standardRect 把全局点坐标换成所在显示器 standard 输出图像素；不在任何显示器上时坐标为空。
            let place = node.frame.flatMap { MCPToolRunner.standardRect($0, displays: displays) }
            return MCPElementInfo(
                ref: "@s\(id):e\(index + 1)", depth: node.depth, role: node.role, name: node.name, value: node.value,
                enabled: node.enabled, displayIndex: place?.displayIndex,
                x: place?.x ?? 0, y: place?.y ?? 0, width: place?.width ?? 0, height: place?.height ?? 0
            )
        }
        return .elements(snapshot: "@s\(id)", complete: walk.complete, items: items)
    }

    /// 作用：解析 ref。参数 ref：形如 @s3:e12。返回：快照编号与元素序号；格式不合法为 nil。
    private static func parse(_ ref: String) -> (snapshot: Int, index: Int)? {
        guard let match = ref.wholeMatch(of: /@s(\d+):e(\d+)/),
              let snapshot = Int(match.1), let index = Int(match.2), index >= 1 else { return nil }
        return (snapshot, index)
    }
}

/// 操控类工具返回给 agent 的失败原因；message 为英文文案。
struct MCPFailure: Error {
    let message: String

    init(_ message: String) { self.message = message }
}

/// 无障碍树遍历（#140）：深度优先、按阅读顺序，受深度、元素数与时间预算限制；在后台线程执行。
enum AXWalk {
    /// 遍历得到的一个元素：depth 相对读取根；role 为规范化角色；name、value 已截断；frame 为全局点坐标。
    struct Node: @unchecked Sendable {
        let element: AXUIElement
        let depth: Int
        let role: String
        let name: String
        let value: String
        let enabled: Bool
        let interactive: Bool
        let frame: CGRect?
    }

    /// 遍历结果；complete 为 false 表示因时间预算或元素上限提前结束。
    struct Result: @unchecked Sendable {
        let nodes: [Node]
        let complete: Bool
    }

    /// 可交互角色（规范化后）；其他角色只有声明了按下动作时才算可交互。
    private static let interactiveRoles: Set<String> = [
        "button", "checkbox", "radiobutton", "popupbutton", "menubutton", "combobox", "textfield", "textarea",
        "securetextfield", "searchfield", "link", "menuitem", "menubaritem", "slider", "incrementor",
        "disclosuretriangle", "tab", "cell", "row", "colorwell", "datefield",
    ]

    /// 批量读取的属性，顺序与 node(_:depth:) 中的下标一致。
    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute, kAXPlaceholderValueAttribute,
    ] as CFArray

    /// 作用：遍历读取根下的元素。
    /// 参数 roots：读取根（depth 0）；maxDepth：最大深度；limit：最多输出数；include：判断元素是否输出。
    /// 返回：按深度优先顺序输出的元素；超时或达到上限时 complete 为 false。
    static func run(roots: [AXUIElement], maxDepth: Int, limit: Int, include: (Node) -> Bool) -> Result {
        let deadline = Date().addingTimeInterval(AppConstants.mcpSnapshotBudget)
        var nodes: [Node] = []
        var stack = roots.reversed().map { ($0, 0) }
        while let (element, depth) = stack.popLast() {
            guard nodes.count < limit, Date() < deadline else { return Result(nodes: nodes, complete: false) }
            guard let (node, children) = node(element, depth: depth) else { continue }
            if include(node) { nodes.append(node) }
            guard depth < maxDepth else { continue }
            // 逆序入栈，出栈时保持子元素原有顺序。
            stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        return Result(nodes: nodes, complete: true)
    }

    /// 作用：一次批量读取元素属性。参数 element：元素；depth：层级。
    /// 返回：元素与子元素；元素已失效时为 nil。
    private static func node(_ element: AXUIElement, depth: Int) -> (Node, [AXUIElement])? {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let values = raw as? [AnyObject], values.count == CFArrayGetCount(attributes) else { return nil }
        // 缺失的属性以 AXValue 错误占位，统一转成 nil。
        let value = { (index: Int) -> AnyObject? in
            let item = values[index]
            if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError { return nil }
            return item
        }
        let subrole = value(1) as? String
        let secure = subrole == kAXSecureTextFieldSubrole
        let role = secure ? "securetextfield" : normalizedRole(subrole == kAXSearchFieldSubrole ? "searchfield" : value(0) as? String ?? "")
        let rawValue = secure ? "" : (value(4) as? String ?? (value(4) as? NSNumber)?.stringValue ?? "")
        let name = [value(2) as? String, value(3) as? String, value(9) as? String, role == "statictext" ? rawValue : nil]
            .compactMap { $0 }.first { !$0.isEmpty } ?? ""
        var interactive = interactiveRoles.contains(role)
        if !interactive {
            // 网页中可点击的 div 等为 group，只有声明了按下动作才算可交互。
            var actions: CFArray?
            interactive = AXUIElementCopyActionNames(element, &actions) == .success
                && (actions as? [String])?.contains(kAXPressAction) == true
        }
        let children = (value(8) as? [AXUIElement]) ?? []
        let node = Node(
            element: element, depth: depth, role: role, name: truncated(name), value: truncated(rawValue),
            enabled: value(5) as? Bool ?? true, interactive: interactive,
            frame: frame(position: value(6), size: value(7))
        )
        return (node, children)
    }

    /// 作用：读取元素数组属性。参数 element：元素；name：属性名。返回：元素数组，缺失时为空。
    static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    /// 作用：读取元素的全局点坐标矩形。参数 element：元素。返回：矩形；缺少位置或尺寸时为 nil。
    static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)
        return frame(position: position, size: size)
    }

    /// 作用：由位置与尺寸 AXValue 组成矩形。参数 position、size：AXValue。返回：矩形；任一缺失或宽高为 0 时为 nil。
    private static func frame(position: AnyObject?, size: AnyObject?) -> CGRect? {
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }

    /// 作用：规范化角色名。参数 role：AX 角色或用户输入的角色。返回：去掉 AX 前缀后的小写形式，如 AXButton → button。
    static func normalizedRole(_ role: String) -> String {
        let lowered = role.lowercased()
        return lowered.hasPrefix("ax") ? String(lowered.dropFirst(2)) : lowered
    }

    /// 作用：截断过长文字并去掉换行。参数 text：原文。返回：不超过 mcpElementValueLimit 个字符的单行文字。
    private static func truncated(_ text: String) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > AppConstants.mcpElementValueLimit
            ? String(single.prefix(AppConstants.mcpElementValueLimit)) + "…" : single
    }
}
