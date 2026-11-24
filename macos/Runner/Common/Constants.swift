import Foundation
import AppKit
import Carbon

/// 采集目标协议；rawValue与Dart CaptureTarget.name逐项对应。
enum CaptureTarget: String { case region, application, display }

/// 连续采集的公开阶段；原始值与Dart CapturePhase一致。
enum CapturePhase: String {
    case idle, preparing, recording, pausing, paused, finalizing, videoReady, scrolling, imageReady, converting, failed
}

/// 实时翻译会话阶段；rawValue 与 Dart LiveRegionPhase.name 逐项对应（#127）。
enum LiveRegionPhase: String { case idle, running, paused, ended, discarded }

/// 发给主引擎的实时翻译命令；rawValue 与 Dart LiveRegionAction.name 逐项对应（#127）。
enum LiveRegionAction: String { case start, pause, resume, end, discard, captureFailed }

/// 录制结果的导出类型；rawValue 是 converting 阶段 exporting 详情值与保存分类，与Dart RecordingExport.name逐项对应（#110）。
enum RecordingExport: String {
    case mp4, gif, apng, webm

    /// 无参数；返回保存文件的扩展名，APNG 的标准扩展名为 png。
    var fileExtension: String { self == .apng ? "png" : rawValue }
}

/// 长截图滚动方式偏好值；rawValue 与 Dart ScrollCaptureMode.name 逐项对应，缺省为手动（#112）。
enum ScrollCaptureMode: String {
    case manual, automatic
}

/// 原生侧通道名、方法名、错误码、偏好键与平台视图类型等协议值；两端都定义的值字面量一致，改名须两端同步；只有一端使用的值不在另一端定义。
/// 只定义 Swift 端代码（含测试）实际使用的值。
enum AppConstants {
    /// 独立引擎入口就绪确认；五秒预算只覆盖入口执行，不等待首帧或业务加载。
    static let windowStartupChannel = "translateapp/window_startup"
    static let windowReadyMethod = "windowReady"
    /// #120 的有限等待策略；实测条件与样本见工单，若新增入口或启动负载变化需重新测量。
    static let windowStartupTimeout: TimeInterval = 5

    /// 连续采集独立通道与多引擎入口，和Dart常量一致。
    static let captureChannel = "translateapp/capture"
    static let captureEntrypoint = "captureMain"
    /// 实时翻译 SCStream 的已批准供帧间隔，单位毫秒；只节流系统输出，不保证固定帧率。
    static let liveCaptureMinIntervalMs = 200
    static let previewLiveRegionMethod = "previewLiveRegion"
    static let cancelLivePreviewMethod = "cancelLivePreview"
    static let liveRegionCommandMethod = "liveRegionCommand"
    static let liveRegionOcrMethod = "liveRegionOcr"
    static let publishLiveRegionMethod = "publishLiveRegion"
    static let captureVideoPreview = "translateapp/capture_video_preview"
    /// Spec #67中的采集工具尺寸，单位为屏幕逻辑点。
    static let captureControlSize = NSSize(width: 320, height: 84)
    static let captureShadeOpacity: CGFloat = 0.6
    static let captureControlGap: CGFloat = 8
    /// 区域录制边框流光规范数值（#67 第 9 条、#142）：光段占周长 22%、线宽 2pt、外发光 8pt（shadowRadius 4）、周期 2.4s。
    static let recordingFlowArc: CGFloat = 0.22
    static let recordingFlowStroke: CGFloat = 2
    static let recordingFlowGlow: CGFloat = 8
    static let recordingFlowPeriod: CFTimeInterval = 2.4
    static let recordingFlowShadowOpacity: Float = 0.85
    /// Issue #87长截图过程提示：沿用#67文字反馈的最大宽、内边距与圆角，距选区8pt，常规提示1000ms、错误提示2000ms，极窄居中最小宽88pt（#144 U-32）。
    static let scrollHintMaxWidth: CGFloat = 240
    static let scrollHintMinCenteredWidth: CGFloat = 88
    static let scrollHintPadding = NSSize(width: 12, height: 5)
    static let scrollHintRadius: CGFloat = 8
    static let scrollHintDurationMs = 1000
    static let scrollErrorHintDurationMs = 2000
    /// Issue #87实时缩略图：外框宽160pt含4pt内边距，图像最大高240pt、圆角4pt，回退目标框2pt。
    static let scrollPreviewWidth: CGFloat = 160
    static let scrollPreviewInset: CGFloat = 4
    static let scrollPreviewMaxImageHeight: CGFloat = 240
    static let scrollPreviewImageRadius: CGFloat = 4
    static let scrollPreviewTargetLine: CGFloat = 2
    /// 录制结果底部工具栏长度与厚度（8 个 32pt 按钮、7 个 12pt 间距和左右各 8pt 内边距：8×32+7×12+16=356；上下各 8pt 内边距：32+16=48）；与 Dart 一致。
    static let captureResultToolbarLength: CGFloat = 356
    static let captureResultToolbarThickness: CGFloat = 48
    /// 录制最高帧率：ScreenCaptureKit 最小帧间隔为其倒数；WebM 编码以此作为码率分配的帧率提示（#110）。
    static let recordingFramesPerSecond: Int32 = 30
    /// WebM 编码页面的自定义 URL 协议名；编码页面与待编码帧都经此协议交给不挂窗口的 WKWebView（#110）。
    static let webMEncoderScheme = "translateapp-webm"
    /// 录制结果使用系统窗口控制；标题栏尺寸由AppKit按此样式实际计算。
    static let captureResultWindowStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    /// 采集控制窗口标记：控制气泡、选区外阴影、长截图预览、截图面板与跨屏目标预览；录屏只排除带此标记的本应用窗口（#68）。
    static let captureControlWindowIdentifier = NSUserInterfaceItemIdentifier("captureControl")
    static let getCaptureStateMethod = "getCaptureState"
    static let captureStateChangedMethod = "captureStateChanged"
    static let prepareCaptureMethod = "prepareCapture"
    /// 截图准备阶段的显示器与应用窗口预览协议。
    static let previewCaptureTargetMethod = "previewCaptureTarget"
    static let captureSourcesMethod = "captureSources"
    static let stopCaptureMethod = "stopCapture"
    static let setCapturePausedMethod = "setCapturePaused"
    static let cancelCaptureMethod = "cancelCapture"
    static let saveRecordingMethod = "saveRecording"
    /// copyRecording 协议值；拷贝完整视频或裁剪片段到剪贴板临时目录并写入文件引用（#142），与 Dart 常量同步。
    static let copyRecordingMethod = "copyRecording"
    /// 录屏复制到剪贴板使用的临时子目录名；下次启动应用时清空（#68 第 10 条、#142）。
    static let recordingClipboardDirectoryName = "TranslateApp-Clipboard"
    static let previewRecordingMethod = "previewRecording"
    static let exportRecordingGIFMethod = "exportRecordingGIF"
    /// exportRecordingAPNG 协议值；按 GIF 设置导出 APNG（#110），与Dart常量同步。
    static let exportRecordingAPNGMethod = "exportRecordingAPNG"
    /// exportRecordingWebM 协议值；按原分辨率与原帧时间导出 VP8 WebM（#110），与Dart常量同步。
    static let exportRecordingWebMMethod = "exportRecordingWebM"
    /// trimRecording 协议值；结果页播放器进入系统裁剪模式，确认后记录区间（#110），与Dart常量同步。
    static let trimRecordingMethod = "trimRecording"
    /// cancelRecordingExport 协议值；取消正在进行的 MP4/GIF/APNG/WebM 转换，与Dart常量同步。
    static let cancelRecordingExportMethod = "cancelRecordingExport"
    static let captureFailedError = "capture_failed"
    static let saveDrawingPreferencesMethod = "saveDrawingPreferences"
    /// saveRecordingOptions 协议值；截图引擎经主引擎设置队列保存录制延时与点击特效（#129、#143），与Dart常量同步。
    static let saveRecordingOptionsMethod = "saveRecordingOptions"
    static let screenshotDrawingKey = "screenshotDrawing"
    /// screenshotConfirmAction 偏好键；确认截图时的动作，随截图快照与工具栏变更通知交给截图引擎（#111），与Dart常量同步。
    static let screenshotConfirmActionKey = "screenshotConfirmAction"
    static let historyChangedMethod = "historyChanged"
    static let historyChangedNotification = Notification.Name("translateapp.historyChanged")

