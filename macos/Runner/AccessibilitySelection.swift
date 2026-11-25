import ApplicationServices
import AppKit
import Carbon
import Darwin
import Foundation

struct InputAnchor: Equatable {
    let selection: NSRect
    let window: NSRect?
}

enum AccessibilitySelection {
    static func isTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func readFrontmostSelection(sourcePID: pid_t, allowCopy: Bool) async -> (text: String?, element: AXUIElement?) {
        guard !Task.isCancelled, sourcePID != getpid(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return (nil, nil) }
        let app = AXUIElementCreateApplication(sourcePID)
        enableManualAccessibility(app)
        var result = readOnce(app: app)
        for delay in [80, 180] where !isUsable(result.text) {
            do { try await Task.sleep(for: .milliseconds(delay)) } catch { return (nil, nil) }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return (nil, nil) }
            result = readOnce(app: app)
        }
        guard !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID,
              !isSecure(focusedElement(from: app)) else { return (nil, nil) }
        let copyRoles = focusedElement(from: app).map(ancestorRoles(of:)) ?? []
        if TextSelectionContext.shouldCopySelection(ancestorRoles: copyRoles, hasAXText: isUsable(result.text), allowCopy: allowCopy),
           let copied = await readByCopyingSelection(pasteboard: .general, copy: postCopyKey, accepts: { copied in
               guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return false }
               guard let original = result.text else { return true }
               return TextSelectionContext.matchesCopiedSelection(axText: original, copiedText: copied)
           }) {
            return (copied, result.element)
        }
        return result
    }

    static func hasReadableSelection(sourcePID: pid_t, selectionElement: AXUIElement?) async -> Bool? {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return false }
        let app = AXUIElementCreateApplication(sourcePID)
        guard let element = focusedElement(from: app) else { return nil }
        guard !isSecure(element), TextSelectionContext.shouldReadSelectedText(ancestorRoles: ancestorRoles(of: element)) else { return false }
        if let selectionElement, selection(from: selectionElement) != nil { return true }
        if isUsable(readOnce(app: app).text) { return true }
        guard let selectionElement else { return nil }
        if let text = selectedTextMarker(from: selectionElement) { return isUsable(text) }
        if let text = stringAttribute(selectionElement, kAXSelectedTextAttribute as CFString) {
            return isUsable(text)
        }
        if let value = attribute(selectionElement, kAXSelectedTextRangeAttribute as CFString),
           CFGetTypeID(value) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(value as! AXValue, .cfRange, &range), range.length == 0 { return false }
        }
        return nil
    }

    static func permitsKeyboardTrigger(sourcePID: pid_t) async -> Bool {
        guard AXIsProcessTrusted(), NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return false }
        let app = AXUIElementCreateApplication(sourcePID)
        guard let focused = focusedElement(from: app) else { return true }
        return !isSecure(focused) && TextSelectionContext.shouldReadSelectedText(ancestorRoles: ancestorRoles(of: focused))
    }

    private static func readOnce(app: AXUIElement) -> (text: String?, element: AXUIElement?) {
        var candidates: [AXUIElement] = []
        if let focused = focusedElement(from: app) {
            guard !isSecure(focused), TextSelectionContext.shouldReadSelectedText(ancestorRoles: ancestorRoles(of: focused)) else {
                return (nil, nil)
            }
            candidates.append(focused)
        }
        if let systemFocused = systemFocusedElement(),
           !candidates.contains(where: { CFEqual($0, systemFocused) }) {
            candidates.append(systemFocused)
        }

        if let window = axElement(attribute(app, kAXFocusedWindowAttribute as CFString)) {
            candidates.append(window)
        }
        for element in candidates {
            if isSecure(element) { return (nil, nil) }
            let roles = ancestorRoles(of: element)
            if !TextSelectionContext.shouldReadSelectedText(ancestorRoles: roles) {
                continue
            }
            if let text = selection(from: element) {
                return (text, element)
            }
        }
        if let hit = searchSelectedText(roots: candidates.filter {
            !isSecure($0) && TextSelectionContext.shouldReadSelectedText(ancestorRoles: ancestorRoles(of: $0))
        }) {
            return hit
        }
        return (nil, nil)
    }

    private static func enableManualAccessibility(_ app: AXUIElement) {
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    static func focusedElement(from app: AXUIElement) -> AXUIElement? {
        axElement(attribute(app, kAXFocusedUIElementAttribute as CFString))
    }

    private static func systemFocusedElement() -> AXUIElement? {
        axElement(attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString))
    }

    private static func axElement(_ value: AnyObject?) -> AXUIElement? {
        guard let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func selection(from element: AXUIElement) -> String? {
        if let text = selectedTextMarker(from: element), isUsable(text) {
            return text
        }
        if let text = stringAttribute(element, kAXSelectedTextAttribute as CFString), isUsable(text) {
            return text
        }
        if let text = selectedTextFromValue(element), isUsable(text) {
            return text
        }
        return nil
    }

    private static func selectedTextMarker(from element: AXUIElement) -> String? {
        guard let marker = attribute(element, kAXSelectedTextMarkerRangeAttribute as CFString),
              CFGetTypeID(marker) == AXTextMarkerRangeGetTypeID() else { return nil }
        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForTextMarkerRangeParameterizedAttribute as CFString, marker, &value)
        guard status == .success, let text = value as? String else { return nil }
        return text
    }

    private static func selectedTextFromValue(_ element: AXUIElement) -> String? {
        guard let value = stringAttribute(element, kAXValueAttribute as CFString) else { return nil }
        guard let rangeValue = attribute(element, kAXSelectedTextRangeAttribute as CFString) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        guard range.location >= 0, range.length > 0 else { return nil }
        let utf16 = value.utf16
        guard range.location + range.length <= utf16.count else { return nil }
        let start = utf16.index(utf16.startIndex, offsetBy: range.location)
        let end = utf16.index(start, offsetBy: range.length)
        return String(utf16[start..<end])
    }

    private static func searchSelectedText(roots: [AXUIElement]) -> (text: String, element: AXUIElement)? {
        var queue = roots
        var seen = 0
        while !queue.isEmpty, seen < 80 {
            let element = queue.removeFirst()
            seen += 1
            if isSecure(element) { continue }
            if let nodeRole = role(of: element), TextSelectionContext.nonTextRoles.contains(nodeRole) {
                continue
            }
            if let text = selection(from: element) { return (text, element) }
            queue.append(contentsOf: children(of: element))
        }
        return nil
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(element, kAXChildrenAttribute as CFString) else { return [] }
        guard let array = value as? NSArray else { return [] }
        return array.map { $0 as! AXUIElement }
    }

    private static func role(of element: AXUIElement) -> String? {
        stringAttribute(element, kAXRoleAttribute as CFString)
    }

    private static func ancestorRoles(of element: AXUIElement) -> [String] {
        var roles: [String] = []
        var current: AXUIElement? = element
        var steps = 0
        while let node = current, steps < 64 {
            if let role = role(of: node) { roles.append(role) }
            current = axElement(attribute(node, kAXParentAttribute as CFString))
            steps += 1
        }
        return roles
    }

    static func focusIsSecure(sourcePID: pid_t) async -> Bool {
        isSecure(focusedElement(from: AXUIElementCreateApplication(sourcePID)))
    }

    private static func isSecure(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        let role = role(of: element)
        let subrole = stringAttribute(element, kAXSubroleAttribute as CFString)
        return role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    private static func isUsable(_ text: String?) -> Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> AnyObject? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name, &value)
        guard status == .success else { return nil }
        return value
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        attribute(element, name) as? String
    }

    static func readByCopyingSelection(
        pasteboard: NSPasteboard, copy: () -> Void, accepts: (String) -> Bool
    ) async -> String? {
        guard !Task.isCancelled else { return nil }
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        let changeCount = pasteboard.changeCount
        copy()
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            guard !Task.isCancelled else { return nil }
            if pasteboard.changeCount != changeCount {
                let copiedChangeCount = pasteboard.changeCount
                let text = pasteboard.string(forType: .string)
                let accepted = text.map { isUsable($0) && accepts($0) } ?? false
                guard pasteboard.changeCount == copiedChangeCount else { return nil }
                snapshot.restore(pasteboard)
                guard accepted, !Task.isCancelled else { return nil }
                return text
            }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return nil }
        }
        return nil
    }

    static func inputAnchor(sourcePID: pid_t, selectionElement: AXUIElement?) -> InputAnchor {
        let app = AXUIElementCreateApplication(sourcePID)
        let window = axElement(attribute(app, kAXFocusedWindowAttribute as CFString)).flatMap(elementRect)
        let focused = focusedElement(from: app)
        let selection = (selectionElement ?? focused).flatMap { textRangeRect(of: $0) ?? elementRect($0) }
            ?? focused.flatMap(elementRect)
        if let selection { return InputAnchor(selection: selection, window: window) }
        let mouse = NSEvent.mouseLocation
        return InputAnchor(selection: NSRect(x: mouse.x, y: mouse.y, width: 1, height: 1), window: window)
    }

    private static func textRangeRect(of element: AXUIElement) -> NSRect? {
        let candidates: [(range: CFString, bounds: CFString)] = [
            (AppConstants.axSelectedTextMarkerRangeAttribute as CFString, AppConstants.axBoundsForTextMarkerRangeAttribute as CFString),
            (kAXSelectedTextRangeAttribute as CFString, kAXBoundsForRangeParameterizedAttribute as CFString),
        ]
        for candidate in candidates {
            var bounds: CFTypeRef?
            if let range = attribute(element, candidate.range),
               AXUIElementCopyParameterizedAttributeValue(element, candidate.bounds, range, &bounds) == .success,
               let rect = axRect(bounds), !rect.isEmpty {
                return CaptureGeometry.appKitRect(fromCGWindowBounds: rect)
            }
        }
        return nil
    }

    private static func elementRect(_ element: AXUIElement) -> NSRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue = attribute(element, kAXPositionAttribute as CFString),
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              let sizeValue = attribute(element, kAXSizeAttribute as CFString),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CaptureGeometry.appKitRect(fromCGWindowBounds: CGRect(origin: position, size: size))
    }

    private static func axRect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rect) ? rect : nil
    }

    static func focusWritableInput(sourcePID: pid_t, selection: AXUIElement?) async -> Bool {
        let app = AXUIElementCreateApplication(sourcePID)
        guard let focused = focusedElement(from: app) else { return true }
        if let selection, CFEqual(selection, focused) { return true }
        if let role = role(of: focused), AppConstants.axTextInputRoles.contains(role), !isSecure(focused) { return true }
        guard let window = axElement(attribute(app, kAXFocusedWindowAttribute as CFString)) else { return false }
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var index = 0
        var found: [AXUIElement] = []
        let deadline = ContinuousClock.now + AppConstants.inputTargetSearchTimeout
        while index < queue.count, index < AppConstants.inputTargetSearchMaxNodes, found.count < 2 {
            guard ContinuousClock.now < deadline else { return false }
            let (element, depth) = queue[index]
            index += 1
            if isWritableInput(element) { found.append(element); continue }
            guard depth < AppConstants.inputTargetSearchMaxDepth,
                  let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        guard found.count == 1,
              AXUIElementSetAttributeValue(found[0], kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success else { return false }
        try? await Task.sleep(for: AppConstants.inputTargetFocusDelay)
        return true
    }

    private static func isWritableInput(_ element: AXUIElement) -> Bool {
        guard let role = role(of: element), AppConstants.axTextInputRoles.contains(role), !isSecure(element) else { return false }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    static func selectAllInFocusedTextInput(sourcePID: pid_t) async -> Bool {
        guard !IsSecureEventInputEnabled(),
              let focused = focusedElement(from: AXUIElementCreateApplication(sourcePID)),
              !isSecure(focused),
              let role = role(of: focused),
              AppConstants.axTextInputRoles.contains(role) else { return false }
        postCommandKey(0x00)
        return true
    }

    static func pasteReplacingSelection(_ text: String, pasteboard: NSPasteboard, paste: () -> Void) async -> Bool {
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore(pasteboard)
            return false
        }
        let written = pasteboard.changeCount
        paste()
        try? await Task.sleep(for: AppConstants.pasteRestoreDelay)
        if pasteboard.changeCount == written { snapshot.restore(pasteboard) }
        return true
    }

    private static func postCopyKey() {
        postCommandKey(0x08)
    }

    static func postPasteKey() {
        postCommandKey(0x09)
    }

    private static func postCommandKey(_ virtualKey: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down.map(SyntheticEvent.mark)
        up.map(SyntheticEvent.mark)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

private struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let encoded = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    values[type] = data
                }
            }
            return values
        }
        return PasteboardSnapshot(items: encoded)
    }

    func restore(_ pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let objects = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(objects)
    }
}
