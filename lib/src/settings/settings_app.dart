import 'dart:async';
import 'dart:io';

import '../common/widgets/line_icon.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/preference_keys.dart';
import '../common/constants/drawing_metrics.dart';
import '../common/constants/appearance_modes.dart';
import '../common/constants/method_names.dart';
import '../common/constants/toolbar_grid.dart';
import '../common/constants/channel_names.dart';
import '../common/constants/error_codes.dart';
import '../common/constants/screenshot_enums.dart';
import '../common/constants/text_mode.dart';
import '../common/utils/shortcut_tokens.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';
import 'package:motor/motor.dart';

import '../common/widgets/app_motion.dart';
import '../common/widgets/window_drag_area.dart';
import '../common/widgets/native_glass.dart';

import 'app_settings.dart';
import 'click_effect_player.dart';
import 'prompt_editor.dart';
import 'sticker_upload_dialog.dart';
import '../screenshot/drawing_controls.dart';
import '../screenshot/stickers.dart';
import '../translation/glossary.dart';
import 'glossary_editor.dart';
import 'mcp_platforms.dart';
import 'mcp_settings_page.dart';
import 'service_config.dart';
import 'screenshot_toolbar_editor.dart';
import 'service_editor.dart';
import '../common/constants/app_colors.dart';

enum SettingsPage {
  general,
  personalization,
  languages,
  services,
  shortcuts,
  exclusions,
  screenshotSave,
  recording,
  screenshotActions,
  stickers,
  toolbar,
  mcp,
}

class SettingsApp extends StatelessWidget {
  const SettingsApp({
    super.key,
    this.createMcpService = McpSettingsPage.defaultService,
  });

  final McpPlatformService Function(String helperPath) createMcpService;

  @override
  Widget build(BuildContext context) => NativeGlassApp(
    title: '权限与启动',
    home: NativeGlassWindowPage(
      child: _SettingsPage(createMcpService: createMcpService),
    ),
  );
}

class _SettingsPage extends StatefulWidget {
  const _SettingsPage({required this.createMcpService});

  final McpPlatformService Function(String helperPath) createMcpService;
  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel(ChannelNames.settings);
  AppSettings? _settings;
  final _gifMaximumWidth = TextEditingController();
  Map<Object?, Object?> _status = {};
  String? _message;
  bool _saving = false;
  Completer<bool>? _saveCompletion;

  String? _recordingTarget;
  bool _failed = false;
  bool _dirty = false;
  bool _conflicted = false;
  int _revision = 0;
  int _editGeneration = 0;
  bool _adjustingOpacity = false;
  Set<String> _credentialIds = {};
  final Map<String, Map<String, String>?> _credentials = {};
  SettingsPage _page = SettingsPage.general;

  String? _languagePackStatus;
  bool? _historyRecording;
  bool _savingHistoryRecording = false;
  bool? _screenshotHistoryRecording;
  bool _savingScreenshotHistoryRecording = false;

  static const List<NativeGlassSidebarSection<SettingsPage>> _sidebarSections =
      [
        (
          title: '通用',
          icon: LucideIcons.sliders,
          value: null,
          children: {
            SettingsPage.general: '权限与启动',
            SettingsPage.personalization: '个性化',
          },
        ),
        (
          title: '翻译',
          icon: LucideIcons.languages,
          value: null,
          children: {
            SettingsPage.languages: '语言与服务',
            SettingsPage.services: '服务列表',
            SettingsPage.shortcuts: '快捷键',
            SettingsPage.exclusions: '排除应用',
          },
        ),
        (
          title: '截图',
          icon: LucideIcons.scan,
          value: null,
          children: {
            SettingsPage.screenshotSave: '保存与导出',
            SettingsPage.recording: '录制',
            SettingsPage.screenshotActions: '操作',
            SettingsPage.stickers: '贴纸',
            SettingsPage.toolbar: '工具栏',
          },
        ),
        (
          title: 'MCP',
          icon: LucideIcons.network,
          value: SettingsPage.mcp,
          children: {},
        ),
      ];

  static String _pageTitle(SettingsPage page) {
    for (final section in _sidebarSections) {
      if (section.value == page) return section.title;
      final title = section.children[page];
      if (title != null) return title;
    }
    throw StateError('侧边栏缺少子页 $page');
  }

  void _openPage(SettingsPage page) {
    setState(() {
      _page = page;
      _recordingTarget = null;
      if (!_dirty && !_conflicted) {
        _message = null;
        _failed = false;
      }
    });
    unawaited(_syncWindowTitle(_pageTitle(page)));
    if (page == SettingsPage.general) _checkLanguagePacks();
    if (page == SettingsPage.toolbar) _loadSystemShortcuts();
  }

  Future<void> _syncWindowTitle(String title) async {
    try {
      await _channel.invokeMethod<void>(MethodNames.setWindowTitle, {
        'title': title,
      });
    } on MissingPluginException catch (_) {
    } on PlatformException catch (_) {}
  }

  Set<({int modifiers, int digit})> _systemShortcutSlots = const {};

  Future<void> _loadSystemShortcuts() async {
    final entries =
        await _channel.invokeListMethod<Map<Object?, Object?>>(
          MethodNames.systemShortcuts,
        ) ??
        const [];
    if (!mounted) return;
    setState(
      () => _systemShortcutSlots = {
        for (final entry in entries)
          ?ToolbarGrid.slotOfCocoa(
            entry['keyCode'] as int,
            entry['modifiers'] as int,
          ),
      },
    );
  }

  Future<void> _checkLanguagePacks() async {
    if (_languagePackStatus != null) {
      setState(() => _languagePackStatus = null);
    }
    String status;
    try {
      status = (await _channel.invokeMethod<String>(
        MethodNames.checkSystemTranslation,
      ))!;
    } on PlatformException catch (error) {
      status = error.message!;
    }
    if (mounted) setState(() => _languagePackStatus = status);
  }

