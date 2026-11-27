import Foundation
import AppKit
import Carbon

enum CaptureTarget: String { case region, application, display }

enum CapturePhase: String {
    case idle, preparing, recording, pausing, paused, finalizing, videoReady, scrolling, imageReady, converting, failed
}

enum LiveRegionPhase: String { case idle, running, paused, ended, discarded }

enum LiveRegionAction: String { case start, pause, resume, end, discard, captureFailed }

enum RecordingExport: String {
    case mp4, gif, apng, webm

    var fileExtension: String { self == .apng ? "png" : rawValue }
}

enum ScrollCaptureMode: String {
    case manual, automatic
}

enum AppConstants {
    static let windowStartupChannel = "transnap/window_startup"
    static let windowReadyMethod = "windowReady"
    static let windowStartupTimeout: TimeInterval = 5

    static let captureChannel = "transnap/capture"
    static let captureEntrypoint = "captureMain"
    static let liveCaptureMinIntervalMs = 200
    static let previewLiveRegionMethod = "previewLiveRegion"
    static let cancelLivePreviewMethod = "cancelLivePreview"
    static let liveRegionCommandMethod = "liveRegionCommand"
    static let liveRegionOcrMethod = "liveRegionOcr"
    static let publishLiveRegionMethod = "publishLiveRegion"
    static let captureVideoPreview = "transnap/capture_video_preview"
    static let captureControlSize = NSSize(width: 400, height: 84)
    static let captureShadeOpacity: CGFloat = 0.6
    static let captureControlGap: CGFloat = 8
    static let recordingFlowArc: CGFloat = 0.22
    static let recordingFlowStroke: CGFloat = 2
    static let recordingFlowGlow: CGFloat = 8
    static let recordingFlowPeriod: CFTimeInterval = 2.4
    static let recordingFlowShadowOpacity: Float = 0.85
    static let scrollHintMaxWidth: CGFloat = 240
    static let scrollHintMinCenteredWidth: CGFloat = 88
    static let scrollHintPadding = NSSize(width: 12, height: 5)
    static let scrollHintRadius: CGFloat = 8
    static let scrollHintDurationMs = 1000
    static let scrollErrorHintDurationMs = 2000
    static let scrollPreviewWidth: CGFloat = 160
    static let scrollPreviewInset: CGFloat = 4
    static let scrollPreviewMaxImageHeight: CGFloat = 240
    static let scrollPreviewImageRadius: CGFloat = 4
    static let scrollPreviewTargetLine: CGFloat = 2
    static let resultWindowCanvasPadding: CGFloat = 24
    static let resultWindowBarHeight: CGFloat = 52
    static let recordingResultMinimumSize = NSSize(width: 600, height: 200)
    static let recordingFramesPerSecond: Int32 = 30
    static let webMEncoderScheme = "transnap-webm"
    static let captureResultWindowStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    static let captureControlWindowIdentifier = NSUserInterfaceItemIdentifier("captureControl")
    static let getCaptureStateMethod = "getCaptureState"
    static let captureStateChangedMethod = "captureStateChanged"
    static let prepareCaptureMethod = "prepareCapture"
    static let previewCaptureTargetMethod = "previewCaptureTarget"
    static let captureSourcesMethod = "captureSources"
    static let stopCaptureMethod = "stopCapture"
    static let setCapturePausedMethod = "setCapturePaused"
    static let cancelCaptureMethod = "cancelCapture"
    static let saveRecordingMethod = "saveRecording"
    static let copyRecordingMethod = "copyRecording"
    static let recordingClipboardDirectoryName = "TranSnap-Clipboard"
    static let previewRecordingMethod = "previewRecording"
    static let toggleRecordingPlaybackMethod = "toggleRecordingPlayback"
    static let seekRecordingMethod = "seekRecording"
    static let exportRecordingGIFMethod = "exportRecordingGIF"
    static let exportRecordingAPNGMethod = "exportRecordingAPNG"
    static let exportRecordingWebMMethod = "exportRecordingWebM"
    static let trimRecordingMethod = "trimRecording"
    static let cancelRecordingExportMethod = "cancelRecordingExport"
    static let captureFailedError = "capture_failed"
    static let saveDrawingPreferencesMethod = "saveDrawingPreferences"
    static let saveRecordingOptionsMethod = "saveRecordingOptions"
    static let screenshotDrawingKey = "screenshotDrawing"
    static let screenshotConfirmActionKey = "screenshotConfirmAction"
    static let historyChangedMethod = "historyChanged"
    static let historyChangedNotification = Notification.Name("transnap.historyChanged")

