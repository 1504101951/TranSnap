import '../screenshot/drawing_preferences.dart';
import '../common/constants/appearance_modes.dart';
import '../common/constants/preference_keys.dart';
import '../common/constants/screenshot_actions.dart';
import '../common/constants/toolbar_grid.dart';
import '../common/constants/screenshot_enums.dart';
import '../common/constants/shortcut_keys.dart';
import '../common/constants/text_mode.dart';
import '../translation/glossary.dart';
import '../translation/language_direction.dart';
import 'service_config.dart';
import 'screenshot_toolbar_preferences.dart';
import '../screenshot/stickers.dart';

/// Dart 持有完整偏好；平台只负责存储及热键、登录项等系统副作用。
class AppSettings {
  AppSettings({
    required this.primaryLanguage,
    this.secondaryLanguage,
    String? inputPrimaryLanguage,
    String? inputSecondaryLanguage,
    this.automatic = true,
    this.shortcutKeyCode = 17,
    this.shortcutLabel = 'T',
    this.shortcutModifiers = 6144,
    this.inputShortcutKeyCode = 15,
    this.inputShortcutLabel = 'R',
    this.inputShortcutModifiers = 6144,
    this.screenshotShortcutKeyCode = 1,
    this.screenshotShortcutLabel = 'S',
    this.screenshotShortcutModifiers = 6144,
    this.screenshotSaveDirectory = '',
    this.gifFramesPerSecond = 10,
    this.liveRecording = false,
    this.screenshotIncludesCursor = false,
    this.recordingClickEffect = RecordingClickEffect.off,
    this.recordingClickRightDistinct = true,
    this.recordingDelay = 0,
    this.screenshotConfirmAction = ScreenshotConfirmAction.copy,
    this.scrollCaptureMode = ScrollCaptureMode.manual,
    this.mcpEnabled = false,
    this.mcpControlEnabled = false,
    this.gifMaximumWidth,
    this.glassAppearance = AppearanceModes.system,
    this.glassOpacity = 0.8,
    this.accentColor = AccentColors.system,
    this.launchAtLogin = false,
    Map<String, String>? excludedApps,
    List<GlossaryEntry>? glossary,
    Map<TextMode, String>? prompts,
    Map<TextMode, bool>? thinking,
    List<StickerEntry>? stickers,
    this.defaultServiceId = ServiceConfig.builtinId,
    List<ServiceConfig>? services,
    ScreenshotToolbarPreferences? screenshotToolbar,
    DrawingPreferences? drawing,
  }) : // 输入翻译一组未设置过时复制全局两项语言（#99）。
       inputPrimaryLanguage = inputPrimaryLanguage ?? primaryLanguage,
       inputSecondaryLanguage = inputPrimaryLanguage == null
           ? secondaryLanguage
           : inputSecondaryLanguage,
       excludedApps = excludedApps ?? {},
       glossary = glossary ?? [],
       prompts = {...defaultPrompts, ...?prompts},
       thinking = {
         for (final mode in TextMode.values) mode: false,
         ...?thinking,
       },
       stickers = stickers ?? [],
       services = services ?? [],
       screenshotToolbar = screenshotToolbar ?? ScreenshotToolbarPreferences(),
       drawing = drawing ?? DrawingPreferences();

  DrawingPreferences drawing;

  ScreenshotToolbarPreferences screenshotToolbar;
  String primaryLanguage;
  String? secondaryLanguage;

  /// 输入翻译快捷键使用的主要/次要语言，与全局翻译隔离（#99）。
  String inputPrimaryLanguage;
  String? inputSecondaryLanguage;
  bool automatic;
  int shortcutKeyCode;
  String shortcutLabel;
  int shortcutModifiers;

  /// 输入翻译快捷键；默认 ⌃⌥R（键码 15），翻译完成后用译文替换来源输入框中的原文。
  int inputShortcutKeyCode;
  String inputShortcutLabel;
  int inputShortcutModifiers;
  int screenshotShortcutKeyCode;
  String screenshotShortcutLabel;
  int screenshotShortcutModifiers;

  /// 采集文件的根目录；空字符串由原生解析为用户Pictures下的截图目录。
  String screenshotSaveDirectory;

