import '../screenshot/drawing_preferences.dart';
import '../common/constants/appearance_modes.dart';
import '../common/constants/font_sets.dart';
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

class AppSettings {
  AppSettings({
    required this.primaryLanguage,
    this.secondaryLanguage,
    String? inputPrimaryLanguage,
    String? inputSecondaryLanguage,
    this.automatic = true,
    this.shortcut = ShortcutKeys.translate,
    this.inputShortcut = ShortcutKeys.input,
    this.screenshotShortcut = ShortcutKeys.screenshot,
    this.screenshotSaveDirectory = '',
    this.gifFramesPerSecond = 10,
    this.liveRecording = false,
    this.screenshotIncludesCursor = false,
    this.recordingClickEffectEnabled = false,
    this.recordingClickEffect = RecordingClickEffect.optical,
    this.recordingDelay = 0,
    this.screenshotConfirmAction = ScreenshotConfirmAction.copy,
    this.scrollCaptureMode = ScrollCaptureMode.manual,
    this.mcpEnabled = false,
    this.mcpControlEnabled = false,
    this.gifMaximumWidth,
    this.glassAppearance = AppearanceModes.system,
    this.glassOpacity = 0.8,
    this.fontSet = FontSet.fallback,
    this.accentColor = AccentColors.system,
    this.accentForeground = AccentForegrounds.auto,
    this.launchAtLogin = false,
    Map<String, String>? excludedApps,
    List<GlossaryEntry>? glossary,
    Map<TextMode, String>? prompts,
    Map<TextMode, bool>? thinking,
    List<StickerEntry>? stickers,
    this.defaultServiceId = ServiceConfig.systemId,
    List<ServiceConfig>? services,
    ScreenshotToolbarPreferences? screenshotToolbar,
    DrawingPreferences? drawing,
  }) : inputPrimaryLanguage = inputPrimaryLanguage ?? primaryLanguage,
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

  String inputPrimaryLanguage;
  String? inputSecondaryLanguage;
  bool automatic;
  Shortcut shortcut;
  Shortcut inputShortcut;
  Shortcut screenshotShortcut;

  String screenshotSaveDirectory;

  int gifFramesPerSecond;

  bool liveRecording;

  bool screenshotIncludesCursor;

  bool recordingClickEffectEnabled;
  RecordingClickEffect recordingClickEffect;

  int recordingDelay;

  ScreenshotConfirmAction screenshotConfirmAction;

  ScrollCaptureMode scrollCaptureMode;

  bool mcpEnabled;

  bool mcpControlEnabled;
  int? gifMaximumWidth;

  String glassAppearance;
  double glassOpacity;

  FontSet fontSet;
  String accentColor;
  String accentForeground;
  bool launchAtLogin;
  final Map<String, String> excludedApps;

  final List<GlossaryEntry> glossary;

  final Map<TextMode, String> prompts;

  final Map<TextMode, bool> thinking;

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
          ServiceConfig.systemId,
      services: (map[PreferenceKeys.services] as List? ?? [])
          .map(
            (e) => ServiceConfig.fromMap(Map<Object?, Object?>.from(e as Map)),
          )
          .toList(),
      shortcut:
          ShortcutKeys.parse(map[PreferenceKeys.shortcut] as Map?) ??
          ShortcutKeys.translate,
      inputShortcut:
          ShortcutKeys.parse(map[PreferenceKeys.inputShortcut] as Map?) ??
          ShortcutKeys.input,
      screenshotShortcut:
          ShortcutKeys.parse(map[PreferenceKeys.screenshotShortcut] as Map?) ??
          ShortcutKeys.screenshot,
      screenshotSaveDirectory:
          map[PreferenceKeys.screenshotSaveDirectory] as String? ?? '',
      gifFramesPerSecond: map[PreferenceKeys.gifFramesPerSecond] as int? ?? 10,
      liveRecording: map[PreferenceKeys.liveRecording] as bool? ?? false,
      screenshotIncludesCursor:
          map[PreferenceKeys.screenshotIncludesCursor] as bool? ?? false,
      recordingClickEffectEnabled:
          map[PreferenceKeys.recordingClickEffectEnabled] as bool? ?? false,
      recordingClickEffect: RecordingClickEffect.parse(
        map[PreferenceKeys.recordingClickEffect] as String?,
      ),
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
      fontSet: FontSet.parse(map[PreferenceKeys.fontSet]),
      accentColor:
          map[PreferenceKeys.accentColor] as String? ?? AccentColors.system,
      accentForeground:
          map[PreferenceKeys.accentForeground] as String? ??
          AccentForegrounds.auto,
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