    static let setResizeCursorMethod = "setResizeCursor"
    static let setBrushCursorMethod = "setBrushCursor"
    static let resizeNorthWestSouthEast = "nwse"
    static let resizeNorthEastSouthWest = "nesw"
    static let screenshotTextInputMethod = "screenshotTextInput"
    static let screenshotToolbarHiddenKey = "screenshotToolbarHiddenIds"
    static let screenshotToolbarColumnsKey = "screenshotToolbarGrid"
    static let screenshotToolbarChildrenKey = "screenshotToolbarNested"
    static let screenshotToolbarFavoritesKey = "screenshotToolbarQuickTools"
    static let screenshotToolbarTabMethod = "screenshotToolbarTab"
    static let screenshotToolbarSlotKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22]
    static let screenshotToolbarChangedMethod = "screenshotToolbarChanged"
    static let screenshotToolbarSlotMethod = "screenshotToolbarSlot"
    static let appearanceSystem = "system"
    static let appearanceLight = "light"
    static let appearanceDark = "dark"
    static let appearanceChangedNotification = Notification.Name("TranSnapAppearanceChanged")
    static let settingsChannel = "transnap/settings"
    static let screenshotChannel = "transnap/screenshot"
    static let screenshotEntrypoint = "screenshotMain"
    static let screenshotEngineName = "screenshot"
    static let settingsEngineName = "settings"
    static let permissionWizardEngineName = "permission-wizard"
    static let historyEngineName = "history"
    static let permissionWizardFinishedKey = "permissionWizardFinished"
    static let screenshotSaveDirectoryKey = "screenshotSaveDirectory"
    static let gifFramesPerSecondKey = "gifFramesPerSecond"
    static let liveRecordingKey = "liveRecording"
    static let screenshotIncludesCursorKey = "screenshotIncludesCursor"
    static let languageDetectionCandidates = 3
    static let chineseScriptTransforms = [(script: "Hans", transform: "Hant-Hans"), (script: "Hant", transform: "Hans-Hant")]
    static let recordingClickEffectKey = "recordingClickEffect"
    static let recordingClickEffectEnabledKey = "recordingClickEffectEnabled"
    static let clickEffectLeftColor = NSColor(srgbRed: 0, green: 0x7A / 255.0, blue: 1, alpha: 1)
    static let clickEffectRightColor = NSColor(srgbRed: 1, green: 0x95 / 255.0, blue: 0, alpha: 1)
    static let clickEffectBaseRadius: CGFloat = 8
    static let clickEffectExpandRadius: CGFloat = 36
    static let clickEffectMinimalStartRadius: CGFloat = 11
    static let clickEffectMinimalEndRadius: CGFloat = 30
    static let clickEffectPressRadius: CGFloat = 13
    static let clickEffectStrokeWidth: CGFloat = 1.75
    static let clickEffectMinimalStrokeWidth: CGFloat = 2.2
    static let clickEffectDuration: CFTimeInterval = 0.56
    static let clickEffectMinimalDuration: CFTimeInterval = 0.42
    static let clickEffectTrailDuration: CFTimeInterval = 0.36
    static let clickEffectTrailMinDistance: CGFloat = 5
    static let scrollCaptureModeKey = "scrollCaptureMode"
    static let recordingDelayKey = "recordingDelay"
    static let recordingDelays = [0, 3, 5, 10]
    static let gifMaximumWidthKey = "gifMaximumWidth"
    static let escapeKeyCode: UInt16 = 53
    static let tabKeyCode: UInt16 = 48
    static let syntheticEventTag: Int64 = 0x5452_414E
    static let shortcutRequiredModifiers = UInt32(cmdKey | optionKey | controlKey)
    static let shortcutAllowedModifiers = shortcutRequiredModifiers | UInt32(shiftKey)
    static let textEditingKeyCodes: Set<UInt32> = [0, 6, 7, 8, 9]
    static let shortcutKeyNames: [UInt16: String] = [
        0: "KeyA", 1: "KeyS", 2: "KeyD", 3: "KeyF", 4: "KeyH", 5: "KeyG", 6: "KeyZ", 7: "KeyX",
        8: "KeyC", 9: "KeyV", 10: "IntlBackslash", 11: "KeyB", 12: "KeyQ", 13: "KeyW", 14: "KeyE", 15: "KeyR",
        16: "KeyY", 17: "KeyT", 18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4", 22: "Digit6", 23: "Digit5",
        24: "Equal", 25: "Digit9", 26: "Digit7", 27: "Minus", 28: "Digit8", 29: "Digit0", 30: "BracketRight", 31: "KeyO",
        32: "KeyU", 33: "BracketLeft", 34: "KeyI", 35: "KeyP", 36: "Enter", 37: "KeyL", 38: "KeyJ", 39: "Quote",
        40: "KeyK", 41: "Semicolon", 42: "Backslash", 43: "Comma", 44: "Slash", 45: "KeyN", 46: "KeyM", 47: "Period",
        48: "Tab", 49: "Space", 50: "Backquote", 51: "Backspace", 53: "Escape",
        64: "F17", 65: "NumpadDecimal", 67: "NumpadMultiply", 69: "NumpadAdd", 71: "NumLock",
        72: "AudioVolumeUp", 73: "AudioVolumeDown", 74: "AudioVolumeMute", 75: "NumpadDivide", 76: "NumpadEnter",
        78: "NumpadSubtract", 79: "F18", 80: "F19", 81: "NumpadEqual", 82: "Numpad0", 83: "Numpad1", 84: "Numpad2",
        85: "Numpad3", 86: "Numpad4", 87: "Numpad5", 88: "Numpad6", 89: "Numpad7", 90: "F20", 91: "Numpad8",
        92: "Numpad9", 93: "IntlYen", 94: "IntlRo", 95: "NumpadComma", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 102: "Lang2", 103: "F11", 104: "Lang1", 105: "F13", 106: "F16", 107: "F14",
        109: "F10", 110: "ContextMenu", 111: "F12", 113: "F15", 114: "Insert", 115: "Home", 116: "PageUp",
        117: "Delete", 118: "F4", 119: "End", 120: "F2", 121: "PageDown", 122: "F1", 123: "ArrowLeft",
        124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp",
    ]
    static let shortcutModifierNames: [(name: String, carbon: UInt32, flag: NSEvent.ModifierFlags, bit: Int)] = [
        ("control", UInt32(controlKey), .control, 1),
        ("alt", UInt32(optionKey), .option, 2),
        ("shift", UInt32(shiftKey), .shift, 4),
        ("meta", UInt32(cmdKey), .command, 8),
    ]
    static let returnKeyCode: UInt16 = 36
    static let keypadEnterKeyCode: UInt16 = 76
    static let confirmScreenshotMethod = "confirmScreenshot"
    static let arrowKeyDirections: [UInt16: (dx: Int, dy: Int)] = [123: (-1, 0), 124: (1, 0), 125: (0, 1), 126: (0, -1)]
    static let nudgeScreenshotCropMethod = "nudgeScreenshotCrop"
    static let appReadyMethod = "appReady"
    static let capabilitiesMethod = "capabilities"
    static let platformCapabilities = ["appleTranslation", "dictionary", "permissions", "screenshot", "recording", "mcp"]
    static let appStartFailedMethod = "appStartFailed"
    static let perfMarkMethod = "perfMark"
    static let appearanceChangedMethod = "appearanceChanged"
    static let previewAppearanceMethod = "previewAppearance"
    static let applicationSupportPathMethod = "applicationSupportPath"
    static let importStickerImageMethod = "importStickerImage"
    static let saveStickerMethod = "saveSticker"
    static let deleteStickerMethod = "deleteSticker"
    static let stickerDirectoryMethod = "stickerDirectory"
    static let openStickerSettingsMethod = "openStickerSettings"
    static let deleteScreenshotSelectionMethod = "deleteScreenshotSelection"
    static let deleteKeyCodes: Set<UInt16> = [51, 117]
    static let stickersKey = "stickers"
    static let stickerDirectoryKey = "stickerDirectory"
    static let stickerMaxPixels = 1024
    static let applySettingsMethod = "applySettings"
    static let automaticKey = "automatic"
    static let badAppError = "bad_app"
    static let badArgsError = "bad_args"
    static let badSettingsError = "bad_settings"
    static let chooseExcludedAppMethod = "chooseExcludedApp"
    static let systemShortcutsMethod = "systemShortcuts"
    static let symbolicHotKeysDomain = "com.apple.symbolichotkeys"
    static let symbolicHotKeysKey = "AppleSymbolicHotKeys"
    static let chooseScreenshotDirectoryMethod = "chooseScreenshotDirectory"
    static let closePermissionWizardMethod = "closePermissionWizard"
    static let closeScreenshotMethod = "closeScreenshot"
    static let copyScreenshotMethod = "copyScreenshot"
    static let copyTextMethod = "copyText"
    static let copyFailedError = "copy_failed"
    static let credentialIdsMethod = "credentialIds"
    static let dragOverlayMethod = "dragOverlay"
    static let escapePressedMethod = "escapePressed"
    static let excludedAppsKey = "excludedApps"
    static let finishPermissionWizardMethod = "finishPermissionWizard"
    static let getAppearanceMethod = "getAppearance"
    static let getScreenshotMethod = "getScreenshot"
    static let glassAppearanceKey = "glassAppearance"
    static let glassOpacityKey = "glassOpacity"
    static let accentColorKey = "accentColor"
    static let accentForegroundKey = "accentForeground"
    static let accentSystem = "system"
    static let accentSwatches: [String: (light: Int, dark: Int)] = [
        "blue": (0xFF2F_6FE4, 0xFF4C_8DFF),
        "purple": (0xFF6E_56CF, 0xFF9B_8AFB),
        "pink": (0xFFC9_356E, 0xFFF0_6A97),
        "orange": (0xFFC2_560F, 0xFFFF_8F4D),
        "green": (0xFF0B_7F72, 0xFF2E_C4AE),
        "graphite": (0xFF57_606C, 0xFFA3_AAB4),
    ]
    static let accentCustomDarkLift = 0.35
    static let accentLightKey = "accentLight"
    static let accentDarkKey = "accentDark"
    static let fontSetKey = "fontSet"
    static let fontSetFallback = "neutral"
    static let fontsDirectoryKey = "fontsDirectory"
    static let fontStateKey = "fontState"
    static let publishFontStateMethod = "publishFontState"
    static let hideOverlayMethod = "hideOverlay"
    static let hideOverlayTooltipMethod = "hideOverlayTooltip"
    static let historyEntrypoint = "historyMain"
    static let keychainFailedError = "keychain_failed"
    static let credentialsKeychainService = "com.coolyang.transnap.credentials"
    static let launchAtLoginKey = "launchAtLogin"
    static let loadSettingsMethod = "loadSettings"
    static let ocrEmptyError = "ocr_empty"
    static let ocrFailedError = "ocr_failed"
    static let openAccessibilityMethod = "openAccessibility"
    static let openLoginItemsMethod = "openLoginItems"
    static let openTranslationLanguagesMethod = "openTranslationLanguages"
    static let translationLanguagesSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!
    static let openLinkMethod = "openLink"
    static let openableLinkSchemes: Set<String> = ["http", "https"]
    static let permissionStatusChangedMethod = "permissionStatusChanged"
    static let permissionWizardEntrypoint = "permissionWizardMain"
    static let permissionWizardStatusMethod = "permissionWizardStatus"
    static let pinScreenshotMethod = "pinScreenshot"
    static let preferencesKey = "preferences"
    static let readCredentialsMethod = "readCredentials"
    static let readSelectionForTranslationMethod = "readSelectionForTranslation"
    static let recognizeBlocksMethod = "recognizeBlocks"
    static let recognizeTextMethod = "recognizeText"
    static let recordShortcutMethod = "recordShortcut"
    static let redoPressedMethod = "redoPressed"
    static let refreshSettingsMethod = "refreshSettings"
    static let requestScreenAccessMethod = "requestScreenAccess"
    static let retainOverlayMethod = "retainOverlay"
    static let setWindowTitleMethod = "setWindowTitle"
    static let startWindowDragMethod = "startWindowDrag"
    static let replaceSelectionMethod = "replaceSelection"
    static let showInputFailureMethod = "showInputFailure"
    static let inputFailureDurationMs = 2000
    static let inputFailureGap: CGFloat = 8
    static let inputFailureIconSize: CGFloat = 14
    static let inputFailureIconSpacing: CGFloat = 6
    static let axSelectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    static let axBoundsForTextMarkerRangeAttribute = "AXBoundsForTextMarkerRange"
    static let inputProgressDelayMs = 300
    static let inputProgressText = "翻译中…"
    static let inputProgressFontSize: CGFloat = 13
    static let inputProgressHeight: CGFloat = 24
    static let inputProgressRadius: CGFloat = 12
    static let inputProgressPaddingX: CGFloat = 10
    static let inputProgressSpinnerSize: CGFloat = 12
    static let inputProgressSpacing: CGFloat = 6
    static let axTextInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    static let axMessagingTimeout: Float = 1
    static let inputTargetSearchMaxNodes = 2000
    static let inputTargetSearchMaxDepth = 40
    static let inputTargetSearchTimeout = Duration.seconds(1)
    static let inputTargetFocusDelay = Duration.milliseconds(80)
    static let pasteRestoreDelay = Duration.milliseconds(500)
    static let revealFileMethod = "revealFile"
    static let rollbackFailedError = "rollback_failed"
    static let saveScreenshotMethod = "saveScreenshot"
    static let saveFailedError = "save_failed"
    static let screenshotChangedMethod = "screenshotChanged"
    static let screenshotShortcutKey = "screenshotShortcut"
    static let selectionCapturedEvent = "selectionCaptured"
    static let selectionInvalidatedEvent = "selectionInvalidated"
    static let setOverlaySizeMethod = "setOverlaySize"
    static let settingsEntrypoint = "settingsMain"
    static let settingsFailedError = "settings_failed"
    static let shortcutKey = "shortcut"
    static let inputShortcutKey = "inputShortcut"
    static let shortcutInvalidError = "shortcut_invalid"
    static let showOverlayMethod = "showOverlay"
    static let showOverlayTooltipMethod = "showOverlayTooltip"
    static let staleCaptureError = "stale_capture"
    static let systemStatusMethod = "systemStatus"
    static let recordScreenshotHistoryMethod = "recordScreenshotHistory"
    static let screenshotHistoryRecordingMethod = "screenshotHistoryRecording"
    static let stitchScreenshotsMethod = "stitchScreenshots"
    static let splitScreenshotMethod = "splitScreenshot"
    static let compareScreenshotsMethod = "compareScreenshots"
    static let composeFailedError = "compose_failed"
    static let openFileMethod = "openFile"
    static let copyImageFileMethod = "copyImageFile"
    static let languageCandidatesMethod = "languageCandidates"
    static let shouldCopySelectionMethod = "shouldCopySelection"
    static let acceptsCopiedSelectionMethod = "acceptsCopiedSelection"
    static let lookupDefinitionMethod = "lookupDefinition"
    static let vocabularyListMethod = "vocabularyList"
    static let saveTextFileMethod = "saveTextFile"
    static let openGlossaryFileMethod = "openGlossaryFile"
    static let cancelScreenshotTranslationMethod = "cancelScreenshotTranslation"
    static let toggleSpeechMethod = "toggleSpeech"
    static let stopSpeechMethod = "stopSpeech"
    static let systemTranslateMethod = "systemTranslate"
    static let cancelSystemTranslationMethod = "cancelSystemTranslation"
    static let systemTranslationStatusMethod = "systemTranslationStatus"
    static let systemTranslationInstalled = "installed"
    static let systemTranslationSupported = "supported"
    static let systemTranslationUnsupported = "unsupported"
    static let systemTranslationHighFidelity = "highFidelity"
    static let toggleAutomaticMethod = "toggleAutomatic"
    static let translateScreenshotBlocksMethod = "translateScreenshotBlocks"
    static let prewarmTranslationMethod = "prewarmTranslation"
    static let publishScreenshotTranslationMethod = "publishScreenshotTranslation"
    static let translateFailedError = "translate_failed"
    static let translationNotInstalledError = "translation_not_installed"
    static let translationUnsupportedError = "translation_unsupported"
    static let appearanceChannel = "transnap/appearance"
    static let platformChannel = "transnap/platform"
    static let platformEventsChannel = "transnap/platform/events"
    static let nativeGlassViewType = "transnap/native-glass"
    static let undoPressedMethod = "undoPressed"

    static let applicationSupportFolderName = "TranSnap"
    static let errorDomain = "TranSnap"
    static let keychainErrorDomain = "TranSnap.Keychain"
    static let screenRecordingRequiredMessage = "需要屏幕录制权限，请在系统设置中允许 TranSnap 后重试。"
    static let longScreenshotResultMinimumSize = NSSize(width: 600, height: 240)
    static let settingsWindowAutosaveName: NSWindow.FrameAutosaveName = "TranSnapSettingsWindow"
    static let historyWindowAutosaveName: NSWindow.FrameAutosaveName = "TranSnapHistoryWindow"
    static let permissionWizardMinSize = NSSize(width: 440, height: 340)
    static let historyWindowMinSize = NSSize(width: 480, height: 480)
    static let overlayTriggerCornerRadius: CGFloat = 10
    static let overlayCardCornerRadius: CGFloat = 16
    static let overlayTriggerMaxHeight: CGFloat = 44
    static let pinCloseButtonSize: CGFloat = 24
    static let pinCloseButtonInset: CGFloat = 6
    static let pinCloseButtonAlpha: CGFloat = 0.6
    static let pinCloseButtonHoverAlpha: CGFloat = 0.78
    static let pinCloseButtonPressedScale: CGFloat = 0.92
    static let pinCloseButtonEdgeWidth: CGFloat = 0.5
    static let pinCloseButtonEdgeAlpha: CGFloat = 0.22
    static let pinCloseGlyphSize: CGFloat = 6
    static let pinCloseGlyphStroke: CGFloat = 1.6
    static var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationSupportFolderName, isDirectory: true)
    }
    static var fontsURL: URL {
        applicationSupportURL.appendingPathComponent("Fonts", isDirectory: true)
    }
    static var stickersURL: URL {
        applicationSupportURL.appendingPathComponent("Stickers", isDirectory: true)
    }
    static let mcpHelperName = "transnap-mcp"
    static let mcpServerName = "transnap"
    static let mcpSocketFileName = "mcp.sock"
    static let mcpImageMaxEdge = 1568
    static let mcpTokenPatch = 28
    static let mcpNotRunningMessage = "TranSnap is not running."
    static let mcpHelperIdentifier = "com.coolyang.transnap.mcp"
    static let mcpUntrustedPeerMessage = "Connection refused: the caller is not the TranSnap MCP helper."
    static let mcpDisabledMessage = "MCP is disabled in TranSnap settings."
    static let mcpPermissionMessage = "TranSnap lacks Screen Recording permission. Allow it in System Settings > Privacy & Security > Screen Recording, then retry."
    static let mcpVersionMismatchMessage = "TranSnap and its MCP helper are different versions. Restart TranSnap, then retry."
    static let mcpNoTextMessage = "No text recognized."
    static func mcpRectangleOutOfRangeMessage(reference: String, display: Int, width: Int, height: Int) -> String {
        "Rectangle exceeds the \(reference) image of display \(display) (\(width)×\(height))."
    }
    static func mcpWindowNotFoundMessage(windowID: UInt32) -> String {
        "window_id \(windowID) not found; call list_windows again."
    }
    static func mcpCaptureFailedMessage(_ reason: String) -> String { "Capture failed: \(reason)" }
    static func mcpDisplayOutOfRangeMessage(index: Int, count: Int) -> String {
        "display_index \(index) is out of range; \(count) displays available."
    }
    static func mcpUnknownArgumentMessage(_ name: String) -> String { "Unknown argument: \(name)" }
    static func mcpMissingArgumentMessage(_ key: String) -> String { "Missing required argument: \(key)" }
    static let mcpInternalErrorMessage = "Internal error: response is not JSON-serializable."
    static func mcpConnectFailedMessage(_ reason: String) -> String { "Cannot connect to TranSnap: \(reason)" }
    static let mcpConnectionClosedMessage = "TranSnap closed the connection without a result."
    static func mcpCommunicationFailedMessage(_ reason: String) -> String { "Communication with TranSnap failed: \(reason)" }
    static let mcpParseErrorMessage = "Parse error"
    static func mcpMethodNotFoundMessage(_ method: String) -> String { "Method not found: \(method)" }
    static func mcpUnknownToolMessage(_ name: String) -> String { "Unknown tool: \(name)" }
    static let mcpPixelReadFailedMessage = "Unable to read screenshot pixels."
    static let mcpScaleFailedMessage = "Unable to scale screenshot."
    static let mcpEnabledKey = "mcpEnabled"
    static let mcpControlEnabledKey = "mcpControlEnabled"
    static let mcpControlDisabledMessage = "Computer control is disabled in TranSnap settings. click, type_text, press_key, scroll, and drag are not allowed."
    static let mcpAccessibilityPermissionMessage = "TranSnap lacks Accessibility permission. Allow it in System Settings > Privacy & Security > Accessibility, then retry."
    static func mcpBlockedAppMessage(_ name: String) -> String { "\(name) is blocked from computer control." }
    static func mcpAppNotRunningMessage(_ name: String) -> String { "App \(name) is not running; check list_windows." }
    static func mcpAmbiguousAppMessage(_ name: String, candidates: [String]) -> String {
        "App \(name) is ambiguous; pass one bundle id: \(candidates.joined(separator: ", "))"
    }
    static func mcpWindowNotInTreeMessage(windowID: UInt32) -> String {
        "window_id \(windowID) has no accessibility information; use capture_window and pixel coordinates."
    }
    static func mcpInvalidRefMessage(_ ref: String) -> String { "Invalid ref \(ref); refs look like @s3:e12." }
    static func mcpStaleRefMessage(_ ref: String) -> String { "Ref \(ref) is stale; call snapshot or find again." }
    static let mcpTargetConflictMessage = "Pass only one of app, window_id or root."
    static let mcpPointTargetMessage = "Pass ref, or display_index with x and y, not both."
    static let mcpClickCountMessage = "count must be 1 or 2"
    static let mcpDragTargetMessage = "drag needs display_index, x, y, to_x and to_y within the capture_screen image."
    static let mcpSecureFieldMessage = "Typing into password fields is refused."
    static func mcpInvalidKeysMessage(_ keys: String) -> String {
        "Cannot parse keys \(keys); use forms like cmd+s, return, shift+tab, f5."
    }
    static func mcpForbiddenKeysMessage(_ keys: String) -> String { "\(keys) is refused: quit, log-out and force-quit shortcuts are blocked." }
    static func mcpDeniedMessage(_ app: String) -> String { "The user did not allow control of \(app) in this session." }
    static let mcpControlBusyMessage = "Another control action is still running; wait for its result."
    static let mcpUserBusyMessage = "The user is using the computer; retry shortly."
    static let mcpInterruptedMessage = "Interrupted by the user's input; observe again before retrying."
    static let mcpNoWindowAtPointMessage = "No app window at that point."
    static let mcpScreenshotUnavailableMessage = "Screenshot unavailable: grant Screen Recording permission."
    static let overlayResizeAnimationDuration: TimeInterval = 0.24
    static let overlayFadeInDuration: TimeInterval = 0.16
    static let charRevealDuration: TimeInterval = 0.18
    static let charRevealStagger: TimeInterval = 0.012
    static let charRevealMaxSpread: TimeInterval = 0.60
    static let charRevealBlur: CGFloat = 3
    static let liveOverlayMinFontSize: CGFloat = 10
    static let liveOverlayPadding = NSSize(width: 4, height: 2)
    static let liveOverlayCornerRadius: CGFloat = 4
    static let controlSessionLimit: TimeInterval = 30 * 60
    static let controlIdleLimit: TimeInterval = 5 * 60
    static let controlUserIdleInterval: TimeInterval = 1
    static let controlUserWaitLimit: TimeInterval = 10
    static let controlApprovalTimeout: TimeInterval = 30
    static let controlActivationDelay: TimeInterval = 0.15
    static let controlSettleDelay: TimeInterval = 0.3
    static let controlBorderWidth: CGFloat = 3
    static let controlBorderColor = NSColor(srgbRed: 1, green: 0x95 / 255.0, blue: 0, alpha: 1)
    static let controlSymbol = "cursorarrow.rays"
    static let controlPanelWidth: CGFloat = 360
    static let controlPanelPadding: CGFloat = 16
    static let controlPanelTopInset: CGFloat = 48
    static let controlPanelCornerRadius: CGFloat = 14
    static let controlLogFileName = "control.log"
    static let mcpFindFilterMessage = "Pass role, text or both."
    static let controlBlockedBundleIDs: Set<String> = [
        "com.apple.systempreferences", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.1password.1password", "com.bitwarden.desktop",
    ]
    static let mcpSnapshotBudget: TimeInterval = 2
    static let mcpSnapshotElementLimit = 400
    static let mcpFindLimit = 50
    static let mcpSnapshotDefaultDepth = 10
    static let mcpSnapshotMaxDepth = 50
    static let mcpRefSnapshotLimit = 8
    static let mcpElementValueLimit = 120
    static let mcpHelperPathMethod = "mcpHelperPath"
    static let mcpCaptureSymbol = "camera.viewfinder"
    static let mcpCaptureIndicatorMinimum = Duration.milliseconds(1000)
}