    /// 截图对角光标的受控协议轴，与Dart ResizeCursorAxes一致。
    static let setResizeCursorMethod = "setResizeCursor"
    static let setBrushCursorMethod = "setBrushCursor"
    static let resizeNorthWestSouthEast = "nwse"
    static let resizeNorthEastSouthWest = "nesw"
    static let screenshotTextInputMethod = "screenshotTextInput"
    static let screenshotToolbarHiddenKey = "screenshotToolbarHidden"
    /// 截图工具栏网格：[{modifiers, slots}]，modifiers 为 Control=1/Option=2/Command=8 位掩码，slots 为 6 个功能 ID（空格为空字符串），与 Dart 一致（#141）。
    static let screenshotToolbarColumnsKey = "screenshotToolbarColumns"
    static let screenshotToolbarChildrenKey = "screenshotToolbarChildren"
    /// 网格格位对应的数字行物理键码（kVK_ANSI_1…6），下标 0 为第 1 格（#141）。
    static let screenshotToolbarSlotKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22]
    /// 截图局部工具配置独立广播，不替换截图编辑草稿。
    static let screenshotToolbarChangedMethod = "screenshotToolbarChanged"
    /// 截图面板收到格位快捷键时交给截图引擎：{id, modifiers, digit}，digit 为 1–6（#141）。
    static let screenshotToolbarSlotMethod = "screenshotToolbarSlot"
    /// 跨引擎外观模式与通知名称；与Dart AppearanceModes一致。
    static let appearanceSystem = "system"
    static let appearanceLight = "light"
    static let appearanceDark = "dark"
    static let appearanceChangedNotification = Notification.Name("TranslateAppAppearanceChanged")
    static let settingsChannel = "translateapp/settings"
    static let screenshotChannel = "translateapp/screenshot"
    static let screenshotEntrypoint = "screenshotMain"
    /// 附属窗口的 Flutter 引擎名，经 WindowEngine 创建时使用（#120、#124）。
    static let screenshotEngineName = "screenshot"
    static let settingsEngineName = "settings"
    static let permissionWizardEngineName = "permission-wizard"
    static let historyEngineName = "history"
    static let permissionWizardFinishedKey = "permissionWizardFinished"
    static let screenshotSaveDirectoryKey = "screenshotSaveDirectory"
    /// GIF导出偏好；最大宽度缺省表示原始宽度。
    static let gifFramesPerSecondKey = "gifFramesPerSecond"
    /// liveRecording 协议值；实时翻译开始时读取，决定是否同步录制。与Dart常量同步。
    static let liveRecordingKey = "liveRecording"
    /// screenshotIncludesCursor 协议值；区域截图冻结帧是否包含鼠标指针，Dart 设置写入、冻结时读取（#105）。与Dart常量同步。
    static let screenshotIncludesCursorKey = "screenshotIncludesCursor"
    /// 全局与输入翻译的主要/次要语言偏好键；语言识别据此在低置信度时取用户语言，与 Dart PreferenceKeys 同步。
    static let userLanguageKeys = ["primaryLanguage", "secondaryLanguage", "inputPrimaryLanguage", "inputSecondaryLanguage"]
    /// 语言识别直接采用首位结果的最低置信度；低于它时只在前若干名中取用户语言。
    static let languageDetectionConfidence = 0.5
    static let languageDetectionCandidates = 3
    /// 语言识别先验权重（#1）：可识别语言基准 1，热门语言 3，用户语言 30；短文本优先判为用户语言，特征明确的其他语言不受影响。
    /// 用户语言需为热门的 10 倍：只放大热门层时，同在热门层的法语会与英语抢短文本。
    static let languageDetectionBaseWeight = 1.0
    static let languageDetectionPopularWeight = 3.0
    static let languageDetectionUserWeight = 30.0
    /// 热门语言（识别器语言码）：英、简中、繁中、日、韩、法、德、西、葡、俄、意。
    static let languageDetectionPopular = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "pt", "ru", "it"]
    /// NLLanguageRecognizer 可识别的全部语言码（57 种）。给出先验后未列出的语言几乎不会被识别出来，
    /// 系统新增可识别语言时须补入此表。
    static let languageDetectionAll = [
        "am", "ar", "hy", "bn", "bg", "my", "ca", "chr", "hr", "cs", "da", "nl", "en", "fi", "fr", "ka", "de", "el", "gu",
        "he", "hi", "hu", "is", "id", "it", "ja", "kn", "kk", "km", "ko", "lo", "ms", "ml", "mr", "mn-Mong", "nb", "or",
        "fa", "pl", "pt", "pa-Guru", "ro", "ru", "zh-Hans", "si", "sk", "es", "sv", "ta", "te", "th", "bo", "zh-Hant",
        "tr", "uk", "ur", "vi",
    ]
    /// recordingClickEffect / recordingClickRightDistinct 协议值；区域与显示器录制点击特效样式与右键/拖动区分（#143），与Dart常量同步。
    static let recordingClickEffectKey = "recordingClickEffect"
    static let recordingClickRightDistinctKey = "recordingClickRightDistinct"
    /// 录屏鼠标点击特效规范数值（#67、#143）：左键 #007AFF、右键 #FF9500、半径/描边/时长与拖动轨迹。
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
    /// scrollCaptureMode 偏好键；长截图滚动方式 manual/automatic，开始长截图时读取（#112），与Dart常量同步。
    static let scrollCaptureModeKey = "scrollCaptureMode"
    /// recordingDelay 偏好键；开始录制前的倒计时秒数，随截图快照与工具栏变更通知交给截图引擎（#129），与Dart常量同步。
    static let recordingDelayKey = "recordingDelay"
    /// 录制延时的可选秒数，0 为不延时；prepareCapture 的 delay 只接受这些值（#129），与Dart常量同步。
    static let recordingDelays = [0, 3, 5, 10]
    static let gifMaximumWidthKey = "gifMaximumWidth"
    /// Escape 键的硬件键码（kVK_Escape）。
    static let escapeKeyCode: UInt16 = 53
    /// 本应用合成键鼠事件写入 eventSourceUserData 的标记（ASCII「TRAN」）；选区监听据此忽略自身注入的事件（#140）。
    static let syntheticEventTag: Int64 = 0x5452_414E
    /// 全局快捷键必须包含其中至少一个修饰键（Carbon 修饰键位）。
    static let shortcutRequiredModifiers = UInt32(cmdKey | optionKey | controlKey)
    /// 全局快捷键允许出现的全部修饰键（Carbon 修饰键位）。
    static let shortcutAllowedModifiers = shortcutRequiredModifiers | UInt32(shiftKey)
    /// 文本编辑组合的主键键码（kVK_ANSI_A/Z/X/C/V）：仅 Command 或 Command+Shift 搭配时为全选、撤销/重做、剪切、复制、粘贴（含粘贴并匹配样式），
    /// 独占注册会让所有应用失去这些操作，不能作为全局快捷键。
    static let textEditingKeyCodes: Set<UInt32> = [0, 6, 7, 8, 9]
    /// Return 键的硬件键码（kVK_Return）。
    static let returnKeyCode: UInt16 = 36
    /// 小键盘 Enter 键的硬件键码（kVK_ANSI_KeypadEnter）。
    static let keypadEnterKeyCode: UInt16 = 76
    static let confirmScreenshotMethod = "confirmScreenshot"
    /// 方向键硬件键码（kVK_LeftArrow…kVK_UpArrow）到截图像素单位方向的映射（#106）。
    static let arrowKeyDirections: [UInt16: (dx: Int, dy: Int)] = [123: (-1, 0), 124: (1, 0), 125: (0, 1), 126: (0, -1)]
    /// nudgeScreenshotCrop 协议值；原生按键路由把方向键交给截图引擎微调选区，参数 id、dx、dy、shift、option（#106），与Dart常量同步。
    static let nudgeScreenshotCropMethod = "nudgeScreenshotCrop"
    static let appReadyMethod = "appReady"
    /// appStartFailed 协议值；主 Dart 引擎初始化失败时发送错误文本，原生提示后退出（#126），与Dart常量同步。
    static let appStartFailedMethod = "appStartFailed"
    /// perfMark 协议值；Dart 交来阶段名与毫秒数，原生写入性能日志（#68「性能测量边界」），与Dart常量同步。
    static let perfMarkMethod = "perfMark"
    static let appearanceChangedMethod = "appearanceChanged"
    /// 设置页拖动透明度或调色时的外观预览；参数为 {glassOpacity?, accentColor?}，nil 清除预览，只广播不写偏好（#144）。
    static let previewAppearanceMethod = "previewAppearance"
    static let applicationSupportPathMethod = "applicationSupportPath"
    /// 贴纸库协议值（#103），与Dart常量同步：选择并规范化图片、写入贴纸文件、删除贴纸文件。
    static let importStickerImageMethod = "importStickerImage"
    static let saveStickerMethod = "saveSticker"
    static let deleteStickerMethod = "deleteSticker"
    static let stickerDirectoryMethod = "stickerDirectory"
    /// 截图贴纸面板打开设置、Delete 键删除选中标注的协议值（#103），与Dart常量同步。
    static let openStickerSettingsMethod = "openStickerSettings"
    static let deleteScreenshotSelectionMethod = "deleteScreenshotSelection"
    /// Delete（kVK_Delete）与向前删除（kVK_ForwardDelete）的硬件键码（#103）。
    static let deleteKeyCodes: Set<UInt16> = [51, 117]
    /// 截图快照中的贴纸列表与贴纸目录键（#103），与Dart常量同步。
    static let stickersKey = "stickers"
    static let stickerDirectoryKey = "stickerDirectory"
    /// 贴纸图片长边上限（像素），导入时超过则按原比例缩小（#103）。
    static let stickerMaxPixels = 1024
    static let applySettingsMethod = "applySettings"
    static let automaticKey = "automatic"
    static let badAppError = "bad_app"
    static let badArgsError = "bad_args"
    static let badSettingsError = "bad_settings"
    static let chooseExcludedAppMethod = "chooseExcludedApp"
    /// systemShortcuts 协议值；读取已启用的系统快捷键 [{keyCode, modifiers}]，与 Dart 常量同步（#141）。
    static let systemShortcutsMethod = "systemShortcuts"
    /// 系统快捷键设置的偏好域与键；只读取，不修改。
    static let symbolicHotKeysDomain = "com.apple.symbolichotkeys"
    static let symbolicHotKeysKey = "AppleSymbolicHotKeys"
    static let chooseScreenshotDirectoryMethod = "chooseScreenshotDirectory"
    static let closePermissionWizardMethod = "closePermissionWizard"
    static let closeScreenshotMethod = "closeScreenshot"
    static let copyScreenshotMethod = "copyScreenshot"
    static let copyTextMethod = "copyText"
    static let copyFailedError = "copy_failed"
    static let credentialIdsMethod = "credentialIds"
    static let detectLanguageMethod = "detectLanguage"
    static let dragOverlayMethod = "dragOverlay"
    static let escapePressedMethod = "escapePressed"
    static let excludedAppsKey = "excludedApps"
    static let finishPermissionWizardMethod = "finishPermissionWizard"
    static let getAppearanceMethod = "getAppearance"
    static let getScreenshotMethod = "getScreenshot"
    static let glassAppearanceKey = "glassAppearance"
    static let glassOpacityKey = "glassOpacity"
    /// 个性化强调色偏好与六种经典色表（sRGB ARGB 整数），与 Dart AccentColors 同步（#144）。
    static let accentColorKey = "accentColor"
    /// 强调色实底上的前景偏好（auto / white / black / #RRGGBB），随外观快照原样下发，与 Dart PreferenceKeys.accentForeground 同步（#144）。
    static let accentForegroundKey = "accentForeground"
    static let accentSystem = "system"
    /// 强调色预设的浅、深两套 sRGB ARGB 值，与 Dart AccentColors.swatches 同步；自定义色为 #RRGGBB（#144）。
    static let accentSwatches: [String: (light: Int, dark: Int)] = [
        "blue": (0xFF2F_6FE4, 0xFF4C_8DFF),
        "purple": (0xFF6E_56CF, 0xFF9B_8AFB),
        "pink": (0xFFC9_356E, 0xFFF0_6A97),
        "orange": (0xFFC2_560F, 0xFFFF_8F4D),
        "green": (0xFF0B_7F72, 0xFF2E_C4AE),
        "graphite": (0xFF57_606C, 0xFFA3_AAB4),
    ]
    /// 自定义强调色深色外观值由浅色值向白混合的比例，与 Dart AccentColors.customDarkLift 同步（#144）。
    static let accentCustomDarkLift = 0.35
    /// 外观快照中按浅、深外观解析的系统强调色（sRGB ARGB 整数），与 Dart AppearanceKeys 同步（#142）。
    static let accentLightKey = "accentLight"
    static let accentDarkKey = "accentDark"
    static let hideOverlayMethod = "hideOverlay"
    static let historyEntrypoint = "historyMain"
    static let keychainFailedError = "keychain_failed"
    /// 凭据在钥匙串中的服务名；凭据列举、读取与写入共用，改动会使已存凭据读不到（#122）。
    static let credentialsKeychainService = "com.coolyang.translateApp.credentials"
    static let launchAtLoginKey = "launchAtLogin"
    static let loadSettingsMethod = "loadSettings"
    static let ocrEmptyError = "ocr_empty"
    static let ocrFailedError = "ocr_failed"
    static let openAccessibilityMethod = "openAccessibility"
    static let openLoginItemsMethod = "openLoginItems"
    /// openTranslationLanguages 协议值；设置页打开系统「语言与地区」下载离线翻译语言（#98），与Dart常量同步。
    static let openTranslationLanguagesMethod = "openTranslationLanguages"
    /// 系统设置「通用 → 语言与地区」面板；「翻译语言…」在该面板内（#98）。
    static let translationLanguagesSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!
    /// openLink 协议值；截图识别结果中的链接交给默认浏览器（#108），与Dart常量同步。
    static let openLinkMethod = "openLink"
    /// 识别结果中允许打开的链接协议；其他协议只可复制（#108），与Dart常量同步。
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
    /// setWindowTitle 协议值；设置或历史等独立窗口同步更新所属 NSWindow 标题，参数 title（#144），与 Dart 常量同步。
    static let setWindowTitleMethod = "setWindowTitle"
    /// replaceSelection 协议值；输入翻译完成后把译文粘贴回来源应用，与Dart常量同步。
    static let replaceSelectionMethod = "replaceSelection"
    /// showInputFailure 协议值；输入翻译失败时 Dart 发送 sessionId 与 message，原生在选中区域附近显示失败气泡（#99），与Dart常量同步。
    static let showInputFailureMethod = "showInputFailure"
    /// 输入翻译失败气泡的自动消失时长（毫秒，悬停暂停计时、离开后重新计时 2000ms）与距锚点的间距（#99、#144）。
    static let inputFailureDurationMs = 2000
    static let inputFailureGap: CGFloat = 8
    /// 输入翻译失败气泡左端错误图标边长与文本间距，避免仅靠颜色区分错误（#144）。
    static let inputFailureIconSize: CGFloat = 14
    static let inputFailureIconSpacing: CGFloat = 6
    /// 输入翻译锚点使用的文本标记范围属性名（Electron/WebKit 的只读文本，SDK 未提供常量）：选区范围与按范围取屏幕矩形。
    static let axSelectedTextMarkerRangeAttribute = "AXSelectedTextMarkerRange"
    static let axBoundsForTextMarkerRangeAttribute = "AXBoundsForTextMarkerRange"
    /// 输入翻译进行中浮标（#67）：读取原文后等待的毫秒数、文案、字号、高度、圆角、水平内边距、转圈边长与转圈到文字的间距。
    static let inputProgressDelayMs = 300
    static let inputProgressText = "翻译中…"
    static let inputProgressFontSize: CGFloat = 13
    static let inputProgressHeight: CGFloat = 24
    static let inputProgressRadius: CGFloat = 12
    static let inputProgressPaddingX: CGFloat = 10
    static let inputProgressSpinnerSize: CGFloat = 12
    static let inputProgressSpacing: CGFloat = 6
    /// 输入翻译视为文本输入控件的 AX 角色：读不到选区时的全选范围与粘贴目标查找共用。
    static let axTextInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]
    /// 本进程辅助功能调用的消息超时（秒），来源应用无响应时单次调用最多等待该时长（#68）。
    static let axMessagingTimeout: Float = 1
    /// 输入翻译粘贴目标查找（#1）：焦点不在输入控件时遍历来源窗口的节点数、深度与总时长上限，聚焦目标后等待来源应用完成聚焦的时长。
    static let inputTargetSearchMaxNodes = 2000
    static let inputTargetSearchMaxDepth = 40
    static let inputTargetSearchTimeout = Duration.seconds(1)
    static let inputTargetFocusDelay = Duration.milliseconds(80)
    /// 输入翻译粘贴后等待来源应用读取剪贴板的时长，之后才还原原剪贴板（#99）。
    static let pasteRestoreDelay = Duration.milliseconds(500)
    static let revealFileMethod = "revealFile"
    static let rollbackFailedError = "rollback_failed"
    static let saveScreenshotMethod = "saveScreenshot"
    static let saveFailedError = "save_failed"
    static let screenshotChangedMethod = "screenshotChanged"
    static let screenshotShortcutKeyCodeKey = "screenshotShortcutKeyCode"
    static let screenshotShortcutLabelKey = "screenshotShortcutLabel"
    static let screenshotShortcutModifiersKey = "screenshotShortcutModifiers"
    static let selectionCapturedEvent = "selectionCaptured"
    static let selectionInvalidatedEvent = "selectionInvalidated"
    static let setOverlaySizeMethod = "setOverlaySize"
    static let settingsEntrypoint = "settingsMain"
    static let settingsFailedError = "settings_failed"
    static let shortcutKeyCodeKey = "shortcutKeyCode"
    static let shortcutLabelKey = "shortcutLabel"
    static let shortcutModifiersKey = "shortcutModifiers"
    /// inputShortcutKeyCode 协议值；输入翻译快捷键键码，与Dart常量同步。
    static let inputShortcutKeyCodeKey = "inputShortcutKeyCode"
    /// inputShortcutLabel 协议值；输入翻译快捷键显示名，与Dart常量同步。
    static let inputShortcutLabelKey = "inputShortcutLabel"
    /// inputShortcutModifiers 协议值；输入翻译快捷键修饰键，与Dart常量同步。
    static let inputShortcutModifiersKey = "inputShortcutModifiers"
    static let shortcutInvalidError = "shortcut_invalid"
    static let showOverlayMethod = "showOverlay"
    static let staleCaptureError = "stale_capture"
    static let systemStatusMethod = "systemStatus"
    /// recordScreenshotHistory 协议值；截图导出成功且开关开启时原生请求主引擎记录，与Dart常量同步。
    static let recordScreenshotHistoryMethod = "recordScreenshotHistory"
    /// screenshotHistoryRecording 协议值；原生导出成功后向主引擎查询「记录截图历史」开关，与Dart常量同步。
    static let screenshotHistoryRecordingMethod = "screenshotHistoryRecording"
    /// stitchScreenshots 协议值；按顺序拼接截图历史图片（#109），与Dart常量同步。
    static let stitchScreenshotsMethod = "stitchScreenshots"
    /// splitScreenshot 协议值；按高度等分一张截图历史图片（#109），与Dart常量同步。
    static let splitScreenshotMethod = "splitScreenshot"
    /// compareScreenshots 协议值；逐像素比较两张截图历史图片（#109），与Dart常量同步。
    static let compareScreenshotsMethod = "compareScreenshots"
    /// compose_failed 协议值；拼接、拆分或比较失败（#109），与Dart常量同步。
    static let composeFailedError = "compose_failed"
    /// openFile 协议值；用系统默认应用打开文件，与Dart常量同步。
    static let openFileMethod = "openFile"
    /// copyImageFile 协议值；把 PNG 文件复制到剪贴板，与Dart常量同步。
    static let copyImageFileMethod = "copyImageFile"
    /// lookupDefinition 协议值；查询 macOS 词典释义，与Dart常量同步。
    static let lookupDefinitionMethod = "lookupDefinition"
    /// vocabularyList 协议值；历史窗口读取生词本，转发主引擎，与Dart常量同步。
    static let vocabularyListMethod = "vocabularyList"
    /// saveTextFile 协议值；经系统保存面板保存文本文件，与Dart常量同步。
    static let saveTextFileMethod = "saveTextFile"
    /// openGlossaryFile 协议值；系统面板读取术语 CSV/JSON，与 Dart 常量同步。
    static let openGlossaryFileMethod = "openGlossaryFile"
    /// cancelScreenshotTranslation 协议值；截图生命周期结束时取消主引擎翻译。
    static let cancelScreenshotTranslationMethod = "cancelScreenshotTranslation"
    /// toggleSpeech 协议值；朗读或停止朗读卡片一栏文字，与Dart常量同步。
    static let toggleSpeechMethod = "toggleSpeech"
    /// stopSpeech 协议值；停止当前朗读，与Dart常量同步。
    static let stopSpeechMethod = "stopSpeech"
    /// systemTranslate 协议值；Apple 系统翻译一组段落，与Dart常量同步。
    static let systemTranslateMethod = "systemTranslate"
    /// cancelSystemTranslation 协议值；按 requestId 取消系统翻译，与Dart常量同步。
    static let cancelSystemTranslationMethod = "cancelSystemTranslation"
    /// systemTranslationStatus 协议值；查询语言对安装状态，与Dart常量同步。
    static let systemTranslationStatusMethod = "systemTranslationStatus"
    /// 系统翻译语言对状态：语言包已安装；与Dart SystemTranslationStatus同步。
    static let systemTranslationInstalled = "installed"
    /// 系统翻译语言对状态：支持但语言包未下载；与Dart SystemTranslationStatus同步。
    static let systemTranslationSupported = "supported"
    /// 系统翻译语言对状态：不支持；与Dart SystemTranslationStatus同步。
    static let systemTranslationUnsupported = "unsupported"
    /// 系统翻译高保真策略；与Dart SystemTranslationStrategy同步，其余值按低延迟处理。
    static let systemTranslationHighFidelity = "highFidelity"
    static let toggleAutomaticMethod = "toggleAutomatic"
    /// translateScreenshotBlocks 协议值；截图引擎把段落块经原生交主引擎分块翻译（#138），与Dart常量同步。
    static let translateScreenshotBlocksMethod = "translateScreenshotBlocks"
    /// prewarmTranslation 协议值；截图开始识别文字时请求主引擎预热翻译连接（#68），与Dart常量同步。
    static let prewarmTranslationMethod = "prewarmTranslation"
    /// publishScreenshotTranslation 协议值；主引擎截图翻译快照经原生转给截图引擎（#138），与Dart常量同步。
    static let publishScreenshotTranslationMethod = "publishScreenshotTranslation"
    /// translate_failed 协议值；与Dart常量同步。
    static let translateFailedError = "translate_failed"
    /// translation_not_installed 协议值；系统翻译语言包未下载，与Dart常量同步。
    static let translationNotInstalledError = "translation_not_installed"
    /// translation_unsupported 协议值；系统翻译不支持该语言对，与Dart常量同步。
    static let translationUnsupportedError = "translation_unsupported"
    static let appearanceChannel = "translateapp/appearance"
    /// 主引擎平台通道与事件通道，与 Dart ChannelNames.platform/platformEvents 同步；Windows 原生实现同一协议。
    static let platformChannel = "translateapp/platform"
    static let platformEventsChannel = "translateapp/platform/events"
    static let nativeGlassViewType = "translateapp/native-glass"
    static let undoPressedMethod = "undoPressed"

    /// App 在用户 Application Support 下的数据目录名；历史库与 MCP socket 共用。
    static let applicationSupportFolderName = "TranslateApp"
    /// 本应用 NSError 的统一域名。
    static let errorDomain = "TranslateApp"
    /// 钥匙串读写失败的 NSError 域名。
    static let keychainErrorDomain = "TranslateApp.Keychain"
    /// 缺少屏幕录制权限时显示给用户的统一提示。
    static let screenRecordingRequiredMessage = "需要屏幕录制权限，请在系统设置中允许 TranslateApp 后重试。"
    /// 长图结果窗的最小内容尺寸，单位点。
    static let longScreenshotResultMinimumSize = NSSize(width: 320, height: 240)
    /// 设置与历史独立窗口的系统框架持久化键名（#144 U-34）。
    static let settingsWindowAutosaveName: NSWindow.FrameAutosaveName = "TranslateAppSettingsWindow"
    static let historyWindowAutosaveName: NSWindow.FrameAutosaveName = "TranslateAppHistoryWindow"
    /// 权限向导与历史独立窗口的最小尺寸，防止缩窄造成主体或顶栏挤压溢出（#144 U-14）。
    static let permissionWizardMinSize = NSSize(width: 440, height: 340)
    static let historyWindowMinSize = NSSize(width: 480, height: 480)
    /// 翻译浮层触发胶囊与展开卡片的宿主裁切圆角（pt）及触发器最大高度阈值，与 Dart GlassMetrics 一致（#144 U-18）。
    static let overlayTriggerCornerRadius: CGFloat = 10
    static let overlayCardCornerRadius: CGFloat = 16
    static let overlayTriggerMaxHeight: CGFloat = 44
    /// 桌面贴图右上角悬停关闭按钮边长与内缩间距（pt，满足 WCAG 2.5.8 最小 24pt 命中目标，#144 U-29）。
    static let pinCloseButtonSize: CGFloat = 24
    static let pinCloseButtonInset: CGFloat = 6
    /// 无参数；返回用户 Application Support 下的 App 数据目录（不保证已创建），历史库与 MCP socket 共用。
    static var applicationSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(applicationSupportFolderName, isDirectory: true)
    }
    /// 无参数；返回 App 数据目录下保存「我的贴纸」PNG 的目录（不保证已创建，#103）。
    static var stickersURL: URL {
        applicationSupportURL.appendingPathComponent("Stickers", isDirectory: true)
    }
    /// MCP 接口（#96、#68「MCP 接口边界」）：stdio helper 与 App 共用的名称、图片预算和英文协议文案。
    /// helper 可执行文件名，位于 App 包 Contents/MacOS。
    static let mcpHelperName = "translateapp-mcp"
    /// MCP serverInfo.name 与客户端配置中的服务名。
    static let mcpServerName = "translateapp"
    /// helper 连接 App 的 Unix domain socket 文件名，位于 Application Support 数据目录。
    static let mcpSocketFileName = "mcp.sock"
    /// 返回图片长边上限，单位像素（#96 决策 3）。
    static let mcpImageMaxEdge = 1568
    /// Claude 视觉 token 的切块边长，单位像素；token 数为 ⌈宽/28⌉×⌈高/28⌉（#96 决策 3）。
    static let mcpTokenPatch = 28
    /// 连接不到 App 时返回给 agent 的错误。
    static let mcpNotRunningMessage = "TranslateApp is not running."
    /// MCP helper 的代码签名标识符；App 只接受该标识符且与本 App 同证书签名的 socket 对端（#140）。
    static let mcpHelperIdentifier = "com.coolyang.translateApp.mcp"
    /// socket 对端不是本 App 签名的 helper 时返回的错误。
    static let mcpUntrustedPeerMessage = "Connection refused: the caller is not the TranslateApp MCP helper."
    /// 设置中 MCP 开关关闭时返回给 agent 的错误。
    static let mcpDisabledMessage = "MCP is disabled in TranslateApp settings."
    /// 屏幕录制授权被拒绝时返回给 agent 的错误。
    static let mcpPermissionMessage = "TranslateApp lacks Screen Recording permission. Allow it in System Settings > Privacy & Security > Screen Recording, then retry."
    /// 运行中的 App 与 helper 版本不一致、请求或结果结构无法解析时返回给 agent 的错误。
    static let mcpVersionMismatchMessage = "TranslateApp and its MCP helper are different versions. Restart TranslateApp, then retry."
    /// OCR 没有识别到文字时返回给 agent 的文本。
    static let mcpNoTextMessage = "No text recognized."
    /// 截图类工具的矩形超出参考清晰度图片时的错误；reference 为清晰度名，display 为显示器序号，width/height 为该图尺寸。
    static func mcpRectangleOutOfRangeMessage(reference: String, display: Int, width: Int, height: Int) -> String {
        "Rectangle exceeds the \(reference) image of display \(display) (\(width)×\(height))."
    }
    /// capture_window 找不到窗口时的错误；windowID 为请求的窗口编号。
    static func mcpWindowNotFoundMessage(windowID: UInt32) -> String {
        "window_id \(windowID) not found; call list_windows again."
    }
    /// 截图失败时的错误；reason 为失败原因描述。
    static func mcpCaptureFailedMessage(_ reason: String) -> String { "Capture failed: \(reason)" }
    /// 显示器序号越界时的错误；index 为请求序号，count 为当前显示器数量。
    static func mcpDisplayOutOfRangeMessage(index: Int, count: Int) -> String {
        "display_index \(index) is out of range; \(count) displays available."
    }
    /// 工具调用包含未声明参数时的错误；name 为参数名。
    static func mcpUnknownArgumentMessage(_ name: String) -> String { "Unknown argument: \(name)" }
    /// 工具调用缺少必填参数时的错误；key 为参数名。
    static func mcpMissingArgumentMessage(_ key: String) -> String { "Missing required argument: \(key)" }
    /// 响应无法序列化为 JSON 时的 JSON-RPC 内部错误文案。
    static let mcpInternalErrorMessage = "Internal error: response is not JSON-serializable."
    /// helper 无法连接 App 时的错误；reason 为失败原因描述。
    static func mcpConnectFailedMessage(_ reason: String) -> String { "Cannot connect to TranslateApp: \(reason)" }
    /// App 未返回结果就关闭连接时的错误。
    static let mcpConnectionClosedMessage = "TranslateApp closed the connection without a result."
    /// helper 与 App 通信中断时的错误；reason 为失败原因描述。
    static func mcpCommunicationFailedMessage(_ reason: String) -> String { "Communication with TranslateApp failed: \(reason)" }
    /// 请求不是合法 JSON 时的 JSON-RPC 错误文案。
    static let mcpParseErrorMessage = "Parse error"
    /// 请求的 JSON-RPC 方法不存在时的错误；method 为方法名。
    static func mcpMethodNotFoundMessage(_ method: String) -> String { "Method not found: \(method)" }
    /// 调用的工具不存在时的错误；name 为工具名。
    static func mcpUnknownToolMessage(_ name: String) -> String { "Unknown tool: \(name)" }
    /// 截图数据无法解码为像素时的错误。
    static let mcpPixelReadFailedMessage = "Unable to read screenshot pixels."
    /// 截图无法缩放到目标尺寸时的错误。
    static let mcpScaleFailedMessage = "Unable to scale screenshot."
    /// 设置中「允许 agent 截图」开关的偏好键；与 Dart PreferenceKeys.mcpEnabled 一致。
    static let mcpEnabledKey = "mcpEnabled"
    /// 偏好字典中「允许操控电脑」开关的键，与 Dart PreferenceKeys.mcpControlEnabled 一致（#140）。
    static let mcpControlEnabledKey = "mcpControlEnabled"
    /// App 的包标识；helper 据此读取 App 偏好判断 tools/list 是否列出操控类工具（#140）。
    static let appBundleIdentifier = "com.coolyang.translateApp"
    /// 「允许操控电脑」关闭时调用操控类工具返回的错误。
    static let mcpControlDisabledMessage = "Computer control is disabled in TranslateApp settings."
    /// 辅助功能未授权时操控类工具返回的错误。
    static let mcpAccessibilityPermissionMessage = "TranslateApp lacks Accessibility permission. Allow it in System Settings > Privacy & Security > Accessibility, then retry."
    /// 目标应用禁止读取或操作时的错误；name 为应用显示名。
    static func mcpBlockedAppMessage(_ name: String) -> String { "\(name) is blocked from computer control." }
    /// 按名称或包标识找不到运行中应用时的错误。
    static func mcpAppNotRunningMessage(_ name: String) -> String { "App \(name) is not running; check list_windows." }
    /// 名称对应多个运行中应用时的错误；candidates 为可用的包标识。
    static func mcpAmbiguousAppMessage(_ name: String, candidates: [String]) -> String {
        "App \(name) is ambiguous; pass one bundle id: \(candidates.joined(separator: ", "))"
    }
    /// window_id 对应窗口不在无障碍树中时的错误。
    static func mcpWindowNotInTreeMessage(windowID: UInt32) -> String {
        "window_id \(windowID) has no accessibility information; use capture_window and pixel coordinates."
    }
    /// ref 格式不合法时的错误。
    static func mcpInvalidRefMessage(_ ref: String) -> String { "Invalid ref \(ref); refs look like @s3:e12." }
    /// ref 对应快照已淘汰或元素已消失时的错误。
    static func mcpStaleRefMessage(_ ref: String) -> String { "Ref \(ref) is stale; call snapshot or find again." }
    /// 同时给出互斥的目标参数时的错误。
    static let mcpTargetConflictMessage = "Pass only one of app, window_id or root."
    /// 操作目标既不是 ref 也不是完整坐标、或两者都给出时的错误。
    static let mcpPointTargetMessage = "Pass ref, or display_index with x and y, not both."
    /// click 的 count 超出 1–2 时的错误。
    static let mcpClickCountMessage = "count must be 1 or 2"
    /// drag 的终点超出参考截图范围时的错误。
    static let mcpDragTargetMessage = "drag needs display_index, x, y, to_x and to_y within the capture_screen image."
    /// 目标为密码框时的错误。
    static let mcpSecureFieldMessage = "Typing into password fields is refused."
    /// 按键组合无法解析时的错误。
    static func mcpInvalidKeysMessage(_ keys: String) -> String {
        "Cannot parse keys \(keys); use forms like cmd+s, return, shift+tab, f5."
    }
    /// 退出、注销、锁屏与强制退出类快捷键被拒绝时的错误。
    static func mcpForbiddenKeysMessage(_ keys: String) -> String { "\(keys) is refused: quit, log-out and force-quit shortcuts are blocked." }
    /// 用户拒绝或未在时限内允许操作某应用时的错误。
    static func mcpDeniedMessage(_ app: String) -> String { "The user did not allow control of \(app) in this session." }
    /// 上一个操作仍在执行（含等待授权）时的错误。
    static let mcpControlBusyMessage = "Another control action is still running; wait for its result."
    /// 用户持续操作电脑、等待超时时的错误。
    static let mcpUserBusyMessage = "The user is using the computer; retry shortly."
    /// 操作中途被用户的真实输入打断时的错误。
    static let mcpInterruptedMessage = "Interrupted by the user's input; observe again before retrying."
    /// 坐标处没有可操作窗口时的错误。
    static let mcpNoWindowAtPointMessage = "No app window at that point."
    /// 操作已执行但附带截图失败时追加的说明。
    static let mcpScreenshotUnavailableMessage = "Screenshot unavailable: grant Screen Recording permission."
    /// 非激活翻译浮层缩放与淡入动画时长，单位秒（#67、#142）。
    static let overlayResizeAnimationDuration: TimeInterval = 0.24
    static let overlayFadeInDuration: TimeInterval = 0.16
    /// 实时翻译盖层逐字显影参数：单字时长（秒）、错峰间隔（秒）、错峰总长上限（秒）与初始模糊半径（pt），与 Dart MotionMetrics 一致（#142）。
    static let charRevealDuration: TimeInterval = 0.18
    static let charRevealStagger: TimeInterval = 0.012
    static let charRevealMaxSpread: TimeInterval = 0.60
    static let charRevealBlur: CGFloat = 3
    /// 实时翻译盖层块最小可读字号（pt）、内边距与圆角（#144 U-31）。
    static let liveOverlayMinFontSize: CGFloat = 10
    static let liveOverlayPadding = NSSize(width: 4, height: 2)
    static let liveOverlayCornerRadius: CGFloat = 4
    /// 操控会话的时长上限与空闲上限，单位秒（#140：30 分钟、5 分钟）。
    static let controlSessionLimit: TimeInterval = 30 * 60
    static let controlIdleLimit: TimeInterval = 5 * 60
    /// 用户最近一次真实输入后需要静止的时长；未静止时不借用前台，单位秒。
    static let controlUserIdleInterval: TimeInterval = 1
    /// 等待用户静止的最长时长，超过返回用户忙，单位秒。
    static let controlUserWaitLimit: TimeInterval = 10
    /// 授权面板等待用户回应的时长，超时按拒绝处理，单位秒（#140）。
    static let controlApprovalTimeout: TimeInterval = 30
    /// 激活目标应用后等待其成为前台的时长、操作后附带截图前等待界面更新的时长，单位秒。
    static let controlActivationDelay: TimeInterval = 0.15
    static let controlSettleDelay: TimeInterval = 0.3
    /// 操控边框宽度（pt）与颜色 #FF9500（#67「电脑操控提示」）。
    static let controlBorderWidth: CGFloat = 3
    static let controlBorderColor = NSColor(srgbRed: 1, green: 0x95 / 255.0, blue: 0, alpha: 1)
    /// 操控期间菜单栏图标。
    static let controlSymbol = "cursorarrow.rays"
    /// 授权面板宽度、内边距与距可见区域顶部的距离，单位 pt（#67「电脑操控提示」）。
    static let controlPanelWidth: CGFloat = 360
    static let controlPanelPadding: CGFloat = 16
    static let controlPanelTopInset: CGFloat = 48
    static let controlPanelCornerRadius: CGFloat = 14
    /// 本地操作日志文件名，位于 Application Support 数据目录；只记录时间、应用、动作与目标，不记录输入文字。
    static let controlLogFileName = "control.log"
    /// find 未给出任何筛选条件时的错误。
    static let mcpFindFilterMessage = "Pass role, text or both."
    /// 操控禁止的应用包标识（#140 安全基线）：系统设置、钥匙串访问、密码、1Password、Bitwarden；另合并用户的「排除应用」。
    static let controlBlockedBundleIDs: Set<String> = [
        "com.apple.systempreferences", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.1password.1password", "com.bitwarden.desktop",
    ]
    /// 一次快照遍历的时间预算，单位秒；超时返回已读部分并标为不完整。
    static let mcpSnapshotBudget: TimeInterval = 2
    /// 一次快照最多输出的元素数；超过时标为不完整，模型可用 root 展开局部。
    static let mcpSnapshotElementLimit = 400
    /// find 最多返回的匹配数。
    static let mcpFindLimit = 50
    /// 快照默认与最大遍历深度。
    static let mcpSnapshotDefaultDepth = 10
    static let mcpSnapshotMaxDepth = 50
    /// 内存中保留的快照数；更早快照的 ref 视为失效。
    static let mcpRefSnapshotLimit = 8
    /// 元素值输出的最大字符数，超出截断。
    static let mcpElementValueLimit = 120
    /// 设置页读取 helper 完整路径的方法；与 Dart MethodNames.mcpHelperPath 一致。
    static let mcpHelperPathMethod = "mcpHelperPath"
    /// 截图类工具执行期间的菜单栏图标与最短保持时间（#96 待确认的界面数值）。
    static let mcpCaptureSymbol = "camera.viewfinder"
    static let mcpCaptureIndicatorMinimum = Duration.milliseconds(1000)
}

