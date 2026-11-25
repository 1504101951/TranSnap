import Foundation

enum TextSelectionContext {
    static let textRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXSearchField", "AXComboBox", "AXWebArea", "AXTextView",
    ]
    static let nonTextRoles: Set<String> = [
        "AXOutline", "AXTable", "AXBrowser", "AXRow", "AXCell", "AXColumn",
        "AXImage", "AXButton", "AXMenu", "AXMenuBar", "AXMenuItem", "AXToolbar", "AXTabGroup",
    ]

    static func shouldReadSelectedText(ancestorRoles: [String]) -> Bool {
        for role in ancestorRoles {
            if nonTextRoles.contains(role) { return false }
            if textRoles.contains(role) { return true }
        }
        return true
    }

    static func shouldCopySelection(ancestorRoles: [String], hasAXText: Bool, allowCopy: Bool) -> Bool {
        guard allowCopy else { return false }
        guard !ancestorRoles.contains(where: { nonTextRoles.contains($0) }) else { return false }
        return !hasAXText || ancestorRoles.contains("AXWebArea")
    }

    private static let invisibleCharacters: Set<Character> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}",
    ]

    private static let listMarkerCharacters: Set<Character> = [
        "•", "◦", "▪", "▫", "‣", "⁃", "●", "○", "■", "□",
    ]

    static func matchesCopiedSelection(axText: String, copiedText: String) -> Bool {
        let strippedAX = axText.filter { !$0.isWhitespace && !invisibleCharacters.contains($0) }
        let strippedCopied = copiedText.filter { !$0.isWhitespace && !invisibleCharacters.contains($0) }
        guard !strippedCopied.isEmpty else { return false }
        if strippedAX == strippedCopied { return true }
        let normalizedAX = strippedAX.filter { !listMarkerCharacters.contains($0) }
        let normalizedCopied = strippedCopied.filter { !listMarkerCharacters.contains($0) }
        return !normalizedCopied.isEmpty && normalizedAX == normalizedCopied
    }
}
