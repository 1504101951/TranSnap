import 'text_mode.dart';

/// Dart 使用的持久化偏好键协议值；Swift AppConstants 也定义的键字面量一致，改名须两端同步，其余键只由 Dart 持久化。
abstract final class PreferenceKeys {
  /// 每工具独立绘图参数。
  static const screenshotDrawing = 'screenshotDrawing';
  static const screenshotToolbarHidden = 'screenshotToolbarHidden';

  /// 截图工具栏网格：各列的修饰键组合与 6 个格位（#141）；与原生偏好键一致。
  static const screenshotToolbarColumns = 'screenshotToolbarColumns';

  /// 截图工具栏的父子结构：父级ID到子级ID列表；与原生偏好键一致。
  static const screenshotToolbarChildren = 'screenshotToolbarChildren';

  static const automatic = 'automatic';

  static const defaultServiceId = 'defaultServiceId';

  static const excludedApps = 'excludedApps';

  /// 区域截图冻结帧是否包含鼠标指针；Swift 冻结画面时读取（#105）。
  static const screenshotIncludesCursor = 'screenshotIncludesCursor';

  /// 区域与显示器录制点击特效样式与右键/拖动区分；Swift 开始录制时读取（#143）。
  static const recordingClickEffect = 'recordingClickEffect';
  static const recordingClickRightDistinct = 'recordingClickRightDistinct';

  /// 开始录制前的倒计时秒数，取值见 RecordingOptions.delays；截图工具栏「录制选项」写入（#129）。
  static const recordingDelay = 'recordingDelay';

  /// 长截图滚动方式：manual 或 automatic；Swift 开始长截图时读取（#112）。
  static const scrollCaptureMode = 'scrollCaptureMode';

  /// 确认截图时的动作：copy 或 copyAndSave；仅 Dart 读取（#111）。
  static const screenshotConfirmAction = 'screenshotConfirmAction';

  /// 我的贴纸：[{id, width, height}]，宽高为默认大小（pt），按添加顺序；截图快照另带贴纸目录路径（#103）。
  static const stickers = 'stickers';
  static const stickerDirectory = 'stickerDirectory';

  /// 术语表；值为 {term, translation, language} 字典列表，仅 Dart 读取（#104）。
  static const glossary = 'glossary';

  static const glassAppearance = 'glassAppearance';

  static const glassOpacity = 'glassOpacity';

  /// 个性化强调色偏好；取值见 AccentColors，默认跟随系统，与 Swift AppConstants.accentColorKey 同步（#144）。
  static const accentColor = 'accentColor';

  static const launchAtLogin = 'launchAtLogin';

  static const primaryLanguage = 'primaryLanguage';

  /// 翻译、润色、纠错、解释的系统提示词；键按处理模式对应，缺省为 defaultPrompts（#100）。
  static const prompts = {
    TextMode.translate: 'translatePrompt',
    TextMode.polish: 'polishPrompt',
    TextMode.correct: 'correctPrompt',
    TextMode.explain: 'explainPrompt',
  };

  /// 各处理模式的思考开关；缺省 false，只对 DeepSeek 与 Anthropic 生效。
  static const thinking = {
    TextMode.translate: 'translateThinking',
    TextMode.polish: 'polishThinking',
    TextMode.correct: 'correctThinking',
    TextMode.explain: 'explainThinking',
  };

  static const screenshotSaveDirectory = 'screenshotSaveDirectory';

  /// GIF完整视频导出的每秒采样帧数；与原生偏好键一致。
  static const gifFramesPerSecond = 'gifFramesPerSecond';

  /// 实时翻译时是否同步录制；与原生偏好键一致。
  static const liveRecording = 'liveRecording';

  /// 是否允许本机 MCP 客户端截图（#96）；与原生 AppConstants.mcpEnabledKey 一致。
  static const mcpEnabled = 'mcpEnabled';

  /// 是否允许本机 MCP 客户端操控电脑（#140）；与原生 AppConstants.mcpControlEnabledKey 一致。
  static const mcpControlEnabled = 'mcpControlEnabled';

  /// GIF最大像素宽度；省略表示不限制，输出仍不会放大原视频。
  static const gifMaximumWidth = 'gifMaximumWidth';

  static const screenshotShortcutKeyCode = 'screenshotShortcutKeyCode';

  static const screenshotShortcutLabel = 'screenshotShortcutLabel';

  static const screenshotShortcutModifiers = 'screenshotShortcutModifiers';

  static const secondaryLanguage = 'secondaryLanguage';

  /// 输入翻译独立的主要/次要语言；主要语言缺失表示从未设置，读取时取全局两项语言（#99）。
  static const inputPrimaryLanguage = 'inputPrimaryLanguage';
  static const inputSecondaryLanguage = 'inputSecondaryLanguage';

  static const services = 'services';

  static const shortcutKeyCode = 'shortcutKeyCode';

  static const shortcutLabel = 'shortcutLabel';

  static const shortcutModifiers = 'shortcutModifiers';

  /// 输入翻译快捷键键码；变更须同步两端及持久化调用方。
  static const inputShortcutKeyCode = 'inputShortcutKeyCode';

  /// 输入翻译快捷键显示名；变更须同步两端及持久化调用方。
  static const inputShortcutLabel = 'inputShortcutLabel';

  /// 输入翻译快捷键修饰键；变更须同步两端及持久化调用方。
  static const inputShortcutModifiers = 'inputShortcutModifiers';
}
