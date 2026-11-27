import AppKit
import Carbon
import ApplicationServices

final class SelectionMonitor {
    private(set) var automatic = false
    private var excludedApps: Set<String> = []
    private var hotKeys: [GlobalHotKey: RegisteredHotKey] = [:]
    private var nextHotKeyId: UInt32 = 1
    var isCapturingScreenshot = false
    private var hotKeyHandler: EventHandlerRef?
    private var pointerGeneration = 0
    private var keyGeneration = 0
    private var keyEvents: Task<Void, Never>?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var keyboardMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var selectionObserver: AXObserver?
    private var observedPID: pid_t?
    private var selectionElement: AXUIElement?
    private var validationTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var ignoreMouseGesture = false
    private var pendingKeySelection: (keyCode: UInt16, gesture: SelectionGesture)?

    struct RegisteredHotKey {
        let id: UInt32
        let binding: HotKeyBinding
        let reference: EventHotKeyRef
    }

    struct HotKeyBinding: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    func configure(automatic: Bool, excludedApps: Set<String>, shortcuts: [GlobalHotKey: HotKeyBinding]) throws {
        guard Set(GlobalHotKey.allCases) == Set(shortcuts.keys) else {
            throw NSError(domain: AppConstants.errorDomain, code: 4, userInfo: [NSLocalizedDescriptionKey: "全局快捷键配置不完整。"])
        }
        for purpose in GlobalHotKey.allCases {
            let binding = shortcuts[purpose]!
            do {
                try Self.validateShortcut(keyCode: binding.keyCode, modifiers: binding.modifiers)
            } catch {
                throw NSError(domain: AppConstants.errorDomain, code: (error as NSError).code, userInfo: [
                    NSLocalizedDescriptionKey: "「\(purpose.title)」\(error.localizedDescription)",
                ])
            }
        }
        guard Set(shortcuts.values).count == shortcuts.count else {
            throw NSError(domain: AppConstants.errorDomain, code: 3, userInfo: [NSLocalizedDescriptionKey: "翻译、输入翻译与截图快捷键不能相同。"])
        }
        if hotKeyHandler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard identifier.signature == 0x5452414E else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<SelectionMonitor>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in
                    guard let entry = monitor.hotKeys.first(where: { $0.value.id == identifier.id }) else { return }
                    if let recorder = MacPlatformBridge.Shared.instance?.shortcutRecorder {
                        recorder(entry.value.binding)
                        return
                    }
                    switch entry.key {
                    case .screenshot:
                        MacPlatformBridge.Shared.instance?.screenshot.capture()
                    case .translate:
                        monitor.capture(gesture: .hotkey)
                    case .input:
                        monitor.capture(gesture: .inputHotkey)
                    }
                }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
        var replacements: [GlobalHotKey: RegisteredHotKey] = [:]
        var created: [EventHotKeyRef] = []
        do {
            for purpose in GlobalHotKey.allCases {
                let binding = shortcuts[purpose]!
                if let existing = hotKeys.values.first(where: { $0.binding == binding }) {
                    replacements[purpose] = RegisteredHotKey(id: existing.id, binding: binding, reference: existing.reference)
                    continue
                }
                var reference: EventHotKeyRef?
                let id = nextHotKeyId
                nextHotKeyId += 1
                let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, EventHotKeyID(signature: 0x5452414E, id: id), GetEventDispatcherTarget(), OptionBits(kEventHotKeyExclusive), &reference)
                guard status == noErr, let reference else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "「\(purpose.title)」已被其他应用占用，请换一个组合。"])
                }
                created.append(reference)
                replacements[purpose] = RegisteredHotKey(id: id, binding: binding, reference: reference)
            }
        } catch {
            for reference in created { UnregisterEventHotKey(reference) }
            throw error
        }
        for old in hotKeys.values where !replacements.values.contains(where: { $0.id == old.id }) {
            UnregisterEventHotKey(old.reference)
        }
        hotKeys = replacements
        self.automatic = automatic
        self.excludedApps = excludedApps
        pointerGeneration += 1
        clearPendingKey()
        captureTask?.cancel()
        stopObservingSelection()
        MacPlatformBridge.Shared.instance?.invalidateSelection()
    }

    static func validateShortcut(keyCode: UInt32, modifiers: UInt32) throws {
        guard UInt16(exactly: keyCode).flatMap({ AppConstants.shortcutKeyNames[$0] }) != nil,
              keyCode != UInt32(AppConstants.escapeKeyCode),
              modifiers & AppConstants.shortcutRequiredModifiers != 0,
              modifiers & ~AppConstants.shortcutAllowedModifiers == 0 else {
            throw NSError(domain: AppConstants.errorDomain, code: 1, userInfo: [
                NSLocalizedDescriptionKey: "快捷键至少需要 Control、Option 或 Command，并搭配一个非 Esc 按键。",
            ])
        }
        let commandOnly = modifiers & ~UInt32(shiftKey) == UInt32(cmdKey)
        guard !(commandOnly && AppConstants.textEditingKeyCodes.contains(keyCode)) else {
            throw NSError(domain: AppConstants.errorDomain, code: 5, userInfo: [
                NSLocalizedDescriptionKey: "这个组合是全选、撤销、剪切、复制或粘贴快捷键，请换一个组合。",
            ])
        }
        var shortcuts: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&shortcuts)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        for item in shortcuts?.takeRetainedValue() as? [[String: Any]] ?? [] {
            if item[kHISymbolicHotKeyEnabled as String] as? Bool == true,
               item[kHISymbolicHotKeyCode as String] as? UInt32 == keyCode,
               item[kHISymbolicHotKeyModifiers as String] as? UInt32 == modifiers {
                throw NSError(domain: AppConstants.errorDomain, code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "这个组合已用于 macOS 系统快捷键，请换一个组合。",
                ])
            }
        }
    }

    func start() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AppConstants.axMessagingTimeout)
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask) { [weak self] event in
            guard !SyntheticEvent.isMarked(event) else { return event }
            let type = event.type
            guard self?.automatic == true || type == .leftMouseDown else { return event }
            let clickCount = event.clickCount
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                self?.consumeMouse(type: type, clickCount: clickCount, location: location)
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in
            guard !SyntheticEvent.isMarked(event) else { return }
            let type = event.type
            guard self?.automatic == true || type == .leftMouseDown else { return }
            let clickCount = event.clickCount
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                self?.consumeMouse(type: type, clickCount: clickCount, location: location)
            }
        }
        keyboardMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard !SyntheticEvent.isMarked(event) else { return }
            let type = event.type
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            guard self?.automatic == true || type == .keyUp || keyCode == AppConstants.escapeKeyCode else { return }
            Task { @MainActor in
                self?.consumeKey(type: type, keyCode: keyCode, modifiers: modifiers)
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                self?.captureTask?.cancel()
                self?.clearPendingKey()
                self?.stopObservingSelection()
                MacPlatformBridge.Shared.instance?.sourceApplicationChanged(to: app?.processIdentifier)
            }
        }
    }

    deinit {
        for registered in hotKeys.values { UnregisterEventHotKey(registered.reference) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        captureTask?.cancel()
        validationTask?.cancel()
        keyEvents?.cancel()
        for monitor in [localMouseMonitor, globalMouseMonitor, keyboardMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let selectionObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(selectionObserver), .commonModes)
        }
    }

    @MainActor
    private func consumeMouse(type: NSEvent.EventType, clickCount: Int, location: NSPoint) {
        guard !isCapturingScreenshot else { return }
        let bridge = MacPlatformBridge.Shared.instance
        if type == .leftMouseDown {
            clearPendingKey()
            ignoreMouseGesture = bridge?.overlayContains(location) == true
                || NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
        }
        guard !ignoreMouseGesture else { return }
        let kind: String
        switch type {
        case .leftMouseDown:
            captureTask?.cancel()
            stopObservingSelection()
            bridge?.invalidateSelection()
            pointerGeneration += 1
            kind = AppConstants.pointerDownKind
        case .leftMouseUp: kind = AppConstants.pointerUpKind
        default: return
        }
        guard automatic else { return }
        let generation = pointerGeneration
        let request: [String: Any] = ["kind": kind, "clickCount": clickCount, "x": location.x, "y": location.y]
        Task { @MainActor [weak self] in
            let gesture = await bridge?.requestApplication(AppConstants.selectionPointerMethod, arguments: request) as? String
            guard let self, self.pointerGeneration == generation,
                  let gesture = gesture.flatMap(SelectionGesture.init(rawValue:)) else { return }
            self.capture(gesture: gesture)
        }
    }

    private func clearPendingKey() {
        pendingKeySelection = nil
        keyGeneration += 1
    }

    @MainActor
    private func consumeKey(type: NSEvent.EventType, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard !isCapturingScreenshot else { return }
        let bridge = MacPlatformBridge.Shared.instance
        if keyCode == AppConstants.escapeKeyCode, type == .keyDown {
            clearPendingKey()
            captureTask?.cancel()
            stopObservingSelection()
            bridge?.invalidateSelection(eventType: AppConstants.escapePressedMethod)
            return
        }
        let previous = keyEvents
        if automatic, type == .keyDown {
            guard let key = SelectionGesture.keyName(keyCode: keyCode, modifiers: modifiers) else { return }
            let generation = keyGeneration
            let request: [String: Any] = ["key": key, "modifiers": ShortcutNames.names(flags: modifiers)]
            keyEvents = Task { @MainActor [weak self] in
                await previous?.value
                let gesture = await bridge?.requestApplication(AppConstants.selectionKeyMethod, arguments: request) as? String
                guard let self, self.keyGeneration == generation,
                      let gesture = gesture.flatMap(SelectionGesture.init(rawValue:)) else { return }
                self.pendingKeySelection = (keyCode, gesture)
            }
            return
        }
        guard type == .keyUp else { return }
        keyEvents = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !self.isCapturingScreenshot else { return }
            if let pending = self.pendingKeySelection, pending.keyCode == keyCode {
                self.pendingKeySelection = nil
                self.capture(gesture: pending.gesture)
                return
            }
            if bridge?.hasSelection == true, self.observedPID != nil {
                self.validateSelection()
            }
        }
    }

    @MainActor
    private func capture(gesture: SelectionGesture) {
        guard !isCapturingScreenshot else { return }
        guard gesture.isExplicit || MacPlatformBridge.Shared.instance?.retainsResult != true else { return }
        captureTask?.cancel()
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid(),
              !excludedApps.contains(app.bundleIdentifier ?? "") else { return }
        let pid = app.processIdentifier
        let sourceAppName = app.localizedName
        if gesture == .hotkey {
            stopObservingSelection()
            let anchor = NSEvent.mouseLocation
            MacPlatformBridge.Shared.instance?.emitSelectionCaptured(
                text: "", gesture: gesture.rawValue, readFailure: nil, x: anchor.x, y: anchor.y,
                sourcePID: pid, sourceAppName: sourceAppName, inputAnchor: nil, inputSelection: nil
            )
            return
        }
        let inputReadStart: ContinuousClock.Instant? = gesture == .inputHotkey ? ContinuousClock.now : nil
        captureTask = Task { @MainActor [weak self] in
            if !gesture.isExplicit {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            }
            var selection = await AccessibilitySelection.readFrontmostSelection(sourcePID: pid, allowCopy: gesture.isExplicit)
            if gesture == .inputHotkey, (selection.text ?? "").isEmpty, !Task.isCancelled,
               await AccessibilitySelection.selectAllInFocusedTextInput(sourcePID: pid) {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                selection = await AccessibilitySelection.readFrontmostSelection(sourcePID: pid, allowCopy: true)
            }
            guard self?.isCapturingScreenshot != true, !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  gesture.isExplicit || MacPlatformBridge.Shared.instance?.retainsResult != true else { return }
            let text = selection.text ?? ""
            var readFailure: SelectionReadFailure?
            if gesture.isExplicit, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               await AccessibilitySelection.focusIsSecure(sourcePID: pid) {
                readFailure = .secureField
            }
            let keyboardCandidate = gesture == .selectAll || gesture == .keyboard
                ? await AccessibilitySelection.permitsKeyboardTrigger(sourcePID: pid) : false
            guard !Task.isCancelled else { return }
            guard gesture.isExplicit || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || keyboardCandidate else {
                MacPlatformBridge.Shared.instance?.invalidateSelection()
                return
            }
            let anchor = NSEvent.mouseLocation
            MacPlatformBridge.Shared.instance?.emitSelectionCaptured(
                text: text, gesture: gesture.rawValue, readFailure: readFailure, x: anchor.x, y: anchor.y, sourcePID: pid, sourceAppName: sourceAppName,
                inputAnchor: gesture == .inputHotkey ? AccessibilitySelection.inputAnchor(sourcePID: pid, selectionElement: selection.element) : nil,
                inputSelection: gesture == .inputHotkey ? selection.element : nil
            )
            if let inputReadStart { PerformanceLog.record("input-read", since: inputReadStart) }
            self?.watchSelection(sourcePID: pid, selectionElement: selection.element)
        }
    }

    @MainActor
    private func watchSelection(sourcePID: pid_t, selectionElement: AXUIElement?) {
        stopObservingSelection()
        observedPID = sourcePID
        self.selectionElement = selectionElement
        let app = AXUIElementCreateApplication(sourcePID)
        guard let element = AccessibilitySelection.focusedElement(from: app) else { return }
        var observer: AXObserver?
        let status = AXObserverCreate(sourcePID, { observer, _, _, context in
            guard let context else { return }
            let monitor = Unmanaged<SelectionMonitor>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                guard let active = monitor.selectionObserver, CFEqual(active, observer),
                      monitor.observedPID != nil else { return }
                monitor.validateSelection()
            }
        }, &observer)
        guard status == .success, let observer else { return }
        selectionObserver = observer
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString, context)
        AXObserverAddNotification(observer, selectionElement ?? element, kAXSelectedTextChangedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    @MainActor
    private func validateSelection() {
        validationTask?.cancel()
        guard let pid = observedPID else { return }
        validationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self, self.observedPID == pid else { return }
            let readable = await AccessibilitySelection.hasReadableSelection(sourcePID: pid, selectionElement: self.selectionElement)
            guard !Task.isCancelled, self.observedPID == pid else { return }
            if readable == false {
                MacPlatformBridge.Shared.instance?.invalidateSelection()
                self.stopObservingSelection()
            }
        }
    }

    private func stopObservingSelection() {
        validationTask?.cancel()
        validationTask = nil
        if let selectionObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(selectionObserver), .commonModes)
        }
        selectionObserver = nil
        observedPID = nil
        selectionElement = nil
    }
}

extension ShortcutNames {
    static func binding(_ value: Any?) -> SelectionMonitor.HotKeyBinding? {
        guard let shortcut = value as? [String: Any],
              let key = shortcut["key"] as? String,
              let keyCode = keyCodes[key],
              let names = shortcut["modifiers"] as? [String] else { return nil }
        let carbon = AppConstants.shortcutModifierNames.filter { names.contains($0.name) }.reduce(UInt32(0)) { $0 | $1.carbon }
        return SelectionMonitor.HotKeyBinding(keyCode: UInt32(keyCode), modifiers: carbon)
    }

    static func shortcut(_ binding: SelectionMonitor.HotKeyBinding, label: String) -> [String: Any]? {
        guard let key = UInt16(exactly: binding.keyCode).flatMap({ AppConstants.shortcutKeyNames[$0] }) else { return nil }
        return ["key": key, "modifiers": names(carbon: binding.modifiers), "label": label]
    }
}