  /// 完整视频GIF导出的采样帧率，以及只缩小不放大的可选像素宽度上限。
  int gifFramesPerSecond;

  /// 实时翻译时是否同步录制；对区域、窗口和全屏目标都生效。
  bool liveRecording;

  /// 区域截图的冻结帧是否包含鼠标指针；默认不含，不影响 MCP 截图与录屏（#105）。
  bool screenshotIncludesCursor;

  /// 区域与全屏录制的鼠标点击特效样式与右键/拖动区分；应用录制不含指针不显示点击（#143）。
  RecordingClickEffect recordingClickEffect;
  bool recordingClickRightDistinct;

  /// 开始录制前的倒计时秒数，取值见 RecordingOptions.delays，默认 0 不延时（#129）。
  int recordingDelay;

  /// 确认截图（回车或双击）时的动作：复制图片或复制并保存（#111）。
  ScreenshotConfirmAction screenshotConfirmAction;

  /// 长截图滚动方式；默认手动，自动时由 App 经辅助功能接口滚动来源窗口（#112）。
  ScrollCaptureMode scrollCaptureMode;

  /// 是否允许本机 MCP 客户端截图；默认关闭，关闭时 App 对所有 MCP 工具返回「MCP 未开启」。
  bool mcpEnabled;

  /// 是否允许本机 MCP 客户端操控电脑；默认关闭，关闭时不列出也不执行无障碍与操作类工具（#140）。
  bool mcpControlEnabled;
  int? gifMaximumWidth;

  /// 视觉偏好与业务设置一同提交，不单独保存第二份配置。
  String glassAppearance;
  double glassOpacity;
  String accentColor;
  bool launchAtLogin;
  final Map<String, String> excludedApps;

  /// 术语表；只对模型服务的翻译模式生效，按目标语言与原文命中后写入请求（#104）。
  final List<GlossaryEntry> glossary;

  /// 翻译、润色、纠错、解释的系统提示词，所有模型服务共用；缺省为 defaultPrompts（#100）。
  final Map<TextMode, String> prompts;

  /// 各处理模式的思考开关，所有模型服务共用，缺省关闭；只对 DeepSeek 与 Anthropic 生效。
  final Map<TextMode, bool> thinking;

  /// 我的贴纸，按添加顺序；文件在 App 数据目录 Stickers/（#103）。
  final List<StickerEntry> stickers;
  String defaultServiceId;
  final List<ServiceConfig> services;

  static const languages = {
    'zh-CN': '简体中文',
    'zh-TW': '繁體中文',
    'en': 'English',
    'ja': '日本語',
    'ko': '한국어',
    'fr': 'Français',
    'de': 'Deutsch',
    'es': 'Español',
    'pt': 'Português',
    'it': 'Italiano',
    'ru': 'Русский',
    'ar': 'العربية',
    'hi': 'हिन्दी',
    'th': 'ไทย',
    'vi': 'Tiếng Việt',
    'id': 'Bahasa Indonesia',
    'nl': 'Nederlands',
    'tr': 'Türkçe',
  };

