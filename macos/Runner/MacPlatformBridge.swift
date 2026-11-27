import Cocoa
import Carbon
import CoreServices
import Security
import LocalAuthentication
import ServiceManagement
import FlutterMacOS

final class MacPlatformBridge: NSObject, FlutterStreamHandler {
    static let methodChannelName = AppConstants.platformChannel
    static let eventChannelName = AppConstants.platformEventsChannel

    private var eventSink: FlutterEventSink?
    private let overlay: OverlayPanelController
    private let selectionMonitor: SelectionMonitor
    let screenshot = ScreenshotWindowController()
    @MainActor lazy var live: LiveRegionCoordinator = LiveRegionCoordinator(bridge: self, controls: self.capture)
    @MainActor lazy var capture: CaptureWindowController = {
        let controller = CaptureWindowController(screenshot: screenshot)
        controller.onActiveChanged = { active in
            StatusBarController.shared.setCaptureActive(active)
        }
        return controller
    }()
    @MainActor lazy var mcp = MCPCaptureServer(
        isEnabled: {
            let preferences = AppPreferences.current
            return preferences[AppConstants.mcpEnabledKey] as? Bool == true
        },
        isControlEnabled: { AppPreferences.current[AppConstants.mcpControlEnabledKey] as? Bool == true },
        run: MCPToolRunner.run,
        isTrustedPeer: MCPPeer.isTrustedHelper
    )
    private let speech = SpeechService()
    @MainActor lazy var systemTranslation = SystemTranslationService()
    private var methods: FlutterMethodChannel?
    var onReady: (() -> Void)? {
        didSet {
            if pendingAppReady, let onReady {
                pendingAppReady = false
                onReady()
            }
        }
    }
    private var pendingAppReady = false
    private var inputAnchor: InputAnchor?
    private var inputSelection: AXUIElement?
    var closePermissionWizard: (() -> Void)?
    var shortcutRecorder: ((SelectionMonitor.HotKeyBinding) -> Void)?
    private var currentSessionId: String?
    private var sourceProcessIdentifier: pid_t?
    private var selectionReadTask: Task<Void, Never>?
    var hasSelection: Bool { currentSessionId != nil }
    private(set) var retainsResult = false

    init(overlay: OverlayPanelController, selectionMonitor: SelectionMonitor) {
        self.overlay = overlay
        self.selectionMonitor = selectionMonitor
        super.init()
        screenshot.onPrepareCapture = { [weak self] source, scrolling, region in
            guard let self else { return }
            if source["live"] as? Bool == true {
                try await self.live.begin(source: source, region: region)
                return
            }
            try self.capture.prepare(source: source, scrolling: scrolling, region: region)
        }
        screenshot.onPreviewLiveRegion = { [weak self] screen in
            self?.live.preview(on: screen)
        }
        screenshot.onCancelLivePreview = { [weak self] in
            self?.live.cancelPreview()
        }
        screenshot.onCaptureSources = { [weak self] preferred in
            guard let self else { throw CancellationError() }
            return try await self.capture.sources(preferredApplicationID: preferred)
        }
        screenshot.onPrepareCaptureControls = { [weak self] in
            self?.capture.prepareControls()
        }
        screenshot.onCapturingChanged = { [weak self] active in
            self?.selectionMonitor.isCapturingScreenshot = active
        }
        screenshot.onFrozenEditorVisibleChanged = { [weak self] visible in
            self?.overlay.setCaptureHidden(visible)
        }
    }

    @discardableResult
    static func register(with messenger: FlutterBinaryMessenger, overlay: OverlayPanelController, selectionMonitor: SelectionMonitor) -> MacPlatformBridge {
        let instance = MacPlatformBridge(overlay: overlay, selectionMonitor: selectionMonitor)
        let methods = FlutterMethodChannel(name: methodChannelName, binaryMessenger: messenger)
        instance.methods = methods
        methods.setMethodCallHandler { call, result in
            instance.handle(call, result: result)
        }
        let events = FlutterEventChannel(name: eventChannelName, binaryMessenger: messenger)
        events.setStreamHandler(instance)
        Shared.instance = instance
        return instance
    }

