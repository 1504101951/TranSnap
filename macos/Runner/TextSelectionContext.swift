import Foundation

/// 文件树/表格不是文本选区；聊天列表可以。
enum TextSelectionContext {
    static let textRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXSearchField", "AXComboBox", "AXWebArea", "AXTextView",
    ]
    static let nonTextRoles: Set<String> = [
        "AXOutline", "AXTable", "AXBrowser", "AXRow", "AXCell", "AXColumn",
        "AXImage", "AXButton", "AXMenu", "AXMenuBar", "AXMenuItem", "AXToolbar", "AXTabGroup",
    ]

    /// ancestorRoles为由近到远的AX祖先角色；遇到非文本角色返回false，遇到文本角色返回true，未识别角色时允许继续读取。
    static func shouldReadSelectedText(ancestorRoles: [String]) -> Bool {
        for role in ancestorRoles {
            if nonTextRoles.contains(role) { return false }
            if textRoles.contains(role) { return true }
        }
        return true
    }

    /// ancestorRoles 为祖先角色，hasAXText 为 AX 可读性，allowCopy 仅由明确翻译操作开启；返回是否复制。
    static func shouldCopySelection(ancestorRoles: [String], hasAXText: Bool, allowCopy: Bool) -> Bool {
        // 被动检测不能向来源 App 注入按键，复制可能结束聊天软件的多选状态。
        guard allowCopy else { return false }
        guard !ancestorRoles.contains(where: { nonTextRoles.contains($0) }) else { return false }
        // 浏览器 AX 文本可能已丢段落；其他文本控件仅在 AX 无文字时才回退到复制。
        return !hasAXText || ancestorRoles.contains("AXWebArea")
    }

    private static let invisibleCharacters: Set<Character> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}",
    ]

    private static let listMarkerCharacters: Set<Character> = [
        "•", "◦", "▪", "▫", "‣", "⁃", "●", "○", "■", "□",
    ]

    /// axText 为辅助功能读取文本，copiedText 为模拟复制文本；忽略空白、零宽字符及浏览器注入的列表项目符号（• 等）后比较是否同一段选区，防止网页列表因换行和项目符号差异丢失复制生成的换行。
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