  /// map 为原生偏好字典；缺省语言取 macOS 首选语言，返回可编辑偏好。
  factory AppSettings.fromMap(Map<Object?, Object?> map) {
    final language = LanguageDirection.systemDefault(
      languageCode: map['systemLanguage'] as String?,
    );
    return AppSettings(
      screenshotToolbar: ScreenshotToolbarPreferences.fromMap(map),
      drawing: DrawingPreferences.fromMap(
        map[PreferenceKeys.screenshotDrawing] as Map?,
      ),
      primaryLanguage:
          map[PreferenceKeys.primaryLanguage] as String? ??
          language.primaryCode,
      secondaryLanguage: map[PreferenceKeys.secondaryLanguage] as String?,
      inputPrimaryLanguage: map[PreferenceKeys.inputPrimaryLanguage] as String?,
      inputSecondaryLanguage:
          map[PreferenceKeys.inputSecondaryLanguage] as String?,
      automatic: map[PreferenceKeys.automatic] as bool? ?? true,
      defaultServiceId:
          map[PreferenceKeys.defaultServiceId] as String? ??
          ServiceConfig.builtinId,
      services: (map[PreferenceKeys.services] as List? ?? [])
          .map(
            (e) => ServiceConfig.fromMap(Map<Object?, Object?>.from(e as Map)),
          )
          .toList(),
      shortcutKeyCode: map[PreferenceKeys.shortcutKeyCode] as int? ?? 17,
      shortcutLabel: map[PreferenceKeys.shortcutLabel] as String? ?? 'T',
      shortcutModifiers: map[PreferenceKeys.shortcutModifiers] as int? ?? 6144,
      inputShortcutKeyCode:
          map[PreferenceKeys.inputShortcutKeyCode] as int? ?? 15,
      inputShortcutLabel:
          map[PreferenceKeys.inputShortcutLabel] as String? ?? 'R',
      inputShortcutModifiers:
          map[PreferenceKeys.inputShortcutModifiers] as int? ?? 6144,
      screenshotShortcutKeyCode:
          map[PreferenceKeys.screenshotShortcutKeyCode] as int? ?? 1,
      screenshotShortcutLabel:
          map[PreferenceKeys.screenshotShortcutLabel] as String? ?? 'S',
      screenshotShortcutModifiers:
          map[PreferenceKeys.screenshotShortcutModifiers] as int? ?? 6144,
      screenshotSaveDirectory:
          map[PreferenceKeys.screenshotSaveDirectory] as String? ?? '',
      gifFramesPerSecond: map[PreferenceKeys.gifFramesPerSecond] as int? ?? 10,
      liveRecording: map[PreferenceKeys.liveRecording] as bool? ?? false,
      screenshotIncludesCursor:
          map[PreferenceKeys.screenshotIncludesCursor] as bool? ?? false,
      recordingClickEffect: RecordingClickEffect.parse(
        map[PreferenceKeys.recordingClickEffect] as String?,
      ),
      recordingClickRightDistinct:
          map[PreferenceKeys.recordingClickRightDistinct] as bool? ?? true,
      recordingDelay: map[PreferenceKeys.recordingDelay] as int? ?? 0,
      screenshotConfirmAction: ScreenshotConfirmAction.parse(
        map[PreferenceKeys.screenshotConfirmAction] as String?,
      ),
      scrollCaptureMode: ScrollCaptureMode.parse(
        map[PreferenceKeys.scrollCaptureMode] as String?,
      ),
      mcpEnabled: map[PreferenceKeys.mcpEnabled] as bool? ?? false,
      mcpControlEnabled:
          map[PreferenceKeys.mcpControlEnabled] as bool? ?? false,
      gifMaximumWidth: map[PreferenceKeys.gifMaximumWidth] as int?,
      glassAppearance:
          map[PreferenceKeys.glassAppearance] as String? ??
          AppearanceModes.system,
      glassOpacity:
          (map[PreferenceKeys.glassOpacity] as num?)?.toDouble() ?? 0.8,
      accentColor:
          map[PreferenceKeys.accentColor] as String? ?? AccentColors.system,
      launchAtLogin: map[PreferenceKeys.launchAtLogin] as bool? ?? false,
      excludedApps: Map<String, String>.from(
        map[PreferenceKeys.excludedApps] as Map? ?? {},
      ),
      glossary: [
        for (final entry in map[PreferenceKeys.glossary] as List? ?? [])
          GlossaryEntry.fromMap(entry as Map),
      ],
      prompts: {
        for (final entry in PreferenceKeys.prompts.entries)
          if (map[entry.value] case final String prompt) entry.key: prompt,
      },
      thinking: {
        for (final entry in PreferenceKeys.thinking.entries)
          if (map[entry.value] case final bool enabled) entry.key: enabled,
      },
      stickers: [
        for (final entry in map[PreferenceKeys.stickers] as List? ?? [])
          StickerEntry.fromMap(entry as Map),
      ],
    );
  }

