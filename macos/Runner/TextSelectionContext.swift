import Foundation

enum TextSelectionContext {
    enum Kind: String {
        case text
        case nonText
        case web
        case other
    }

    static let textRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXSearchField", "AXComboBox", "AXTextView",
    ]
    static let webRole = "AXWebArea"
    static let nonTextRoles: Set<String> = [
        "AXOutline", "AXTable", "AXBrowser", "AXRow", "AXCell", "AXColumn",
        "AXImage", "AXButton", "AXMenu", "AXMenuBar", "AXMenuItem", "AXToolbar", "AXTabGroup",
    ]

    static func kind(ofRole role: String) -> Kind {
        if role == webRole { return .web }
        if textRoles.contains(role) { return .text }
        if nonTextRoles.contains(role) { return .nonText }
        return .other
    }

    static func shouldReadSelectedText(context: [Kind]) -> Bool {
        for kind in context {
            if kind == .nonText { return false }
            if kind == .text || kind == .web { return true }
        }
        return true
    }

    @MainActor
    static func decide(_ method: String, _ arguments: [String: Any]) async -> Bool {
        guard let bridge = MacPlatformBridge.Shared.instance else { return false }
        return await withCheckedContinuation { continuation in
            bridge.requestApplication(method, arguments: arguments) { value in
                continuation.resume(returning: value as? Bool == true)
            }
        }
    }
}