enum SelectionReadFailure: String {
    case secureField
}

enum SelectionGesture: String {
    case drag
    case doubleClick
    case tripleClick
    case selectAll
    case keyboard
    case hotkey
    case inputHotkey

    var isExplicit: Bool { self == .hotkey || self == .inputHotkey }

    static func keyboardGesture(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> SelectionGesture? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        if keyCode == 0, flags == .command { return .selectAll }
        let navigationKeys: Set<UInt16> = [115, 116, 119, 121, 123, 124, 125, 126]
        if flags.contains(.shift), navigationKeys.contains(keyCode) { return .keyboard }
        return nil
    }
}

enum GlobalHotKey: CaseIterable {
    case translate
    case input
    case screenshot

    var preferenceKey: String {
        switch self {
        case .translate: AppConstants.shortcutKey
        case .input: AppConstants.inputShortcutKey
        case .screenshot: AppConstants.screenshotShortcutKey
        }
    }

    var title: String {
        switch self {
        case .translate: "全局翻译快捷键"
        case .input: "输入翻译快捷键"
        case .screenshot: "区域截图快捷键"
        }
    }

    func formattedShortcut(
        in preferences: [String: Any]
    ) -> (titleSuffix: String, keyEquivalent: String, modifiers: NSEvent.ModifierFlags)? {
        guard let shortcut = preferences[preferenceKey] as? [String: Any],
              let names = shortcut["modifiers"] as? [String],
              let rawLabel = (shortcut["label"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawLabel.isEmpty else {
            return nil
        }
        let flags = ShortcutNames.flags(names)
        guard !flags.isEmpty else { return nil }
        let symbols = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }
            .map(\.1)
            .joined()
        if rawLabel.unicodeScalars.count == 1,
           let scalar = rawLabel.unicodeScalars.first,
           scalar.isASCII,
           scalar.value > 32 && scalar.value < 127 {
            return ("", rawLabel.lowercased(), flags)
        }
        return (" (\(symbols)\(rawLabel))", "", flags)
    }
}

enum ShortcutNames {
    static let keyCodes = Dictionary(uniqueKeysWithValues: AppConstants.shortcutKeyNames.map { ($0.value, $0.key) })