/// 明确热键读不到文字的原因；rawValue与Dart SelectionReadFailures保持一致，没有可说明的原因时不发送。
enum SelectionReadFailure: String {
    /// 焦点为密码框：安全文本控件不读取。
    case secureField
}

/// 跨端选区手势；rawValue与Dart SelectionGestureTypes保持一致。
enum SelectionGesture: String {
    case drag
    case doubleClick
    case tripleClick
    case selectAll
    case keyboard
    case hotkey
    case inputHotkey

    /// 无参数；返回是否为用户按下全局快捷键发起的明确请求，明确请求允许一次性复制读取并替换保留的结果。
    var isExplicit: Bool { self == .hotkey || self == .inputHotkey }

    /// keyCode 为硬件键码，modifiers 为修饰键；返回创建文本选区的手势或 nil。
    static func keyboardGesture(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> SelectionGesture? {
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        if keyCode == 0, flags == .command { return .selectAll }
        // Shift 配合方向/Home/End/Page 键覆盖按字、按词、按行及全文扩选。
        let navigationKeys: Set<UInt16> = [115, 116, 119, 121, 123, 124, 125, 126]
        if flags.contains(.shift), navigationKeys.contains(keyCode) { return .keyboard }
        return nil
    }
}

/// 全局热键用途；三者在同一注册事务中校验，偏好键给出各自的键码、修饰键与显示名。
enum GlobalHotKey: CaseIterable {
    case translate
    case input
    case screenshot

