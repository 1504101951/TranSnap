import AppKit
import ApplicationServices

@MainActor
enum MCPAccessibility {
    private struct Snapshot {
        let id: Int
        let pid: pid_t
        let elements: [AXUIElement]
    }

    struct Root {
        let pid: pid_t
        let appName: String
        let elements: [AXUIElement]
    }

    private static var snapshots: [Snapshot] = []
    private static var nextID = 1

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
                let roleMatches = wantedRole.map { $0 == node.role } ?? true
                let textMatches = needle.map { node.name.lowercased().contains($0) || node.value.lowercased().contains($0) } ?? true
                return roleMatches && textMatches
            }
        }.value
        return reply(walk, pid: root.pid, displays: displays)
    }

    static func resolve(_ ref: String) -> Result<(element: AXUIElement, pid: pid_t), MCPFailure> {
        guard let (snapshotID, index) = parse(ref) else { return .failure(MCPFailure(AppConstants.mcpInvalidRefMessage(ref))) }
        guard let snapshot = snapshots.first(where: { $0.id == snapshotID }),
              snapshot.elements.indices.contains(index - 1) else {
            return .failure(MCPFailure(AppConstants.mcpStaleRefMessage(ref)))
        }
        let element = snapshot.elements[index - 1]
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) != .invalidUIElement else {
            return .failure(MCPFailure(AppConstants.mcpStaleRefMessage(ref)))
        }
        return .success((element, snapshot.pid))
    }

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

    static func allowed(_ app: NSRunningApplication) -> Result<String, MCPFailure> {
        let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
        let excluded = (AppPreferences.current[AppConstants.excludedAppsKey] as? [String: String]).map { Set($0.keys) } ?? []
        let bundle = app.bundleIdentifier ?? ""
        let blocked = app.processIdentifier == ProcessInfo.processInfo.processIdentifier
            || AppConstants.controlBlockedBundleIDs.contains(bundle)
            || excluded.contains(bundle)
        return blocked ? .failure(MCPFailure(AppConstants.mcpBlockedAppMessage(name))) : .success(name)
    }

    private static func application(pid: pid_t) -> Result<NSRunningApplication, MCPFailure> {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return .failure(MCPFailure(AppConstants.mcpAppNotRunningMessage("pid \(pid)")))
        }
        return .success(app)
    }

    private static func windows(of app: NSRunningApplication) -> Result<Root, MCPFailure> {
        allowed(app).map { name in
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            let windows = AXWalk.elements(element, kAXWindowsAttribute)
            return Root(pid: app.processIdentifier, appName: name, elements: windows)
        }
    }

    private static func window(_ windowID: UInt32) -> Result<Root, MCPFailure> {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsInfo) else {
            return .failure(MCPFailure(AppConstants.mcpWindowNotFoundMessage(windowID: windowID)))
        }
        return application(pid: pid).flatMap { app in
            windows(of: app).flatMap { root in
                guard let match = root.elements.first(where: { AXWalk.frame($0).map { Self.same($0, bounds) } ?? false }) else {
                    return .failure(MCPFailure(AppConstants.mcpWindowNotInTreeMessage(windowID: windowID)))
                }
                return .success(Root(pid: pid, appName: root.appName, elements: [match]))
            }
        }
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }

    private static func reply(_ walk: AXWalk.Result, pid: pid_t, displays: [MCPToolRunner.Display]) -> MCPToolReply {
        let id = nextID
        nextID += 1
        snapshots.append(Snapshot(id: id, pid: pid, elements: walk.nodes.map(\.element)))
        if snapshots.count > AppConstants.mcpRefSnapshotLimit { snapshots.removeFirst() }
        let items = walk.nodes.enumerated().map { index, node in
            let place = node.frame.flatMap { MCPToolRunner.standardRect($0, displays: displays) }
            return MCPElementInfo(
                ref: "@s\(id):e\(index + 1)", depth: node.depth, role: node.role, name: node.name, value: node.value,
                enabled: node.enabled, displayIndex: place?.displayIndex,
                x: place?.x ?? 0, y: place?.y ?? 0, width: place?.width ?? 0, height: place?.height ?? 0
            )
        }
        return .elements(snapshot: "@s\(id)", complete: walk.complete, items: items)
    }

    private static func parse(_ ref: String) -> (snapshot: Int, index: Int)? {
        guard let match = ref.wholeMatch(of: /@s(\d+):e(\d+)/),
              let snapshot = Int(match.1), let index = Int(match.2), index >= 1 else { return nil }
        return (snapshot, index)
    }
}

struct MCPFailure: Error {
    let message: String

    init(_ message: String) { self.message = message }
}

enum AXWalk {
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

    struct Result: @unchecked Sendable {
        let nodes: [Node]
        let complete: Bool
    }

    private static let interactiveRoles: Set<String> = [
        "button", "checkbox", "radiobutton", "popupbutton", "menubutton", "combobox", "textfield", "textarea",
        "securetextfield", "searchfield", "link", "menuitem", "menubaritem", "slider", "incrementor",
        "disclosuretriangle", "tab", "cell", "row", "colorwell", "datefield",
    ]

    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXEnabledAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute, kAXPlaceholderValueAttribute,
    ] as CFArray

    static func run(roots: [AXUIElement], maxDepth: Int, limit: Int, include: (Node) -> Bool) -> Result {
        let deadline = Date().addingTimeInterval(AppConstants.mcpSnapshotBudget)
        var nodes: [Node] = []
        var stack = roots.reversed().map { ($0, 0) }
        while let (element, depth) = stack.popLast() {
            guard nodes.count < limit, Date() < deadline else { return Result(nodes: nodes, complete: false) }
            guard let (node, children) = node(element, depth: depth) else { continue }
            if include(node) { nodes.append(node) }
            guard depth < maxDepth else { continue }
            stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        return Result(nodes: nodes, complete: true)
    }

    private static func node(_ element: AXUIElement, depth: Int) -> (Node, [AXUIElement])? {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let values = raw as? [AnyObject], values.count == CFArrayGetCount(attributes) else { return nil }
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

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func elements(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)
        return frame(position: position, size: size)
    }

    private static func frame(position: AnyObject?, size: AnyObject?) -> CGRect? {
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }

    static func normalizedRole(_ role: String) -> String {
        let lowered = role.lowercased()
        return lowered.hasPrefix("ax") ? String(lowered.dropFirst(2)) : lowered
    }

    private static func truncated(_ text: String) -> String {
        let single = text.replacingOccurrences(of: "\n", with: " ")
        return single.count > AppConstants.mcpElementValueLimit
            ? String(single.prefix(AppConstants.mcpElementValueLimit)) + "…" : single
    }
}
