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

    static func shouldCopySelection(
        ancestorRoles: [String],
        hasAXText: Bool,
        allowCopy: Bool,
        axText: String? = nil
    ) -> Bool {
        guard allowCopy else { return false }
        guard !ancestorRoles.contains(where: { nonTextRoles.contains($0) }) else { return false }
        return !hasAXText || ancestorRoles.contains("AXWebArea") || (axText.map(hasInlineListMarker) ?? false)
    }

    private static func hasInlineListMarker(_ text: String) -> Bool {
        var afterContent = false
        for character in text {
            if character == "\n" || character == "\r" {
                afterContent = false
            } else if afterContent && listMarkerCharacters.contains(character) {
                return true
            } else if !character.isWhitespace {
                afterContent = true
            }
        }
        return false
    }

    private static let invisibleCharacters: Set<Character> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}",
    ]

    private static let listMarkerCharacters: Set<Character> = [
        "•", "◦", "▪", "▫", "‣", "⁃", "●", "○", "■", "□",
    ]

    static func acceptsCopiedText(ancestorRoles: [String], axText: String?, copiedText: String) -> Bool {
        guard copiedText.contains(where: { !$0.isWhitespace }) else { return false }
        guard let axText, !ancestorRoles.contains("AXWebArea") else { return true }
        return matchesCopiedSelection(axText: axText, copiedText: copiedText)
    }

    static func matchesCopiedSelection(axText: String, copiedText: String) -> Bool {
        let strippedAX = axText.filter { !$0.isWhitespace && !invisibleCharacters.contains($0) }
        let strippedCopied = copiedText.filter { !$0.isWhitespace && !invisibleCharacters.contains($0) }
        guard !strippedCopied.isEmpty else { return false }
        if strippedAX == strippedCopied { return true }
        let normalizedAX = Array(strippedAX.filter { !listMarkerCharacters.contains($0) })
        let normalizedCopied = Array(strippedCopied.filter { !listMarkerCharacters.contains($0) })
        guard !normalizedCopied.isEmpty, !normalizedAX.isEmpty else { return false }
        if normalizedAX == normalizedCopied { return true }
        let (shorter, longer) = normalizedAX.count <= normalizedCopied.count
            ? (normalizedAX, normalizedCopied) : (normalizedCopied, normalizedAX)
        guard shorter.count * 2 >= longer.count else { return false }
        var index = longer.startIndex
        for character in shorter {
            guard let found = longer[index...].firstIndex(of: character) else { return false }
            index = longer.index(after: found)
        }
        return true
    }
}