    /// 无参数；返回该用途键码在偏好字典中的键。
    var keyCodeKey: String {
        switch self {
        case .translate: AppConstants.shortcutKeyCodeKey
        case .input: AppConstants.inputShortcutKeyCodeKey
        case .screenshot: AppConstants.screenshotShortcutKeyCodeKey
        }
    }

    /// 无参数；返回该用途修饰键在偏好字典中的键。
    var modifiersKey: String {
        switch self {
        case .translate: AppConstants.shortcutModifiersKey
        case .input: AppConstants.inputShortcutModifiersKey
        case .screenshot: AppConstants.screenshotShortcutModifiersKey
        }
    }

    /// 无参数；返回该用途在设置页中的名称，用于说明哪一个快捷键注册失败。
    var title: String {
        switch self {
        case .translate: "全局翻译快捷键"
        case .input: "输入翻译快捷键"
        case .screenshot: "区域截图快捷键"
        }
    }

    /// 无参数；返回该用途显示名在偏好字典中的键。
    var labelKey: String {
        switch self {
        case .translate: AppConstants.shortcutLabelKey
        case .input: AppConstants.inputShortcutLabelKey
        case .screenshot: AppConstants.screenshotShortcutLabelKey
        }
    }

    /// preferences 为已保存偏好字典；解析全局快捷键用于菜单项展示，返回标题后缀、单字符键等效符与修饰键标志。
    /// 当偏好尚未写入、缺少修饰键或标签为空时返回 nil。
    func formattedShortcut(
        in preferences: [String: Any]
    ) -> (titleSuffix: String, keyEquivalent: String, modifiers: NSEvent.ModifierFlags)? {
        guard let rawModifiers = (preferences[modifiersKey] as? NSNumber)?.uint32Value,
              rawModifiers != 0,
              let rawLabel = (preferences[labelKey] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawLabel.isEmpty else {
            return nil
        }
        var flags: NSEvent.ModifierFlags = []
        var symbols = ""
        // 遵循 macOS 菜单标准顺序：⌃ ⌥ ⇧ ⌘。
        if rawModifiers & UInt32(controlKey) != 0 {
            flags.insert(.control)
            symbols += "⌃"
        }
        if rawModifiers & UInt32(optionKey) != 0 {
            flags.insert(.option)
            symbols += "⌥"
        }
        if rawModifiers & UInt32(shiftKey) != 0 {
            flags.insert(.shift)
            symbols += "⇧"
        }
        if rawModifiers & UInt32(cmdKey) != 0 {
            flags.insert(.command)
            symbols += "⌘"
        }
        guard !flags.isEmpty else { return nil }
        // 单字符可打印 ASCII 交由 AppKit 原生渲染；传小写避免 NSMenuItem 隐式追加 Shift。
        if rawLabel.unicodeScalars.count == 1,
           let scalar = rawLabel.unicodeScalars.first,
           scalar.isASCII,
           scalar.value > 32 && scalar.value < 127 {
            return ("", rawLabel.lowercased(), flags)
        }
        return (" (\(symbols)\(rawLabel))", "", flags)
    }
}

/// MCP 工具；rawValue 为协议工具名（#96、#140），均无需用户逐次操作。
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