  bool _inputLanguages = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler((call) async {
      if (call.method == MethodNames.refreshSettings) await _load();
    });
    _load();
    _checkLanguagePacks();
    _channel.invokeMethod<String>(MethodNames.stickerDirectory).then((path) {
      if (mounted) setState(() => _stickerDirectory = path);
    });
  }

  String? _stickerDirectory;

  Future<void> _addSticker() async {
    final picked = await _channel.invokeMapMethod<String, Object?>(
      MethodNames.importStickerImage,
    );
    if (picked == null || !mounted) return;
    final bytes = picked['bytes'] as Uint8List;
    final size = await showDialog<(double, double)>(
      context: context,
      barrierDismissible: false,
      builder: (_) => StickerUploadDialog(
        bytes: bytes,
        pixelWidth: picked['width'] as int,
        pixelHeight: picked['height'] as int,
      ),
    );
    if (size == null || !mounted) return;
    final id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    await _channel.invokeMethod<String>(MethodNames.saveSticker, {
      'id': id,
      'bytes': bytes,
    });
    if (!mounted) return;
    _edit(
      () => _settings!.stickers.add(
        StickerEntry(id: id, width: size.$1, height: size.$2),
      ),
    );
  }

  void _removeSticker(StickerEntry sticker) {
    _edit(
      () => _settings!.stickers.removeWhere((item) => item.id == sticker.id),
    );
    unawaited(
      _channel.invokeMethod<void>(MethodNames.deleteSticker, {
        'id': sticker.id,
      }),
    );
  }

  Future<void> _confirmRemoveSticker(StickerEntry sticker) async {
    final confirmed = await NativeGlassDialog.confirm(
      context: context,
      title: '删除贴纸',
      message: '确定删除这张贴纸吗？本地贴纸文件将被永久移除，且无法撤销。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    _removeSticker(sticker);
  }

  @override
  void dispose() {
    _gifMaximumWidth.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    final status = await _channel.invokeMapMethod<Object?, Object?>(
      MethodNames.systemStatus,
    );
    if (mounted) setState(() => _status = status!);
  }

  Future<void> _refreshHistoryRecording() async {
    bool? historyRecording;
    bool? screenshotRecording;
    try {
      historyRecording = await _channel.invokeMethod<bool>(
        MethodNames.historyRecording,
      );
    } on MissingPluginException catch (_) {
    } on PlatformException catch (_) {}
    try {
      screenshotRecording = await _channel.invokeMethod<bool>(
        MethodNames.screenshotHistoryRecording,
      );
    } on MissingPluginException catch (_) {
    } on PlatformException catch (_) {}
    if (!mounted) return;
    setState(() {
      if (historyRecording != null) _historyRecording = historyRecording;
      if (screenshotRecording != null) {
        _screenshotHistoryRecording = screenshotRecording;
      }
    });
  }

  Future<void> _setHistoryRecording(bool enabled) async {
    setState(() {
      _savingHistoryRecording = true;
      _failed = false;
      _message = null;
    });
    try {
      await _channel.invokeMethod<void>(MethodNames.setHistoryRecording, {
        'enabled': enabled,
      });
      if (!mounted) return;
      setState(() => _historyRecording = enabled);
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _message = error.message ?? '无法保存记录设置';
        _failed = true;
      });
    } finally {
      if (mounted) setState(() => _savingHistoryRecording = false);
    }
  }

  Future<void> _setScreenshotHistoryRecording(bool enabled) async {
    setState(() {
      _savingScreenshotHistoryRecording = true;
      _failed = false;
      _message = null;
    });
    try {
      await _channel.invokeMethod<void>(
        MethodNames.setScreenshotHistoryRecording,
        {'enabled': enabled},
      );
      if (!mounted) return;
      setState(() => _screenshotHistoryRecording = enabled);
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _message = error.message ?? '无法保存记录设置';
        _failed = true;
      });
    } finally {
      if (mounted) setState(() => _savingScreenshotHistoryRecording = false);
    }
  }

  Future<void> _load() async {
    try {
      final map = (await _channel.invokeMapMethod<Object?, Object?>(
        MethodNames.getSettings,
      ))!;
      await _refreshStatus();
      await _refreshHistoryRecording();
      if (!mounted) return;
      if ((map['revision'] as int) < _revision) return;
      if (_dirty) {
        if (map['revision'] != _revision) {
          setState(() {
            _conflicted = true;
            _failed = true;
            _message = '设置已在菜单中更新。重新加载将放弃当前未保存的编辑。';
          });
        }
        return;
      }
      setState(() {
        _revision = map['revision'] as int;
        _conflicted = false;
        _settings = AppSettings.fromMap(map);
        _gifMaximumWidth.text = _settings!.gifMaximumWidth?.toString() ?? '';
        _credentialIds = Set<String>.from(
          map[MethodNames.credentialIds] as List? ?? [],
        );
        _credentials.clear();
        _message = map['error'] as String?;
        _failed = _message != null;
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
    }
  }

  Widget _permissionState({
    required bool granted,
    required VoidCallback onGrant,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      NativeGlassStatus(granted: granted),
      if (!granted) ...[
        const SizedBox(width: GlassMetrics.space12),
        _grantButton(label: '授权…', onPressed: onGrant),
      ],
    ],
  );

  Widget _grantButton({
    required String label,
    required VoidCallback onPressed,
  }) => FilledButton(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      minimumSize: const Size(0, GlassMetrics.buttonHeight),
      padding: const EdgeInsets.symmetric(horizontal: GlassMetrics.space12),
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
      ),
    ),
    child: Text(label),
  );

  String? _foregroundWarning(BuildContext context, AppSettings settings) {
    final foreground = AccentForegrounds.colorOf(settings.accentForeground);
    if (foreground == null) return null;
    final ratio = NativeGlassTheme.contrastRatio(
      foreground,
      NativeGlassTheme.accentOf(context),
    );
    if (ratio >= 4.5) return null;
    return '与当前强调色对比度 ${ratio.toStringAsFixed(1)}:1，低于 4.5:1，可能看不清';
  }

  Future<void> _previewAppearance(Map<String, Object>? fields) =>
      _channel.invokeMethod<void>(MethodNames.previewAppearance, fields);

  Future<bool> _save() async {
    if (_saving) return _saveCompletion!.future;
    if (!_dirty || _conflicted || _adjustingOpacity) {
      return !_dirty && !_conflicted;
    }
    final completion = Completer<bool>();
    _saveCompletion = completion;
    setState(() {
      _saving = true;
      _failed = false;
      _message = null;
    });
    try {
      while (_dirty && !_conflicted && !_adjustingOpacity) {
        _settings!.validate();
        final generation = _editGeneration;
        final preferences = AppSettings.fromMap(_settings!.toMap()).toMap();
        final credentials = _credentials.map(
          (id, value) => MapEntry(
            id,
            value == null ? null : Map<String, String>.from(value),
          ),
        );
        final saved = (await _channel.invokeMapMethod<Object?, Object?>(
          MethodNames.saveSettings,
          {...preferences, 'revision': _revision, 'credentials': credentials},
        ))!;
        if (!mounted) return false;
        setState(() {
          _revision = saved['revision'] as int;
          _credentialIds = Set<String>.from(
            saved[MethodNames.credentialIds] as List? ?? [],
          );
          for (final entry in credentials.entries) {
            if (_credentials.containsKey(entry.key) &&
                mapEquals(_credentials[entry.key], entry.value)) {
              _credentials.remove(entry.key);
            }
          }
          if (generation == _editGeneration) {
            _settings = AppSettings.fromMap(saved);
            _dirty = false;
          }
          if (!_conflicted) {
            _message = null;
          }
        });
        await _refreshStatus();
      }
    } catch (error) {
      if (!mounted) return false;
      unawaited(_previewAppearance(null));
      setState(() {
        if (error is PlatformException &&
            error.code == ErrorCodes.settingsConflict) {
          _conflicted = true;
        }
        _message = switch (error) {
          PlatformException(:final message) => message,
          FormatException(:final message) => message,
          _ => '自动保存失败，请重试。',
        };
        _failed = true;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
      completion.complete(!_dirty && !_conflicted);
    }
    return !_dirty && !_conflicted;
  }

  Future<void> _recordShortcut(
    String target,
    void Function(
      AppSettings settings,
      int keyCode,
      int modifiers,
      String label,
    )
    apply,
  ) async {
    if (_recordingTarget != null) return;
    setState(() => _recordingTarget = target);
    try {
      final key = await _channel.invokeMapMethod<Object?, Object?>(
        MethodNames.recordShortcut,
      );
      if (!mounted || key == null || _recordingTarget != target) return;
      _edit(
        () => apply(
          _settings!,
          key['keyCode'] as int,
          key['modifiers'] as int,
          key['label'] as String,
        ),
      );
    } on PlatformException catch (error) {
      if (mounted && _recordingTarget == target) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
    } finally {
      if (mounted && _recordingTarget == target) {
        setState(() => _recordingTarget = null);
      }
    }
  }

  Future<void> _addExclusion() async {
    final app = await _channel.invokeMapMethod<String, String>(
      MethodNames.chooseExcludedApp,
    );
    if (app == null || !mounted) return;
    _edit(() => _settings!.excludedApps[app['id']!] = app['name']!);
  }

  Future<void> _chooseScreenshotDirectory() async {
    final path = await _channel.invokeMethod<String>(
      MethodNames.chooseScreenshotDirectory,
    );
    if (!mounted || path == null) return;
    _edit(() => _settings!.screenshotSaveDirectory = path);
  }

  Future<void> _requestScreenAccess() async {
    try {
      final status = await _channel.invokeMapMethod<Object?, Object?>(
        MethodNames.requestScreenAccess,
      );
      if (!mounted || status == null) return;
      setState(() {
        _status = {..._status, ...status};
        _message = status['screenAccess'] == true
            ? '已获得屏幕录制权限。'
            : '请在系统设置中允许 TranSnap 的屏幕录制。';
        _failed = status['screenAccess'] != true;
      });
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _message = error.message;
          _failed = true;
        });
      }
    }
  }

  void _edit(VoidCallback change, {bool submit = true}) {
    setState(() {
      change();
      _editGeneration += 1;
      _dirty = true;
    });
    if (submit) _save();
  }

  Future<void> _confirmDeleteService(ServiceConfig service) async {
    final confirmed = await NativeGlassDialog.confirm(
      context: context,
      title: '删除翻译服务',
      message: '确定删除“${service.displayName}”吗？关联的钥匙串凭据将一并清除，且无法撤销。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    _edit(() {
      _settings!.services.remove(service);
      _credentials[service.id] = null;
      if (_settings!.defaultServiceId == service.id) {
        _settings!.defaultServiceId = ServiceConfig.systemId;
      }
    });
  }

  Future<void> _editService([ServiceConfig? config]) async {
    final draft =
        await showDialog<
          ({ServiceConfig config, Map<String, String> credentials})
        >(
          context: context,
          barrierDismissible: false,
          builder: (_) => ServiceEditor(
            config: config,
            credentials: _credentials[config?.id] ?? const {},
            hasCredentials: _credentialIds.contains(config?.id),
          ),
        );
    if (draft == null || !mounted) return;
    _edit(() {
      final index = _settings!.services.indexWhere(
        (e) => e.id == draft.config.id,
      );
      if (index < 0) {
        _settings!.services.add(draft.config);
      } else {
        _settings!.services[index] = draft.config;
      }
      if (draft.credentials.isNotEmpty) {
        _credentials[draft.config.id] = draft.credentials;
      }
    });
  }

  Future<void> _manageGlossary() => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => GlossaryManager(
      glossary: _settings!.glossary,
      defaultLanguage: _settings!.primaryLanguage,
      channel: _channel,
      onImport: _importGlossary,
      onChanged: (entries) => _edit(
        () => _settings!.glossary
          ..clear()
          ..addAll(entries),
      ),
    ),
  );

  Future<void> _importGlossary(List<GlossaryEntry> entries) async {
    if (_saving) await _save();
    if (!mounted) return;
    final previous = [..._settings!.glossary];
    final wasDirty = _dirty;
    _edit(
      () => _settings!.glossary
        ..clear()
        ..addAll(entries),
      submit: false,
    );
    if (!await _save()) {
      if (!mounted) return;
      setState(() {
        _settings!.glossary
          ..clear()
          ..addAll(previous);
        _dirty = wasDirty;
      });
      throw FormatException(
        _conflicted ? '设置已在其他窗口修改，请关闭设置窗口后重新打开再导入。' : _message ?? '导入保存失败，请重试。',
      );
    }
  }

  Future<void> _editPrompts() async {
    final saved =
        await showDialog<
          ({Map<TextMode, String> prompts, Map<TextMode, bool> thinking})
        >(
          context: context,
          barrierDismissible: false,
          builder: (_) => PromptEditor(
            prompts: _settings!.prompts,
            thinking: _settings!.thinking,
          ),
        );
    if (saved == null || !mounted) return;
    _edit(() {
      _settings!.prompts.addAll(saved.prompts);
      _settings!.thinking.addAll(saved.thinking);
    });
  }

  Widget _language(
    String label,
    String value,
    ValueChanged<String> onChanged, {
    bool optional = false,
    String? caption,
  }) {
    final languages = {
      if (optional) '': '不设置',
      ...AppSettings.languages,
      if (value.isNotEmpty && !AppSettings.languages.containsKey(value))
        value: value,
    };
    return NativeGlassDropdown<String>(
      label: label,
      caption: caption,
      value: value,
      items: languages,
      onChanged: (v) => _edit(() => onChanged(v)),
    );
  }

  List<Widget> _shortcutBlock({
    required String title,
    required int code,
    required String label,
    required void Function(AppSettings, int, int, String) apply,
    Widget? leading,
  }) {
    final isThisRecording = _recordingTarget == title;
    final tokens = shortcutTokens(code, label);
    return [
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          children: [
            if (leading != null) ...[
              leading,
              const SizedBox(width: GlassMetrics.rowIconGap),
            ],
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: GlassMetrics.space12),
            NativeGlassSurface(
              material: true,
              busy: isThisRecording,
              child: OutlinedButton.icon(
                key: ValueKey(title),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(
                    GlassMetrics.shortcutButtonMinWidth,
                    GlassMetrics.buttonHeight,
                  ),
                ),
                onPressed: _recordingTarget != null
                    ? null
                    : () => _recordShortcut(title, apply),
                icon: const LineIcon(LucideIcons.keyboard),
                label: isThisRecording
                    ? const Text('请按下组合键，Esc 取消…')
                    : NativeGlassKeycaps(tokens: tokens),
              ),
            ),
          ],
        ),
      ),
    ];
  }

  String? get _gifWidthError {
    final text = _gifMaximumWidth.text.trim();
    if (text.isEmpty) return null;
    final parsed = int.tryParse(text);
    if (parsed == null || parsed <= 0) {
      return '请输入大于 0 的整数像素宽度，留空表示不限制。';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings == null) {
      return Scaffold(
        body: Center(
          child: _message == null
              ? const CircularProgressIndicator()
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      NativeGlassBanner(message: _message!, isError: true),
                      const SizedBox(height: GlassMetrics.space12),
                      NativeGlassSurface(
                        material: true,
                        child: FilledButton(
                          onPressed: _load,
                          child: const Text('重新加载'),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      );
    }
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NativeGlassSidebar<SettingsPage>(
            key: const ValueKey('settings-sidebar'),
            value: _page,
            sections: _sidebarSections,
            topPadding: GlassMetrics.sidebarTopInset,
            onChanged: _openPage,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                WindowDragArea(
                  channel: _channel,
                  child: const SizedBox(height: GlassMetrics.titlebarHeight),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    GlassMetrics.pagePadding,
                    GlassMetrics.space8,
                    GlassMetrics.pagePadding,
                    GlassMetrics.space16,
                  ),
                  child: Text(
                    _pageTitle(_page),
                    style: const TextStyle(
                      fontSize: GlassMetrics.pageTitleFont,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(
                      GlassMetrics.pagePadding,
                      0,
                      GlassMetrics.pagePadding,
                      GlassMetrics.pagePadding,
                    ),
                    children: [
                      _SubpageReveal(
                        key: ValueKey(_page),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_page == SettingsPage.general) ...[
                              NativeGlassGroup(
                                title: '权限',
                                children: [
                                  NativeGlassSettingRow(
                                    title: '辅助功能',
                                    caption: '用于读取选中文字',
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.shieldCheck,
                                    ),
                                    child: _permissionState(
                                      granted: _status['accessibility'] == true,
                                      onGrant: () =>
                                          _channel.invokeMethod<void>(
                                            MethodNames.openAccessibility,
                                          ),
                                    ),
                                  ),
                                  NativeGlassSettingRow(
                                    key: const ValueKey('屏幕录制权限'),
                                    title: '屏幕录制',
                                    caption: '截图、录屏与实时翻译需要',
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.monitor,
                                    ),
                                    child: _permissionState(
                                      granted: _status['screenAccess'] == true,
                                      onGrant: _requestScreenAccess,
                                    ),
                                  ),
                                  NativeGlassSettingRow(
                                    key: const ValueKey('离线翻译语言'),
                                    title: 'Apple 离线翻译语言包',
                                    caption: _languagePackStatus ?? '正在检查语言包…',
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.languages,
                                    ),
                                    child: NativeGlassSurface(
                                      material: true,
                                      child: TextButton(
                                        onPressed: () =>
                                            _channel.invokeMethod<void>(
                                              MethodNames
                                                  .openTranslationLanguages,
                                            ),
                                        child: const Text('管理'),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              NativeGlassGroup(
                                children: [
                                  NativeGlassSwitchTile(
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.zap,
                                    ),
                                    title: '登录时启动',
                                    value: settings.launchAtLogin,
                                    onChanged: (v) =>
                                        _edit(() => settings.launchAtLogin = v),
                                  ),
                                  if (_status['loginNeedsApproval'] == true)
                                    NativeGlassSettingRow(
                                      title: '登录项需要在系统设置中允许',
                                      leading: const NativeGlassRowIcon(
                                        icon: LucideIcons.triangleAlert,
                                      ),
                                      child: _grantButton(
                                        label: '允许…',
                                        onPressed: () =>
                                            _channel.invokeMethod<void>(
                                              MethodNames.openLoginItems,
                                            ),
                                      ),
                                    ),
                                ],
                              ),
                            ] else if (_page ==
                                SettingsPage.personalization) ...[
                              NativeGlassGroup(
                                title: '外观与强调色',
                                children: [
                                  NativeGlassSettingRow(
                                    title: '外观',
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.contrast,
                                    ),
                                    child: NativeGlassSegments<String>(
                                      value: settings.glassAppearance,
                                      options: AppearanceModes.labels,
                                      onChanged: (value) => _edit(
                                        () => settings.glassAppearance = value,
                                      ),
                                    ),
                                  ),
                                  NativeGlassSettingRow(
                                    title: '强调色',
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.palette,
                                    ),
                                    child: _SwatchPicker(
                                      keyPrefix: 'accent-color',
                                      options: [
                                        for (final id in AccentColors.values)
                                          (
                                            id: id,
                                            label: AccentColors.labels[id]!,
                                            colors: AccentColors.swatches[id],
                                            sweep: id == AccentColors.system
                                                ? _AccentColorSwatch.systemSweep
                                                : null,
                                            icon: null,
                                          ),
                                      ],
                                      value: settings.accentColor,
                                      customColors: (value) =>
                                          AccentColors.pairOf(value)!,
                                      onChanged: (value) => _edit(
                                        () => settings.accentColor = value,
                                      ),
                                      onPreview: (value) => _previewAppearance(
                                        value == null
                                            ? null
                                            : {
                                                PreferenceKeys.accentColor:
                                                    value,
                                              },
                                      ),
                                    ),
                                  ),
                                  NativeGlassSettingRow(
                                    title: '前景色',
                                    caption:
                                        _foregroundWarning(context, settings) ??
                                        '强调色实底上的图标线条与文字',
                                    captionWarning:
                                        _foregroundWarning(context, settings) !=
                                        null,
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.type,
                                    ),
                                    child: _SwatchPicker(
                                      keyPrefix: 'accent-foreground',
                                      options: [
                                        (
                                          id: AccentForegrounds.auto,
                                          label: AccentForegrounds
                                              .labels[AccentForegrounds.auto]!,
                                          colors: null,
                                          sweep: null,
                                          icon: LucideIcons.contrast,
                                        ),
                                        for (final id in [
                                          AccentForegrounds.white,
                                          AccentForegrounds.black,
                                        ])
                                          (
                                            id: id,
                                            label:
                                                AccentForegrounds.labels[id]!,
                                            colors: (
                                              light:
                                                  AccentForegrounds.colors[id]!,
                                              dark:
                                                  AccentForegrounds.colors[id]!,
                                            ),
                                            sweep: null,
                                            icon: null,
                                          ),
                                      ],
                                      value: settings.accentForeground,
                                      customColors: (value) {
                                        final color = AccentForegrounds.colorOf(
                                          value,
                                        )!;
                                        return (light: color, dark: color);
                                      },
                                      onChanged: (value) => _edit(
                                        () => settings.accentForeground = value,
                                      ),
                                      onPreview: (value) => _previewAppearance(
                                        value == null
                                            ? null
                                            : {
                                                PreferenceKeys.accentForeground:
                                                    value,
                                              },
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              NativeGlassGroup(
                                children: [
                                  NativeGlassSettingRow(
                                    title: '窗口透明度',
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.droplet,
                                    ),
                                    caption: '系统开启“减少透明度”时此项不生效',
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        SizedBox(
                                          width: GlassMetrics.sliderMinWidth,
                                          height: GlassMetrics.sliderHeight,
                                          child: Slider(
                                            value: 1 - settings.glassOpacity,
                                            min: 0,
                                            max: 0.8,
                                            divisions: 80,
                                            onChanged: (value) {
                                              _edit(
                                                () => settings.glassOpacity =
                                                    (100 -
                                                        (value * 100).round()) /
                                                    100,
                                                submit: false,
                                              );
                                              _previewAppearance({
                                                PreferenceKeys.glassOpacity:
                                                    settings.glassOpacity,
                                              });
                                            },
                                            onChangeStart: (_) =>
                                                _adjustingOpacity = true,
                                            onChangeEnd: (_) {
                                              _adjustingOpacity = false;
                                              _save();
                                            },
                                          ),
                                        ),
                                        const SizedBox(
                                          width: GlassMetrics.space8,
                                        ),
                                        SizedBox(
                                          width: GlassMetrics.sliderValueWidth,
                                          child: Text(
                                            '${(100 * (1 - settings.glassOpacity)).round()}%',
                                            textAlign: TextAlign.right,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall!
                                                .copyWith(
                                                  fontFeatures: const [
                                                    FontFeature.tabularFigures(),
                                                  ],
                                                ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              NativeGlassGroup(
                                title: '录制点击特效',
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: GlassMetrics.space4,
                                    ),
                                    child: Center(
                                      child: ClickEffectPlayer(
                                        effect: settings.recordingClickEffect,
                                        onChanged: (v) => _edit(
                                          () =>
                                              settings.recordingClickEffect = v,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ] else if (_page == SettingsPage.languages) ...[
                              NativeGlassGroup(
                                dividerIndent: 0,
                                children: [
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      minHeight: GlassMetrics.rowHeight,
                                    ),
                                    child: Row(
                                      children: [
                                        const Expanded(
                                          child: Text(
                                            '翻译语言',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        NativeGlassSegments<bool>(
                                          value: _inputLanguages,
                                          options: const {
                                            false: '全局翻译',
                                            true: '输入翻译',
                                          },
                                          onChanged: (value) => setState(
                                            () => _inputLanguages = value,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  _language(
                                    '主要语言',
                                    _inputLanguages
                                        ? settings.inputPrimaryLanguage
                                        : settings.primaryLanguage,
                                    (v) {
                                      if (_inputLanguages) {
                                        settings.inputPrimaryLanguage = v;
                                      } else {
                                        settings.primaryLanguage = v;
                                      }
                                    },
                                  ),
                                  _language(
                                    '次要语言（可选）',
                                    (_inputLanguages
                                            ? settings.inputSecondaryLanguage
                                            : settings.secondaryLanguage) ??
                                        '',
                                    (v) {
                                      final secondary = v.isEmpty ? null : v;
                                      if (_inputLanguages) {
                                        settings.inputSecondaryLanguage =
                                            secondary;
                                      } else {
                                        settings.secondaryLanguage = secondary;
                                      }
                                    },
                                    optional: true,
                                    caption: '当翻译文本识别为主要语言时，会自动翻译成次要语言',
                                  ),
                                ],
                              ),
                              NativeGlassGroup(
                                title: '服务与提示词',
                                children: [
                                  NativeGlassDropdown<String>(
                                    label: '默认翻译服务',
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.network,
                                    ),
                                    value: settings.defaultServiceId,
                                    items: {
                                      ServiceConfig.systemId:
                                          ServiceConfig.systemName,
                                      ServiceConfig.builtinId:
                                          ServiceConfig.builtinName,
                                      for (final service in settings.services)
                                        service.id: service.displayName,
                                    },
                                    onChanged: (value) => _edit(
                                      () => settings.defaultServiceId = value,
                                    ),
                                  ),

                                  NativeGlassSettingRow(
                                    title: '术语与提示词',
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.sparkles,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        NativeGlassSurface(
                                          material: true,
                                          child: TextButton(
                                            onPressed: _manageGlossary,
                                            child: Text(
                                              '管理术语（${settings.glossary.length}）',
                                            ),
                                          ),
                                        ),
                                        const SizedBox(
                                          width: GlassMetrics.actionGap,
                                        ),
                                        NativeGlassSurface(
                                          material: true,
                                          child: TextButton(
                                            onPressed: _editPrompts,
                                            child: const Text('编辑提示词'),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              NativeGlassGroup(
                                title: '历史记录',
                                children: [
                                  NativeGlassSwitchTile(
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.history,
                                    ),
                                    title: '记录翻译历史',
                                    value: _historyRecording ?? false,
                                    busy: _savingHistoryRecording,
                                    onChanged:
                                        _historyRecording == null ||
                                            _savingHistoryRecording
                                        ? null
                                        : _setHistoryRecording,
                                  ),
                                ],
                              ),
                            ] else if (_page == SettingsPage.services) ...[
                              NativeGlassGroup(
                                dividerIndent: 0,
                                children: [
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      minHeight: GlassMetrics.rowHeight,
                                    ),
                                    child: Row(
                                      children: [
                                        const Expanded(
                                          child: Text(
                                            '翻译服务',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        NativeGlassSurface(
                                          material: true,
                                          child: TextButton.icon(
                                            onPressed: () => _editService(),
                                            icon: const LineIcon(
                                              LucideIcons.plus,
                                              size: 18,
                                            ),
                                            label: const Text('添加服务'),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (settings.services.isEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        top: GlassMetrics.space8,
                                      ),
                                      child: Text(
                                        '暂无自定义翻译服务；默认使用谷歌翻译或 Apple 系统翻译。',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ),
                                  for (final service in settings.services)
                                    ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(service.displayName),
                                      subtitle: Text(
                                        '${ServiceConfig.kinds[service.kind]}${service.isModel ? ' · ${service.model}' : ''}',
                                      ),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          NativeGlassSurface(
                                            material: true,
                                            child: IconButton(
                                              tooltip:
                                                  '编辑 ${service.displayName}',
                                              icon: const LineIcon(
                                                LucideIcons.pencil,
                                              ),
                                              onPressed: () =>
                                                  _editService(service),
                                            ),
                                          ),
                                          const SizedBox(
                                            width: GlassMetrics.actionGap,
                                          ),
                                          NativeGlassSurface(
                                            material: true,
                                            child: IconButton(
                                              tooltip:
                                                  '删除 ${service.displayName}',
                                              onPressed: () =>
                                                  _confirmDeleteService(
                                                    service,
                                                  ),
                                              icon: const LineIcon(
                                                LucideIcons.trash2,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                            ] else if (_page == SettingsPage.shortcuts) ...[
                              NativeGlassGroup(
                                children: [
                                  NativeGlassSwitchTile(
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.zap,
                                    ),
                                    title: '仅使用快捷键',
                                    value: !settings.automatic,
                                    onChanged: (v) =>
                                        _edit(() => settings.automatic = !v),
                                  ),
                                ],
                              ),
                              NativeGlassGroup(
                                title: '全局快捷键',
                                children: [
                                  ..._shortcutBlock(
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.languages,
                                    ),
                                    title: '全局翻译快捷键',
                                    code: settings.shortcutModifiers,
                                    label: settings.shortcutLabel,
                                    apply:
                                        (target, keyCode, modifiers, label) =>
                                            target
                                              ..shortcutKeyCode = keyCode
                                              ..shortcutModifiers = modifiers
                                              ..shortcutLabel = label,
                                  ),
                                  ..._shortcutBlock(
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.notebookPen,
                                    ),
                                    title: '输入翻译快捷键',
                                    code: settings.inputShortcutModifiers,
                                    label: settings.inputShortcutLabel,
                                    apply:
                                        (target, keyCode, modifiers, label) =>
                                            target
                                              ..inputShortcutKeyCode = keyCode
                                              ..inputShortcutModifiers =
                                                  modifiers
                                              ..inputShortcutLabel = label,
                                  ),
                                ],
                              ),
                            ] else if (_page == SettingsPage.exclusions) ...[
                              NativeGlassGroup(
                                dividerIndent: 0,
                                children: [
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      minHeight: GlassMetrics.rowHeight,
                                    ),
                                    child: Row(
                                      children: [
                                        const Expanded(
                                          child: Text(
                                            '排除应用',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                        NativeGlassSurface(
                                          material: true,
                                          child: TextButton.icon(
                                            onPressed: _addExclusion,
                                            icon: const LineIcon(
                                              LucideIcons.plus,
                                              size: 18,
                                            ),
                                            label: const Text('添加应用'),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (settings.excludedApps.isEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        top: GlassMetrics.space8,
                                      ),
                                      child: Text(
                                        '暂无排除应用；添加后在这些应用中不会自动触发选区翻译。',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ),
                                  for (final app
                                      in settings.excludedApps.entries)
                                    ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(app.value),
                                      trailing: NativeGlassSurface(
                                        material: true,
                                        child: IconButton(
                                          tooltip: '移除排除项',
                                          icon: const LineIcon(
                                            LucideIcons.circleMinus,
                                          ),
                                          onPressed: () => _edit(
                                            () => settings.excludedApps.remove(
                                              app.key,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ] else if (_page ==
                                SettingsPage.screenshotSave) ...[
                              NativeGlassGroup(
                                children: [
                                  ListTile(
                                    key: const ValueKey('截图目录'),
                                    contentPadding: EdgeInsets.zero,
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.folder,
                                    ),
                                    title: const Text('截图目录'),
                                    subtitle: Text(
                                      settings.screenshotSaveDirectory.isEmpty
                                          ? '系统图片目录/截图'
                                          : settings.screenshotSaveDirectory,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                    trailing: Wrap(
                                      spacing: 4,
                                      children: [
                                        NativeGlassSurface(
                                          material: true,
                                          child: TextButton(
                                            onPressed:
                                                _chooseScreenshotDirectory,
                                            child: const Text('选择路径'),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  NativeGlassSwitchTile(
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.history,
                                    ),
                                    title: '记录截图历史',
                                    value: _screenshotHistoryRecording ?? false,
                                    busy: _savingScreenshotHistoryRecording,
                                    onChanged:
                                        _screenshotHistoryRecording == null ||
                                            _savingScreenshotHistoryRecording
                                        ? null
                                        : _setScreenshotHistoryRecording,
                                  ),
                                ],
                              ),
                              NativeGlassGroup(
                                title: 'GIF 导出',
                                children: [
                                  NativeGlassDropdown<int>(
                                    label: '帧率',
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.film,
                                    ),
                                    value: settings.gifFramesPerSecond,
                                    items: {
                                      for (var fps = 1; fps <= 30; fps++)
                                        fps: '$fps fps',
                                    },
                                    onChanged: (fps) => _edit(
                                      () => settings.gifFramesPerSecond = fps,
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      top: GlassMetrics.space12,
                                    ),
                                    child: NativeGlassField(
                                      label: '最大宽度（像素）',
                                      errorText: _gifWidthError,
                                      child: TextField(
                                        key: const Key('gif-maximum-width'),
                                        controller: _gifMaximumWidth,
                                        keyboardType: TextInputType.number,
                                        decoration: const InputDecoration(
                                          hintText: '不限制',
                                        ),
                                        onChanged: (text) => _edit(
                                          () => settings.gifMaximumWidth =
                                              text.trim().isEmpty
                                              ? null
                                              : int.tryParse(text) ?? 0,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ] else if (_page == SettingsPage.recording) ...[
                              NativeGlassGroup(
                                title: '录制选项与点击特效',
                                children: [
                                  NativeGlassSwitchTile(
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.circleDot,
                                    ),
                                    title: '实时翻译时同时录制',
                                    value: settings.liveRecording,
                                    onChanged: (v) =>
                                        _edit(() => settings.liveRecording = v),
                                  ),
                                  NativeGlassSwitchTile(
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.mouse,
                                    ),
                                    title: '截图包含鼠标指针',
                                    value: settings.screenshotIncludesCursor,
                                    onChanged: (v) => _edit(
                                      () =>
                                          settings.screenshotIncludesCursor = v,
                                    ),
                                  ),
                                  NativeGlassSwitchTile(
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.hand,
                                    ),
                                    title: '录制包含点击特效',
                                    value: settings.recordingClickEffectEnabled,
                                    onChanged: (v) => _edit(
                                      () =>
                                          settings.recordingClickEffectEnabled =
                                              v,
                                    ),
                                  ),
                                ],
                              ),
                            ] else if (_page ==
                                SettingsPage.screenshotActions) ...[
                              NativeGlassGroup(
                                children: [
                                  ..._shortcutBlock(
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.crop,
                                    ),
                                    title: '区域截图快捷键',
                                    code: settings.screenshotShortcutModifiers,
                                    label: settings.screenshotShortcutLabel,
                                    apply:
                                        (target, keyCode, modifiers, label) =>
                                            target
                                              ..screenshotShortcutKeyCode =
                                                  keyCode
                                              ..screenshotShortcutModifiers =
                                                  modifiers
                                              ..screenshotShortcutLabel = label,
                                  ),
                                  NativeGlassDropdown<ScreenshotConfirmAction>(
                                    label: '回车或双击确认时',
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.circleCheck,
                                    ),
                                    value: settings.screenshotConfirmAction,
                                    items: const {
                                      ScreenshotConfirmAction.copy: '复制图片',
                                      ScreenshotConfirmAction.copyAndSave:
                                          '复制并保存',
                                    },
                                    onChanged: (action) => _edit(
                                      () => settings.screenshotConfirmAction =
                                          action,
                                    ),
                                  ),
                                  NativeGlassDropdown<ScrollCaptureMode>(
                                    label: '滚动方式',
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.arrowUpDown,
                                    ),
                                    value: settings.scrollCaptureMode,
                                    items: const {
                                      ScrollCaptureMode.manual: '手动滚动',
                                      ScrollCaptureMode.automatic: '自动滚动',
                                    },
                                    onChanged: (mode) => _edit(
                                      () => settings.scrollCaptureMode = mode,
                                    ),
                                  ),
                                ],
                              ),
                            ] else if (_page == SettingsPage.stickers) ...[
                              NativeGlassGroup(
                                dividerIndent: 0,
                                children: [
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      const Text(
                                        '贴纸',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      if (settings.stickers.isEmpty)
                                        Text(
                                          '还没有贴纸',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall,
                                        )
                                      else
                                        Wrap(
                                          spacing: StickerMetrics.thumbnailGap,
                                          runSpacing:
                                              StickerMetrics.thumbnailGap,
                                          children: [
                                            for (final sticker
                                                in settings.stickers)
                                              _StickerThumbnail(
                                                key: ValueKey(
                                                  'sticker-${sticker.id}',
                                                ),
                                                path: _stickerDirectory == null
                                                    ? null
                                                    : '$_stickerDirectory/${sticker.id}.png',
                                                onDelete: () =>
                                                    _confirmRemoveSticker(
                                                      sticker,
                                                    ),
                                              ),
                                          ],
                                        ),
                                      const SizedBox(
                                        height: GlassMetrics.space8,
                                      ),
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: NativeGlassSurface(
                                          material: true,
                                          child: TextButton(
                                            onPressed: _addSticker,
                                            child: const Text('添加图片'),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ] else if (_page == SettingsPage.toolbar) ...[
                              NativeGlassGroup(
                                dividerIndent: 0,
                                children: [
                                  ScreenshotToolbarEditor(
                                    value: settings.screenshotToolbar,
                                    onChanged: (value) => _edit(
                                      () =>
                                          _settings!.screenshotToolbar = value,
                                    ),
                                    reserved: settings.globalShortcutSlots,
                                    systemSlots: _systemShortcutSlots,
                                  ),
                                ],
                              ),
                            ] else if (_page == SettingsPage.mcp) ...[
                              McpSettingsPage(
                                enabled: settings.mcpEnabled,
                                onChanged: (v) =>
                                    _edit(() => settings.mcpEnabled = v),
                                controlEnabled: settings.mcpControlEnabled,
                                onControlChanged: (v) =>
                                    _edit(() => settings.mcpControlEnabled = v),
                                channel: _channel,
                                createService: widget.createMcpService,
                              ),
                            ],
                            if (_conflicted ||
                                (_failed && _dirty) ||
                                (_message != null && !_saving)) ...[
                              const SizedBox(height: GlassMetrics.space16),
                              NativeGlassBanner(
                                message:
                                    _message ??
                                    (_conflicted
                                        ? '设置已在其他位置更新，请重新加载。'
                                        : '自动保存失败，请重试。'),
                                isError: _failed || _conflicted,
                                action: _conflicted
                                    ? NativeGlassSurface(
                                        material: true,
                                        child: TextButton(
                                          onPressed: () {
                                            _dirty = false;
                                            _load();
                                          },
                                          child: const Text('重新加载设置'),
                                        ),
                                      )
                                    : (_failed && _dirty)
                                    ? NativeGlassSurface(
                                        material: true,
                                        child: TextButton(
                                          onPressed: _save,
                                          child: const Text('重试自动保存'),
                                        ),
                                      )
                                    : null,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SubpageReveal extends StatelessWidget {
  const _SubpageReveal({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return child;
    return SingleMotionBuilder(
      from: 0.0,
      value: 1.0,
      motion: AppMotion.bouncy(context),
      child: child,
      builder: (context, progress, target) {
        final clamped = progress.clamp(0.0, 1.0);
        return Opacity(
          opacity: clamped,
          child: Transform.translate(
            offset: Offset(0, 8 * (1 - progress)),
            child: target,
          ),
        );
      },
    );
  }
}

typedef _SwatchOption = ({
  String id,
  String label,
  ({Color light, Color dark})? colors,
  List<Color>? sweep,
  IconData? icon,
});

class _SwatchPicker extends StatefulWidget {
  const _SwatchPicker({
    required this.keyPrefix,
    required this.options,
    required this.value,
    required this.customColors,
    required this.onChanged,
    required this.onPreview,
  });

  final String keyPrefix;
  final List<_SwatchOption> options;
  final String value;
  final ({Color light, Color dark}) Function(String value) customColors;
  final ValueChanged<String> onChanged;
  final ValueChanged<String?> onPreview;

  @override
  State<_SwatchPicker> createState() => _SwatchPickerState();
}

class _SwatchPickerState extends State<_SwatchPicker> {
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final custom = AccentColors.isCustom(widget.value);
    final customColors = custom ? widget.customColors(widget.value) : null;
    final initial = customColors?.light ?? NativeGlassTheme.accentOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 2,
          children: [
            for (final option in widget.options)
              _AccentColorSwatch(
                id: option.id,
                keyPrefix: widget.keyPrefix,
                label: option.label,
                selected: widget.value == option.id,
                swatchColor: switch (option.colors) {
                  null => null,
                  final pair => dark ? pair.dark : pair.light,
                },
                sweep: option.sweep,
                icon: option.icon,
                onSelected: () {
                  setState(() => _editing = false);
                  widget.onChanged(option.id);
                },
              ),
            _AccentColorSwatch(
              id: 'custom',
              keyPrefix: widget.keyPrefix,
              label: '自定义',
              selected: custom,
              swatchColor: customColors == null
                  ? null
                  : (dark ? customColors.dark : customColors.light),
              icon: custom ? null : LucideIcons.pipette,
              onSelected: () => setState(() => _editing = !_editing),
            ),
          ],
        ),
        if (_editing)
          Padding(
            padding: const EdgeInsets.only(top: GlassMetrics.space8),
            child: NativeGlassSurface(
              material: true,
              radius: GlassMetrics.menuRadius,
              child: ColorPicker(
                initial: (color: initial, gradient: null),
                allowGradient: false,
                onPreview: (color) =>
                    widget.onPreview(AccentColors.customValue(color)),
                onApply: (fill) {
                  setState(() => _editing = false);
                  widget.onChanged(AccentColors.customValue(fill.color));
                },
                onCancel: () {
                  setState(() => _editing = false);
                  widget.onPreview(null);
                },
              ),
            ),
          ),
      ],
    );
  }
}

class _AccentColorSwatch extends StatefulWidget {
  const _AccentColorSwatch({
    required this.id,
    this.keyPrefix = 'accent-color',
    required this.label,
    required this.selected,
    required this.swatchColor,
    required this.onSelected,
    this.sweep,
    this.icon,
  });

  static const systemSweep = [
    SystemHues.blue,
    SystemHues.purple,
    Color(0xFFF74F9E),
    Color(0xFFF7821B),
    Color(0xFF28A745),
    SystemHues.blue,
  ];

  final String id;

  final String keyPrefix;
  final String label;
  final bool selected;
  final Color? swatchColor;
  final List<Color>? sweep;
  final IconData? icon;
  final VoidCallback onSelected;

  @override
  State<_AccentColorSwatch> createState() => _AccentColorSwatchState();
}

class _AccentColorSwatchState extends State<_AccentColorSwatch> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reduced = AppMotion.reduced(context);
    final accent = NativeGlassTheme.accentOf(context);
    final ringColor = widget.swatchColor ?? accent;
    final scale = reduced
        ? 1.0
        : _pressed
        ? 0.92
        : _hovered
        ? 1.08
        : 1.0;

    final sweep = widget.sweep;
    final fillDecoration = BoxDecoration(
      shape: BoxShape.circle,
      color:
          widget.swatchColor ??
          (sweep == null
              ? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08)
              : null),
      gradient: widget.swatchColor == null && sweep != null
          ? SweepGradient(colors: sweep)
          : null,
      border: Border.all(
        color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.16),
        width: GlassMetrics.groupBorderWidth,
      ),
    );

    return Semantics(
      label: widget.label,
      selected: widget.selected,
      button: true,
      onTap: widget.onSelected,
      child: Tooltip(
        message: widget.label,
        child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowFocusHighlight: (v) => setState(() => _focused = v),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onSelected();
                return null;
              },
            ),
          },
          child: MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() {
              _hovered = false;
              _pressed = false;
            }),
            child: Listener(
              onPointerDown: (_) => setState(() => _pressed = true),
              onPointerUp: (_) => setState(() => _pressed = false),
              onPointerCancel: (_) => setState(() => _pressed = false),
              child: GestureDetector(
                key: ValueKey('${widget.keyPrefix}-${widget.id}'),
                excludeFromSemantics: true,
                behavior: HitTestBehavior.opaque,
                onTap: widget.onSelected,
                child: SizedBox.square(
                  dimension: GlassMetrics.hitSize,
                  child: Center(
                    child: AnimatedScale(
                      scale: scale,
                      duration: reduced
                          ? Duration.zero
                          : GlassMetrics.transition,
                      curve: Curves.easeOutCubic,
                      child: Container(
                        width: 26,
                        height: 26,
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: _focused
                              ? Border.all(
                                  color: accent,
                                  width: GlassMetrics.focusRingWidth,
                                )
                              : widget.selected
                              ? Border.all(
                                  color: ringColor.withValues(alpha: 0.72),
                                  width: 1.5,
                                )
                              : null,
                        ),
                        child: DecoratedBox(
                          decoration: fillDecoration,
                          child: !widget.selected && widget.icon != null
                              ? LineIcon(
                                  widget.icon,
                                  size: 12,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                )
                              : widget.selected
                              ? Center(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.black.withValues(
                                          alpha: 0.22,
                                        ),
                                        width: 0.5,
                                      ),
                                    ),
                                    child: const SizedBox.square(dimension: 7),
                                  ),
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StickerThumbnail extends StatefulWidget {
  const _StickerThumbnail({
    super.key,
    required this.path,
    required this.onDelete,
  });
  final String? path;
  final VoidCallback? onDelete;

  @override
  State<_StickerThumbnail> createState() => _StickerThumbnailState();
}

class _StickerThumbnailState extends State<_StickerThumbnail> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    onFocusChange: (value) => setState(() => _focused = value),
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          widget.onDelete != null &&
          (event.logicalKey == LogicalKeyboardKey.delete ||
              event.logicalKey == LogicalKeyboardKey.backspace)) {
        widget.onDelete!();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        width: StickerMetrics.thumbnail,
        height: StickerMetrics.thumbnail,
        decoration: _focused
            ? ShapeDecoration(
                shape: RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(
                    StickerMetrics.cellRadius,
                  ),
                  side: BorderSide(
                    color: NativeGlassTheme.accentOf(context),
                    width: GlassMetrics.focusRingWidth,
                  ),
                ),
              )
            : null,
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(StickerMetrics.cellRadius),
                child: widget.path == null
                    ? const SizedBox()
                    : Image.file(
                        File(widget.path!),
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) =>
                            ColoredBox(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                              child: const Center(
                                child: LineIcon(
                                  LucideIcons.imageOff,
                                  size: GlassMetrics.icon,
                                ),
                              ),
                            ),
                      ),
              ),
            ),
            if (_hovered || _focused)
              Positioned(
                top: 0,
                right: 0,
                child: Semantics(
                  label: '删除贴纸',
                  button: true,
                  child: Tooltip(
                    message: '删除贴纸',
                    child: InkWell(
                      onTap: widget.onDelete,
                      borderRadius: BorderRadius.circular(
                        GlassMetrics.minTouchTarget / 2,
                      ),
                      child: const SizedBox.square(
                        dimension: GlassMetrics.minTouchTarget,
                        child: Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Color(0x99000000),
                              shape: BoxShape.circle,
                            ),
                            child: SizedBox.square(
                              dimension: 16,
                              child: LineIcon(
                                LucideIcons.x,
                                size: 12,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}