    enum Shared {
        static var instance: MacPlatformBridge?
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case AppConstants.showOverlayMethod:
            guard let sessionId = args["sessionId"] as? String,
                  let x = args["x"] as? Double,
                  let y = args["y"] as? Double
            else {
                result(Self.badArguments("showOverlay 需要 sessionId/x/y"))
                return
            }
            guard currentSessionId == sessionId else { result(nil); return }
            guard let width = args["width"] as? Double, let height = args["height"] as? Double,
                  x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 else {
                result(Self.badArguments("Overlay 坐标和尺寸必须有效"))
                return
            }
            overlay.show(
                at: NSPoint(x: x, y: y),
                size: NSSize(width: width, height: height),
                sessionId: sessionId
            )
            result(nil)
        case AppConstants.retainOverlayMethod:
            guard let sessionId = args["sessionId"] as? String else {
                result(Self.badArguments("retainOverlay 需要 sessionId")); return
            }
            if currentSessionId == sessionId { retainsResult = true }
            result(nil)
        case AppConstants.hideOverlayMethod:
            guard let sessionId = args["sessionId"] as? String else {
                result(Self.badArguments("hideOverlay 需要 sessionId"))
                return
            }
            guard currentSessionId == sessionId else { result(nil); return }
            selectionReadTask?.cancel()
            selectionReadTask = nil
            currentSessionId = nil
            sourceProcessIdentifier = nil
            retainsResult = false
            overlay.hide(sessionId: sessionId)
            MainActor.assumeIsolated { InputStatusBubble.shared.closeProgress() }
            result(nil)
        case AppConstants.setOverlaySizeMethod:
            guard let sessionId = args["sessionId"] as? String,
                  let width = args["width"] as? Double,
                  let height = args["height"] as? Double
            else {
                result(Self.badArguments("setOverlaySize 需要 sessionId/width/height"))
                return
            }
            guard currentSessionId == sessionId else { result(nil); return }
            guard width.isFinite, height.isFinite, width > 0, height > 0 else {
                result(Self.badArguments("Overlay 尺寸必须为正数"))
                return
            }
            overlay.resize(sessionId: sessionId, size: NSSize(width: width, height: height))
            result(nil)
        case AppConstants.dragOverlayMethod:
            guard let sessionId = args["sessionId"] as? String else {
                result(Self.badArguments("dragOverlay 需要 sessionId"))
                return
            }
            overlay.drag(sessionId: sessionId)
            result(nil)
        case AppConstants.showOverlayTooltipMethod:
            guard let sessionId = args["sessionId"] as? String,
                  let message = args["message"] as? String,
                  let x = args["x"] as? Double,
                  let y = args["y"] as? Double,
                  let width = args["width"] as? Double,
                  let height = args["height"] as? Double
            else {
                result(Self.badArguments("showOverlayTooltip 需要 sessionId/message/x/y/width/height"))
                return
            }
            guard width.isFinite, height.isFinite, width > 0, height > 0,
                  x.isFinite, y.isFinite
            else {
                result(Self.badArguments("Overlay Tooltip 坐标与尺寸必须有限且有效"))
                return
            }
            let preferAbove = args["preferAbove"] as? Bool ?? true
            overlay.showTooltip(
                sessionId: sessionId,
                message: message,
                anchor: NSRect(x: x, y: y, width: width, height: height),
                preferAbove: preferAbove
            )
            result(nil)
        case AppConstants.hideOverlayTooltipMethod:
            overlay.hideTooltip()
            result(nil)
        case AppConstants.readSelectionForTranslationMethod:
            guard let sessionId = args["sessionId"] as? String else {
                result(Self.badArguments("读取选区需要 sessionId")); return
            }
            guard currentSessionId == sessionId, let pid = sourceProcessIdentifier else { result(nil); return }
            selectionReadTask?.cancel()
            selectionReadTask = Task { @MainActor [weak self] in
                let selection = await AccessibilitySelection.readFrontmostSelection(sourcePID: pid, allowCopy: true)
                guard let self, !Task.isCancelled, self.currentSessionId == sessionId else { result(nil); return }
                let text = selection.text ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   await AccessibilitySelection.focusIsSecure(sourcePID: pid) {
                    guard !Task.isCancelled, self.currentSessionId == sessionId else { result(nil); return }
                    result(FlutterError(code: SelectionReadFailure.secureField.rawValue, message: "密码框中的文字不会被读取。", details: nil))
                    return
                }
                result(selection.text)
            }
        case AppConstants.replaceSelectionMethod:
            guard let sessionId = args["sessionId"] as? String, let text = args["text"] as? String else {
                result(Self.badArguments("替换选区需要 sessionId/text")); return
            }
            guard currentSessionId == sessionId, let pid = sourceProcessIdentifier else {
                result("输入已结束，未替换原文。"); return
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                result("来源应用已切换，未替换原文。"); return
            }
            guard !IsSecureEventInputEnabled() else { result("安全输入已开启，未替换原文。"); return }
            MainActor.assumeIsolated { InputStatusBubble.shared.closeProgress() }
            Task { @MainActor in
                guard await AccessibilitySelection.focusWritableInput(sourcePID: pid, selection: self.inputSelection) else {
                    result("没有可写入的输入框，未替换原文。"); return
                }
                let pasted = await AccessibilitySelection.pasteReplacingSelection(text, pasteboard: .general, paste: AccessibilitySelection.postPasteKey)
                result(pasted ? nil : "无法写入剪贴板，未替换原文。")
            }
        case AppConstants.showInputFailureMethod:
            guard let sessionId = args["sessionId"] as? String, let message = args["message"] as? String else {
                result(Self.badArguments("showInputFailure 需要 sessionId/message")); return
            }
            if currentSessionId == sessionId, let inputAnchor {
                MainActor.assumeIsolated { InputStatusBubble.shared.showFailure(message, anchor: inputAnchor) }
            }
            result(nil)
        case AppConstants.loadSettingsMethod:
            var settings = AppPreferences.current
            settings["systemLanguage"] = Locale.preferredLanguages.first ?? "en"
            settings[AppConstants.launchAtLoginKey] = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
            settings[AppConstants.screenshotSaveDirectoryKey] =
                ScreenshotStorage.rootDirectory(
                    UserDefaults.standard.string(forKey: AppConstants.screenshotSaveDirectoryKey)
                    ?? (settings[AppConstants.screenshotSaveDirectoryKey] as? String)).path
            result(settings)
        case AppConstants.chooseScreenshotDirectoryMethod:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "使用此目录"
            panel.begin { response in
                guard response == .OK, let url = panel.url else {
                    result(nil)
                    return
                }
                result(url.path)
            }
        case AppConstants.importStickerImageMethod:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.png, .jpeg, .gif, .heic, .webP]
            panel.allowsMultipleSelection = false
            panel.prompt = "添加贴纸"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { result(nil); return }
                do {
                    let image = try StickerImage.normalized(url: url)
                    result([
                        "bytes": FlutterStandardTypedData(bytes: try PNGEncoding.data(image)),
                        "width": image.width,
                        "height": image.height,
                    ])
                } catch {
                    result(Self.badArguments(error.localizedDescription))
                }
            }
        case AppConstants.saveStickerMethod:
            guard let id = args["id"] as? String, let bytes = args["bytes"] as? FlutterStandardTypedData else {
                result(Self.badArguments("保存贴纸需要 id/bytes")); return
            }
            do {
                try FileManager.default.createDirectory(at: AppConstants.stickersURL, withIntermediateDirectories: true)
                let url = AppConstants.stickersURL.appendingPathComponent("\(id).png")
                try bytes.data.write(to: url, options: .atomic)
                result(url.path)
            } catch {
                result(Self.badArguments(error.localizedDescription))
            }
        case AppConstants.stickerDirectoryMethod:
            result(AppConstants.stickersURL.path)
        case AppConstants.deleteStickerMethod:
            guard let id = args["id"] as? String else {
                result(Self.badArguments("删除贴纸需要 id")); return
            }
            try? FileManager.default.removeItem(at: AppConstants.stickersURL.appendingPathComponent("\(id).png"))
            result(nil)
        case AppConstants.applySettingsMethod:
            guard let settings = args["settings"] as? [String: Any],
                  let credentials = args["credentials"] as? [String: Any] else {
                result(FlutterError(code: AppConstants.badSettingsError, message: "设置数据不完整。", details: nil)); return
            }
            applySettings(settings, credentials: credentials, result: result)
        case AppConstants.readCredentialsMethod:
            guard let id = args["id"] as? String else {
                result(Self.badArguments("缺少服务标识。")); return
            }
            let readStart = ContinuousClock.now
            defer { PerformanceLog.record("credentials-read", since: readStart) }
            do { result(try Self.readCredentials(id: id) ?? [:]) }
            catch { result(FlutterError(code: AppConstants.keychainFailedError, message: error.localizedDescription, details: nil)) }
        case AppConstants.credentialIdsMethod:
            let ids = args["ids"] as? [String] ?? []
            var saved: [String] = []
            let context = LAContext()
            context.interactionNotAllowed = true
            for id in ids {
                let query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: AppConstants.credentialsKeychainService,
                    kSecAttrAccount as String: id,
                    kSecReturnAttributes as String: true,
                    kSecUseAuthenticationContext as String: context,
                ]
                let status = SecItemCopyMatching(query as CFDictionary, nil)
                guard status == errSecSuccess || status == errSecItemNotFound || status == errSecInteractionNotAllowed else {
                    result(FlutterError(code: AppConstants.keychainFailedError, message: "无法读取凭据状态，请检查钥匙串访问权限。", details: nil)); return
                }
                if status == errSecSuccess || status == errSecInteractionNotAllowed { saved.append(id) }
            }
            result(saved)
        case AppConstants.languageCandidatesMethod:
            guard let text = args["text"] as? String, let hints = args["hints"] as? [String: Double] else {
                result(Self.badArguments("缺少待识别文本或语言权重")); return
            }
            let detectStart = ContinuousClock.now
            defer { PerformanceLog.record("translate-detect", since: detectStart) }
            result(LanguageDetection.candidates(text, hints: hints))
        case AppConstants.openFileMethod, AppConstants.revealFileMethod, AppConstants.copyImageFileMethod:
            guard let path = args["path"] as? String else {
                result(Self.badArguments("缺少文件路径。")); return
            }
            let url = URL(fileURLWithPath: path)
            switch call.method {
            case AppConstants.openFileMethod:
                result(NSWorkspace.shared.open(url))
            case AppConstants.revealFileMethod:
                NSWorkspace.shared.activateFileViewerSelecting([url])
                result(nil)
            default:
                guard let png = try? Data(contentsOf: url) else {
                    result(FlutterError(code: AppConstants.copyFailedError, message: "图片文件不可读。", details: nil)); return
                }
                result(PNGPasteboard.write(png))
            }
        case AppConstants.stitchScreenshotsMethod:
            guard let paths = args["paths"] as? [String], let vertical = args["vertical"] as? Bool else {
                result(Self.badArguments("stitchScreenshots 需要 paths/vertical")); return
            }
            composeInBackground(result) {
                FlutterStandardTypedData(bytes: try ScreenshotComposer.stitch(paths: paths, vertical: vertical))
            }
        case AppConstants.splitScreenshotMethod:
            guard let path = args["path"] as? String, let parts = args["parts"] as? Int else {
                result(Self.badArguments("splitScreenshot 需要 path/parts")); return
            }
            composeInBackground(result) {
                try ScreenshotComposer.split(path: path, parts: parts).map(FlutterStandardTypedData.init(bytes:))
            }
        case AppConstants.compareScreenshotsMethod:
            guard let first = args["first"] as? String, let second = args["second"] as? String else {
                result(Self.badArguments("compareScreenshots 需要 first/second")); return
            }
            composeInBackground(result) {
                let comparison = try ScreenshotComposer.compare(first: first, second: second)
                return [
                    "mask": FlutterStandardTypedData(bytes: comparison.mask),
                    "different": comparison.different,
                    "total": comparison.total,
                ] as [String: Any]
            }
        case AppConstants.lookupDefinitionMethod:
            guard let text = args["text"] as? String else {
                result(Self.badArguments("lookupDefinition 需要 text")); return
            }
            let range = CFRange(location: 0, length: (text as NSString).length)
            result(DCSCopyTextDefinition(nil, text as CFString, range)?.takeRetainedValue() as String?)
        case AppConstants.openGlossaryFileMethod:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.commaSeparatedText, .json]
            panel.allowsMultipleSelection = false
            panel.prompt = "导入术语"
            NSApp.activate(ignoringOtherApps: true)
            panel.begin { response in
                guard response == .OK, let url = panel.url else { result(nil); return }
                Task { @MainActor in
                    do {
                        let text = try await Task.detached { try String(contentsOf: url, encoding: .utf8) }.value
                        result(["name": url.lastPathComponent, "format": url.pathExtension.lowercased(), "text": text])
                    } catch let error as CocoaError where error.code == .fileReadInapplicableStringEncoding {
                        result(FlutterError(code: AppConstants.settingsFailedError,
                                            message: "术语文件须为 UTF-8 编码，请另存为 UTF-8 后再导入。", details: nil))
                    } catch {
                        result(FlutterError(code: AppConstants.settingsFailedError, message: error.localizedDescription, details: nil))
                    }
                }
            }
        case AppConstants.saveTextFileMethod:
            guard let text = args["text"] as? String, let suggestedName = args["suggestedName"] as? String else {
                result(Self.badArguments("saveTextFile 需要 text/suggestedName")); return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedName
            panel.allowedContentTypes = (suggestedName as NSString).pathExtension.lowercased() == "json"
                ? [.json] : [.commaSeparatedText]
            NSApp.activate(ignoringOtherApps: true)
            panel.begin { response in
                guard response == .OK, let url = panel.url else { result(nil); return }
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    result(url.path)
                } catch {
                    result(FlutterError(code: AppConstants.saveFailedError, message: error.localizedDescription, details: nil))
                }
            }
        case AppConstants.toggleSpeechMethod:
            guard let text = args["text"] as? String, let language = args["language"] as? String else {
                result(Self.badArguments("toggleSpeech 需要 text/language")); return
            }
            result(speech.toggle(text: text, language: language))
        case AppConstants.stopSpeechMethod:
            speech.stop()
            result(nil)
        case AppConstants.systemTranslateMethod:
            guard let requestId = args["requestId"] as? String,
                  let texts = args["texts"] as? [String],
                  let source = args["source"] as? String,
                  let target = args["target"] as? String,
                  let strategy = args["strategy"] as? String
            else {
                result(Self.badArguments("systemTranslate 需要 requestId/texts/source/target/strategy")); return
            }
            Task { @MainActor in
                do {
                    result(try await self.systemTranslation.translate(
                        requestId: requestId, texts: texts, source: source, target: target, strategy: strategy
                    ))
                } catch {
                    result(FlutterError(code: SystemTranslationService.errorCode(for: error), message: error.localizedDescription, details: nil))
                }
            }
        case AppConstants.cancelSystemTranslationMethod:
            guard let requestId = args["requestId"] as? String else {
                result(Self.badArguments("cancelSystemTranslation 需要 requestId")); return
            }
            Task { @MainActor in
                self.systemTranslation.cancel(requestId: requestId)
                result(nil)
            }
        case AppConstants.systemTranslationStatusMethod:
            guard let pairs = args["pairs"] as? [[String]], pairs.allSatisfy({ $0.count == 2 }) else {
                result(Self.badArguments("systemTranslationStatus 需要 [源语言, 目标语言] 列表")); return
            }
            Task { @MainActor in
                result(await SystemTranslationService.status(pairs: pairs))
            }
        case AppConstants.previewAppearanceMethod:
            NativeGlassFactory.preview = call.arguments as? [String: Any] ?? [:]
            NotificationCenter.default.post(name: AppConstants.appearanceChangedNotification, object: nil)
            result(nil)
        case AppConstants.systemStatusMethod:
            result([
                "accessibility": AccessibilitySelection.isTrusted(prompt: false),
                "loginNeedsApproval": SMAppService.mainApp.status == .requiresApproval,
                "screenAccess": ScreenCaptureService.isAuthorized(),
            ])
        case AppConstants.permissionWizardStatusMethod:
            result([
                "accessibility": AccessibilitySelection.isTrusted(prompt: false),
                "screenAccess": ScreenCaptureService.isAuthorized(),
                "finishedOrSkipped": UserDefaults.standard.bool(forKey: AppConstants.permissionWizardFinishedKey),
            ])
        case AppConstants.finishPermissionWizardMethod:
            UserDefaults.standard.set(true, forKey: AppConstants.permissionWizardFinishedKey)
            result(nil)
        case AppConstants.closePermissionWizardMethod:
            closePermissionWizard?()
            result(nil)
        case AppConstants.applicationSupportPathMethod:
            let dir = AppConstants.applicationSupportURL
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            result(dir.path)
        case AppConstants.mcpHelperPathMethod:
            let executable = Bundle.main.executableURL!.deletingLastPathComponent()
            result(executable.appendingPathComponent(AppConstants.mcpHelperName).path)
        case AppConstants.historyChangedMethod:
            NotificationCenter.default.post(name: AppConstants.historyChangedNotification, object: nil)
            result(nil)
        case AppConstants.publishLiveRegionMethod:
            let state = call.arguments as! [String: Any]
            Task { @MainActor in
                self.live.publish(state)
                result(nil)
            }
        case AppConstants.publishScreenshotTranslationMethod:
            let state = call.arguments as! [String: Any]
            Task { @MainActor in
                self.screenshot.publishTranslation(state)
                result(nil)
            }
        case AppConstants.requestScreenAccessMethod:
            Task { @MainActor in
                let granted = await ScreenCaptureService.requestAccess(promoteToRegularApp: true)
                if !granted {
                    ScreenCaptureService.openScreenRecordingSettings()
                }
                result([
                    "screenAccess": granted,
                    "accessibility": AccessibilitySelection.isTrusted(prompt: false),
                    "loginNeedsApproval": SMAppService.mainApp.status == .requiresApproval,
                ])
            }
        case AppConstants.openAccessibilityMethod:
            if AccessibilitySelection.isTrusted(prompt: false) {
                result(nil)
                return
            }
            _ = AccessibilitySelection.isTrusted(prompt: true)
            AccessibilitySelection.openSettings()
            result(nil)
        case AppConstants.openLoginItemsMethod:
            SMAppService.openSystemSettingsLoginItems()
            result(nil)
        case AppConstants.openTranslationLanguagesMethod:
            NSWorkspace.shared.open(AppConstants.translationLanguagesSettingsURL)
            result(nil)
        case AppConstants.systemShortcutsMethod:
            let entries = UserDefaults(suiteName: AppConstants.symbolicHotKeysDomain)?
                .dictionary(forKey: AppConstants.symbolicHotKeysKey) as? [String: [String: Any]] ?? [:]
            let enabled: [[String: Any]] = entries.values.compactMap { entry in
                guard entry["enabled"] as? Bool == true,
                      let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int],
                      parameters.count == 3,
                      let key = UInt16(exactly: parameters[1]).flatMap({ AppConstants.shortcutKeyNames[$0] }) else { return nil }
                let flags = NSEvent.ModifierFlags(rawValue: UInt(truncatingIfNeeded: parameters[2]))
                return ["key": key, "modifiers": ShortcutNames.names(flags: flags)]
            }
            result(enabled)
        case AppConstants.chooseExcludedAppMethod:
            let picker = NSOpenPanel()
            picker.allowedContentTypes = [.applicationBundle]
            picker.directoryURL = URL(fileURLWithPath: "/Applications")
            picker.allowsMultipleSelection = false
            picker.prompt = "排除此应用"
            picker.begin { response in
                guard response == .OK, let url = picker.url else { result(nil); return }
                guard let id = Bundle(url: url)?.bundleIdentifier else {
                    result(FlutterError(code: AppConstants.badAppError, message: "该应用没有 Bundle ID。", details: nil)); return
                }
                result(["id": id, "name": (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension])
            }
        case AppConstants.capabilitiesMethod:
            result(AppConstants.platformCapabilities)
        case AppConstants.publishFontStateMethod:
            NativeGlassFactory.fontState = call.arguments as? [String: Any] ?? [:]
            AppFonts.update(NativeGlassFactory.fontState)
            NotificationCenter.default.post(name: AppConstants.appearanceChangedNotification, object: nil)
            result(nil)
        case AppConstants.appReadyMethod:
            if let onReady {
                onReady()
            } else {
                pendingAppReady = true
            }
            result(nil)
        case AppConstants.perfMarkMethod:
            PerformanceLog.note(args["stage"] as! String, milliseconds: (args["ms"] as! NSNumber).doubleValue)
            result(nil)
        case AppConstants.appStartFailedMethod:
            result(nil)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NativeGlassFactory.applyAppearance(to: NSAlert())
            alert.alertStyle = .warning
            alert.messageText = "TranSnap 无法启动"
            alert.informativeText = "主程序初始化失败：\(args["message"] as! String)"
            alert.addButton(withTitle: "退出")
            AppFonts.prepare(alert).runModal()
            NSApp.terminate(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func applySettings(_ settings: [String: Any], credentials: [String: Any], result: @escaping FlutterResult) {
        var shortcuts: [GlobalHotKey: SelectionMonitor.HotKeyBinding] = [:]
        for purpose in GlobalHotKey.allCases {
            if let binding = ShortcutNames.binding(settings[purpose.preferenceKey]) {
                shortcuts[purpose] = binding
            }
        }
        guard let automatic = settings[AppConstants.automaticKey] as? Bool,
              shortcuts.count == GlobalHotKey.allCases.count,
              let excluded = settings[AppConstants.excludedAppsKey] as? [String: String],
              let login = settings[AppConstants.launchAtLoginKey] as? Bool,
              credentials.values.allSatisfy({ $0 is NSNull || $0 is [String: String] }) else {
            result(FlutterError(code: AppConstants.badSettingsError, message: "系统设置参数不完整。", details: nil)); return
        }
        let previousLogin = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
        var previousCredentials: [String: [String: String]] = [:]
        var written: [String] = []
        var loginChanged = false
        do {
            for id in credentials.keys { previousCredentials[id] = try Self.readCredentials(id: id) }
            for (id, value) in credentials {
                try Self.storeCredentials(id: id, value: value as? [String: String])
                written.append(id)
            }
            if login != previousLogin {
                if login { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                loginChanged = true
            }
            try selectionMonitor.configure(automatic: automatic, excludedApps: Set(excluded.keys), shortcuts: shortcuts)
            if let directory = settings[AppConstants.screenshotSaveDirectoryKey] as? String, !directory.isEmpty {
                UserDefaults.standard.set(directory, forKey: AppConstants.screenshotSaveDirectoryKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppConstants.screenshotSaveDirectoryKey)
            }
            UserDefaults.standard.set(settings, forKey: AppConstants.preferencesKey)
            NativeGlassFactory.preview = [:]
            NotificationCenter.default.post(name: AppConstants.appearanceChangedNotification, object: nil)
            screenshot.toolbarPreferencesChanged()
            DispatchQueue.main.async { StatusBarController.shared.updateAutomatic(automatic) }
            let controlEnabled = settings[AppConstants.mcpEnabledKey] as? Bool == true
                && settings[AppConstants.mcpControlEnabledKey] as? Bool == true
            if !controlEnabled { Task { @MainActor in MCPControl.shared.endSession() } }
            result(nil)
        } catch {
            let originalError = error
            do {
                for id in written.reversed() {
                    try Self.storeCredentials(id: id, value: previousCredentials[id])
                }
                if loginChanged {
                    if previousLogin { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                }
            } catch {
                result(FlutterError(code: AppConstants.rollbackFailedError, message: "设置未保存，无法恢复部分系统设置或凭据，请检查钥匙串与登录项。", details: nil)); return
            }
            result(FlutterError(code: AppConstants.settingsFailedError, message: originalError.localizedDescription, details: nil))
        }
    }

    static func readCredentials(id: String) throws -> [String: String]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.credentialsKeychainService,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let credentials = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else {
            throw NSError(domain: AppConstants.keychainErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "无法读取翻译服务凭据，请检查钥匙串访问权限。",
            ])
        }
        return credentials
    }

    static func storeCredentials(id: String, value: [String: String]?) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.credentialsKeychainService,
            kSecAttrAccount as String: id,
        ]
        var status: OSStatus
        if let value {
            let attributes = [kSecValueData as String: try JSONSerialization.data(withJSONObject: value)]
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            }
        } else {
            status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
        }
        guard status == errSecSuccess else {
            throw NSError(domain: AppConstants.keychainErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "无法保存或删除翻译服务凭据，请检查钥匙串访问权限。",
            ])
        }
    }

    private func composeInBackground(_ result: @escaping FlutterResult, _ work: @escaping () throws -> Any) {
        DispatchQueue.global(qos: .userInitiated).async {
            let value: Any
            do {
                value = try work()
            } catch {
                value = FlutterError(code: AppConstants.composeFailedError, message: error.localizedDescription, details: nil)
            }
            DispatchQueue.main.async { result(value) }
        }
    }

    func routeWindowRequest(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        handle(call) { [weak self] value in
            guard let self, (value as? NSObject) === FlutterMethodNotImplemented else {
                result(value)
                return
            }
            self.requestApplication(call.method, arguments: call.arguments, result: result)
        }
    }

    private static func badArguments(_ message: String) -> FlutterError {
        FlutterError(code: AppConstants.badArgsError, message: message, details: nil)
    }

    func requestApplication(_ method: String, arguments: Any? = nil, result: @escaping FlutterResult) {
        methods!.invokeMethod(method, arguments: arguments, result: result)
    }

    func overlayContains(_ point: NSPoint) -> Bool {
        overlay.contains(point)
    }

    func emitSelectionCaptured(text: String, gesture: String, readFailure: SelectionReadFailure? = nil, x: CGFloat, y: CGFloat, sourcePID: pid_t, sourceAppName: String?,
                               inputAnchor: InputAnchor? = nil, inputSelection: AXUIElement? = nil) {
        guard !retainsResult || SelectionGesture(rawValue: gesture)?.isExplicit == true else { return }
        retainsResult = false
        invalidateSelection()
        let sessionId = UUID().uuidString
        currentSessionId = sessionId
        sourceProcessIdentifier = sourcePID
        self.inputAnchor = inputAnchor
        self.inputSelection = inputSelection
        if let inputAnchor {
            MainActor.assumeIsolated { InputStatusBubble.shared.showProgress(anchor: inputAnchor) }
        }
        emit([
            "type": AppConstants.selectionCapturedEvent,
            "sessionId": sessionId,
            "text": text,
            "gesture": gesture,
            "readFailure": (readFailure?.rawValue as Any?) ?? NSNull(),
            "sourceAppName": (sourceAppName as Any?) ?? NSNull(),
            "x": x,
            "y": y,
        ])
    }

    func sourceApplicationChanged(to processIdentifier: pid_t?) {
        guard sourceProcessIdentifier != processIdentifier else { return }
        invalidateSelection()
    }

    func invalidateSelection(eventType: String = AppConstants.selectionInvalidatedEvent) {
        guard !retainsResult || eventType == AppConstants.escapePressedMethod else { return }
        MainActor.assumeIsolated { InputStatusBubble.shared.closeProgress() }
        selectionReadTask?.cancel()
        selectionReadTask = nil
        guard let sessionId = currentSessionId else { return }
        currentSessionId = nil
        sourceProcessIdentifier = nil
        retainsResult = false
        overlay.hide(sessionId: sessionId)
        emit([
            "type": eventType,
            "sessionId": sessionId,
        ])
    }

    func emit(_ payload: [String: Any]) {
        eventSink?(payload)
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