    /// 无参数；返回是否为「允许操控电脑」开启后才提供的工具（#140）。
    var isControl: Bool {
        switch self {
        case .listDisplays, .listWindows, .captureScreen, .captureRect, .captureWindow: false
        case .snapshot, .find, .click, .typeText, .pressKey, .scroll, .drag: true
        }
    }
}

/// click 的鼠标键；rawValue 为协议取值，缺省为 left（#140）。
enum MCPMouseButton: String, Codable, CaseIterable {
    case left, right
}

/// scroll 的方向；rawValue 为协议取值（#140）。
enum MCPScrollDirection: String, Codable, CaseIterable {
    case up, down, left, right
}

/// MCP 截图工具的 output 参数；rawValue 为协议取值，缺省为 image。
enum MCPOutput: String, Codable, CaseIterable {
    case image, text, both
}

/// MCP 截图工具的清晰度；rawValue 为协议取值，tokenBudget 为该清晰度的视觉 token 上限（#96 决策 3）。
enum MCPDetail: String, Codable, CaseIterable {
    case low, standard

    var tokenBudget: Int {
        switch self {
        case .low: 512
        case .standard: 1568
        }
    }
}

/// 区域与显示器录制的鼠标点击特效样式；rawValue 与 Dart RecordingClickEffect 一致（#143）。
enum RecordingClickEffect: String, CaseIterable {
    case off
    case optical
    case liquid
    case spotlight
    case prism
    case minimal
    case system
}