    static func names(carbon: UInt32) -> [String] {
        AppConstants.shortcutModifierNames.filter { carbon & $0.carbon != 0 }.map(\.name)
    }

    static func names(flags: NSEvent.ModifierFlags) -> [String] {
        AppConstants.shortcutModifierNames.filter { flags.contains($0.flag) }.map(\.name)
    }

    static func names(bits: Int) -> [String] {
        AppConstants.shortcutModifierNames.filter { bits & $0.bit != 0 }.map(\.name)
    }

    static func flags(_ names: [String]) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(AppConstants.shortcutModifierNames.filter { names.contains($0.name) }.map(\.flag))
    }
}

enum MCPTool: String, CaseIterable {
    case listDisplays = "list_displays"
    case listWindows = "list_windows"
    case captureScreen = "capture_screen"
    case captureRect = "capture_rect"
    case captureWindow = "capture_window"
    case snapshot
    case find
    case click
    case typeText = "type_text"
    case pressKey = "press_key"
    case scroll
    case drag

    var isControl: Bool {
        switch self {
        case .listDisplays, .listWindows, .captureScreen, .captureRect, .captureWindow, .snapshot, .find:
            false
        case .click, .typeText, .pressKey, .scroll, .drag:
            true
        }
    }
}

enum MCPMouseButton: String, Codable, CaseIterable {
    case left, right
}

enum MCPScrollDirection: String, Codable, CaseIterable {
    case up, down, left, right
}

enum MCPOutput: String, Codable, CaseIterable {
    case image, text, both
}

enum MCPDetail: String, Codable, CaseIterable {
    case low, standard

    var tokenBudget: Int {
        switch self {
        case .low: 512
        case .standard: 1568
        }
    }
}

enum RecordingClickEffect: String, CaseIterable {
    case optical
    case liquid
    case spotlight
    case prism
    case minimal
    case system
}