  /// 无参数；校验可执行的语言方向及系统快捷键，非法配置抛 FormatException。
  void validate() {
    screenshotToolbar.validate();
    for (final sticker in stickers) {
      sticker.validate();
    }
    // 提示词为空时模型无从执行（#100）。
    if (prompts.values.any((prompt) => prompt.trim().isEmpty)) {
      throw const FormatException('提示词不能为空。');
    }
    if (gifFramesPerSecond < 1 ||
        gifFramesPerSecond > 30 ||
        (gifMaximumWidth != null && gifMaximumWidth! < 1)) {
      throw const FormatException('GIF帧率须为1–30，最大宽度须为正整数或留空。');
    }
    // 录制延时只接受录制选项提供的秒数（#129）。
    if (!RecordingOptions.delays.contains(recordingDelay)) {
      throw const FormatException('录制延时须为 0、3、5 或 10 秒。');
    }
    if (!AppearanceModes.values.contains(glassAppearance) ||
        !glassOpacity.isFinite ||
        glassOpacity < 0.2 ||
        glassOpacity > 1) {
      throw const FormatException('外观模式或玻璃透明度无效。');
    }
    if (!AccentColors.values.contains(accentColor) &&
        !AccentColors.isCustom(accentColor)) {
      throw const FormatException('强调色设置无效。');
    }
    for (final service in services) {
      service.validate();
    }
    if (services.map((e) => e.id).toSet().length != services.length ||
        !{
          ServiceConfig.builtinId,
          ServiceConfig.systemId,
          ...services.map((e) => e.id),
        }.contains(defaultServiceId)) {
      throw const FormatException('默认翻译服务不存在或配置标识重复。');
    }
    // 全局翻译与输入翻译两组语言各自满足同一规则（#99）。
    for (final (primary, secondary) in [
      (primaryLanguage, secondaryLanguage),
      (inputPrimaryLanguage, inputSecondaryLanguage),
    ]) {
      if (primary.isEmpty ||
          secondary != null &&
              (secondary.isEmpty ||
                  LanguageDirection.normalize(primary) ==
                      LanguageDirection.normalize(secondary))) {
        throw const FormatException('主要语言和次要语言必须不同。');
      }
    }
    // 同一目标语言下同一术语只能有一种译法，否则请求中会出现互相矛盾的要求。
    if (glossary.any((entry) => entry.term.trim().isEmpty) ||
        glossary.map((entry) => entry.key).toSet().length != glossary.length) {
      throw const FormatException('术语不能为空，且同一目标语言下不能重复。');
    }
    // Shift 单独搭配字母会吞掉普通输入，至少要求一个系统修饰键。
    final shortcuts = [
      (shortcutKeyCode, shortcutLabel, shortcutModifiers),
      (inputShortcutKeyCode, inputShortcutLabel, inputShortcutModifiers),
      (
        screenshotShortcutKeyCode,
        screenshotShortcutLabel,
        screenshotShortcutModifiers,
      ),
    ];
    for (final (code, label, modifiers) in shortcuts) {
      // ShortcutKeys 与 Swift 注册校验共用键码、修饰键掩码与文案（#131）。
      if (code < 0 ||
          code > ShortcutKeys.maxKeyCode ||
          code == ShortcutKeys.escape ||
          label.isEmpty ||
          modifiers & ShortcutKeys.required == 0 ||
          modifiers & ~ShortcutKeys.allowed != 0) {
        throw const FormatException(ShortcutKeys.invalidMessage);
      }
    }
    // 三个全局快捷键在同一注册事务中生效，组合（键码与修饰键）不能重复。
    final combinations = {
      for (final (code, _, modifiers) in shortcuts) (code, modifiers),
    };
    if (combinations.length != shortcuts.length) {
      throw const FormatException('翻译、输入翻译与截图快捷键不能相同。');
    }
    // 全局快捷键独占注册，落在有工具的截图工具栏格位上会让该格在截图编辑中无法触发；两侧修改都在此拒绝（#141）。
    for (final MapEntry(key: slot, value: purpose)
        in globalShortcutSlots.entries) {
      final action = screenshotToolbar.actionAt(slot.modifiers, slot.digit);
      if (action != null) {
        throw FormatException(
          '$purpose快捷键与截图工具栏「${ScreenshotActions.labels[action]}」'
          '（${ToolbarModifiers.label(slot.modifiers)}${slot.digit}）相同，请换一个组合或移动该工具。',
        );
      }
    }
  }