  void validate() {
    screenshotToolbar.validate();
    for (final sticker in stickers) {
      sticker.validate();
    }
    if (prompts.values.any((prompt) => prompt.trim().isEmpty)) {
      throw const FormatException('提示词不能为空。');
    }
    if (gifFramesPerSecond < 1 ||
        gifFramesPerSecond > 30 ||
        (gifMaximumWidth != null && gifMaximumWidth! < 1)) {
      throw const FormatException('GIF帧率须为1–30，最大宽度须为正整数或留空。');
    }
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
    if (!AccentForegrounds.isValid(accentForeground)) {
      throw const FormatException('前景色设置无效。');
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
    if (glossary.any((entry) => entry.term.trim().isEmpty) ||
        glossary.map((entry) => entry.key).toSet().length != glossary.length) {
      throw const FormatException('术语不能为空，且同一目标语言下不能重复。');
    }
    final shortcuts = [shortcut, inputShortcut, screenshotShortcut];
    for (final (:key, :modifiers, :label) in shortcuts) {
      if (key.isEmpty ||
          key == ShortcutKeys.escape ||
          label.isEmpty ||
          modifiers & ShortcutModifiers.required == 0 ||
          modifiers & ~ShortcutModifiers.allowed != 0) {
        throw const FormatException(ShortcutKeys.invalidMessage);
      }
    }
    final combinations = {
      for (final (:key, :modifiers, label: _) in shortcuts) (key, modifiers),
    };
    if (combinations.length != shortcuts.length) {
      throw const FormatException('翻译、输入翻译与截图快捷键不能相同。');
    }
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

  Map<({int modifiers, int digit}), String> get globalShortcutSlots => {
    for (final (purpose, (:key, :modifiers, label: _)) in [
      ('全局翻译', shortcut),
      ('输入翻译', inputShortcut),
      ('区域截图', screenshotShortcut),
    ])
      ?ToolbarGrid.slotOf(key, modifiers): purpose,
  };

  Map<String, Object> toMap() => {
    ...screenshotToolbar.toMap(),
    PreferenceKeys.screenshotDrawing: drawing.toMap(),
    PreferenceKeys.defaultServiceId: defaultServiceId,
    PreferenceKeys.services: services.map((e) => e.toMap()).toList(),
    PreferenceKeys.primaryLanguage: primaryLanguage,
    PreferenceKeys.secondaryLanguage: ?secondaryLanguage,
    PreferenceKeys.inputPrimaryLanguage: inputPrimaryLanguage,
    PreferenceKeys.inputSecondaryLanguage: ?inputSecondaryLanguage,
    PreferenceKeys.automatic: automatic,
    PreferenceKeys.shortcut: ShortcutKeys.encode(shortcut),
    PreferenceKeys.inputShortcut: ShortcutKeys.encode(inputShortcut),
    PreferenceKeys.screenshotShortcut: ShortcutKeys.encode(screenshotShortcut),
    PreferenceKeys.screenshotSaveDirectory: screenshotSaveDirectory,
    PreferenceKeys.gifFramesPerSecond: gifFramesPerSecond,
    PreferenceKeys.liveRecording: liveRecording,
    PreferenceKeys.screenshotIncludesCursor: screenshotIncludesCursor,
    PreferenceKeys.recordingClickEffectEnabled: recordingClickEffectEnabled,
    PreferenceKeys.recordingClickEffect: recordingClickEffect.name,
    PreferenceKeys.recordingDelay: recordingDelay,
    PreferenceKeys.screenshotConfirmAction: screenshotConfirmAction.name,
    PreferenceKeys.scrollCaptureMode: scrollCaptureMode.name,
    PreferenceKeys.mcpEnabled: mcpEnabled,
    PreferenceKeys.mcpControlEnabled: mcpControlEnabled,
    PreferenceKeys.gifMaximumWidth: ?gifMaximumWidth,
    PreferenceKeys.glassAppearance: glassAppearance,
    PreferenceKeys.glassOpacity: glassOpacity,
    PreferenceKeys.fontSet: fontSet.name,
    PreferenceKeys.accentColor: accentColor,
    PreferenceKeys.accentForeground: accentForeground,
    PreferenceKeys.launchAtLogin: launchAtLogin,
    PreferenceKeys.excludedApps: excludedApps,
    PreferenceKeys.glossary: [for (final entry in glossary) entry.toMap()],
    for (final entry in PreferenceKeys.prompts.entries)
      entry.value: prompts[entry.key]!,
    for (final entry in PreferenceKeys.thinking.entries)
      entry.value: thinking[entry.key]!,
    PreferenceKeys.stickers: [for (final sticker in stickers) sticker.toMap()],
  };

  LanguageDirection get direction => LanguageDirection(
    primaryCode: primaryLanguage,
    secondaryCode: secondaryLanguage,
  );

  LanguageDirection get inputDirection => LanguageDirection(
    primaryCode: inputPrimaryLanguage,
    secondaryCode: inputSecondaryLanguage,
  );
}