  /// 无参数；返回落在截图工具栏网格格位上的全局快捷键：格位（修饰键与数字）到用途名称（#141）。
  Map<({int modifiers, int digit}), String> get globalShortcutSlots => {
    for (final (purpose, code, modifiers) in [
      ('全局翻译', shortcutKeyCode, shortcutModifiers),
      ('输入翻译', inputShortcutKeyCode, inputShortcutModifiers),
      ('区域截图', screenshotShortcutKeyCode, screenshotShortcutModifiers),
    ])
      ?ToolbarGrid.slotOfCarbon(code, modifiers): purpose,
  };

  /// 无参数；返回可经 MethodChannel 和 UserDefaults 存储的标量字典。
  Map<String, Object> toMap() => {
    ...screenshotToolbar.toMap(),
    PreferenceKeys.screenshotDrawing: drawing.toMap(),
    PreferenceKeys.defaultServiceId: defaultServiceId,
    PreferenceKeys.services: services.map((e) => e.toMap()).toList(),
    PreferenceKeys.primaryLanguage: primaryLanguage,
    // 完整偏好字典通过 UserDefaults 覆盖保存；省略未设置项，避免存储不支持的 null。
    PreferenceKeys.secondaryLanguage: ?secondaryLanguage,
    PreferenceKeys.inputPrimaryLanguage: inputPrimaryLanguage,
    PreferenceKeys.inputSecondaryLanguage: ?inputSecondaryLanguage,
    PreferenceKeys.automatic: automatic,
    PreferenceKeys.shortcutKeyCode: shortcutKeyCode,
    PreferenceKeys.shortcutLabel: shortcutLabel,
    PreferenceKeys.shortcutModifiers: shortcutModifiers,
    PreferenceKeys.inputShortcutKeyCode: inputShortcutKeyCode,
    PreferenceKeys.inputShortcutLabel: inputShortcutLabel,
    PreferenceKeys.inputShortcutModifiers: inputShortcutModifiers,
    PreferenceKeys.screenshotShortcutKeyCode: screenshotShortcutKeyCode,
    PreferenceKeys.screenshotShortcutLabel: screenshotShortcutLabel,
    PreferenceKeys.screenshotShortcutModifiers: screenshotShortcutModifiers,
    PreferenceKeys.screenshotSaveDirectory: screenshotSaveDirectory,
    PreferenceKeys.gifFramesPerSecond: gifFramesPerSecond,
    PreferenceKeys.liveRecording: liveRecording,
    PreferenceKeys.screenshotIncludesCursor: screenshotIncludesCursor,
    PreferenceKeys.recordingClickEffect: recordingClickEffect.name,
    PreferenceKeys.recordingClickRightDistinct: recordingClickRightDistinct,
    PreferenceKeys.recordingDelay: recordingDelay,
    PreferenceKeys.screenshotConfirmAction: screenshotConfirmAction.name,
    PreferenceKeys.scrollCaptureMode: scrollCaptureMode.name,
    PreferenceKeys.mcpEnabled: mcpEnabled,
    PreferenceKeys.mcpControlEnabled: mcpControlEnabled,
    PreferenceKeys.gifMaximumWidth: ?gifMaximumWidth,
    PreferenceKeys.glassAppearance: glassAppearance,
    PreferenceKeys.glassOpacity: glassOpacity,
    PreferenceKeys.accentColor: accentColor,
    PreferenceKeys.launchAtLogin: launchAtLogin,
    PreferenceKeys.excludedApps: excludedApps,
    PreferenceKeys.glossary: [for (final entry in glossary) entry.toMap()],
    for (final entry in PreferenceKeys.prompts.entries)
      entry.value: prompts[entry.key]!,
    for (final entry in PreferenceKeys.thinking.entries)
      entry.value: thinking[entry.key]!,
    PreferenceKeys.stickers: [for (final sticker in stickers) sticker.toMap()],
  };

  /// 无参数；返回当前主要/次要语言决定的翻译方向规则。
  LanguageDirection get direction => LanguageDirection(
    primaryCode: primaryLanguage,
    secondaryCode: secondaryLanguage,
  );

  /// 无参数；返回输入翻译快捷键使用的翻译方向规则（#99）。
  LanguageDirection get inputDirection => LanguageDirection(
    primaryCode: inputPrimaryLanguage,
    secondaryCode: inputSecondaryLanguage,
  );
}
