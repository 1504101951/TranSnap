import 'dart:async';
import 'dart:io';

import '../common/constants/glass_metrics.dart';
import '../common/constants/drawing_metrics.dart';
import '../common/constants/appearance_modes.dart';
import '../common/constants/method_names.dart';
import '../common/constants/toolbar_grid.dart';
import '../common/constants/channel_names.dart';
import '../common/constants/error_codes.dart';
import '../common/constants/screenshot_enums.dart';
import '../common/constants/shortcut_keys.dart';
import '../common/constants/text_mode.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:motor/motor.dart';

import '../common/widgets/app_motion.dart';
import '../common/widgets/native_glass.dart';

import 'app_settings.dart';
import 'prompt_editor.dart';
import 'sticker_upload_dialog.dart';
import '../screenshot/stickers.dart';
import '../translation/glossary.dart';
import 'glossary_editor.dart';
import 'mcp_platforms.dart';
import 'mcp_settings_page.dart';
import 'service_config.dart';
import 'screenshot_toolbar_editor.dart';
import 'service_editor.dart';

/// 设置窗口子页（#67）；仅控制展示，不进入持久化偏好。
enum SettingsPage {
  general,
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

/// 独立可激活窗口的设置 UI；所有偏好读写由主 Dart 引擎处理。
class SettingsApp extends StatelessWidget {
  /// createMcpService 按 helper 路径创建 MCP 接入平台服务；缺省执行真实 CLI 与读写真实配置。
  const SettingsApp({
    super.key,
    this.createMcpService = McpSettingsPage.defaultService,
  });

  final McpPlatformService Function(String helperPath) createMcpService;

  /// context 为设置引擎的构建上下文；返回完整设置应用。
  @override
  Widget build(BuildContext context) => NativeGlassApp(
    title: 'TranslateApp 设置',
    home: NativeGlassWindowPage(
      child: _SettingsPage(createMcpService: createMcpService),
    ),
  );
}

/// 设置页有状态入口；将主题应用与草稿、保存事务生命周期分开。
class _SettingsPage extends StatefulWidget {
  const _SettingsPage({required this.createMcpService});

  final McpPlatformService Function(String helperPath) createMcpService;
  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

/// 管理本地草稿、版本冲突和串行自动保存；旧回包不能覆盖新编辑。
class _SettingsPageState extends State<_SettingsPage>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel(ChannelNames.settings);
  AppSettings? _settings;
  final _gifMaximumWidth = TextEditingController();
  Map<Object?, Object?> _status = {};
  String? _message;
  bool _saving = false;
  Completer<bool>? _saveCompletion;

  /// 当前正在录制的热键标题；null 表示未在录制，避免双快捷键共用同一布尔态（U-17）。
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

  /// 打开通用页时查询到的 Apple 系统翻译语言包状态说明；null 表示查询中。
  String? _languagePackStatus;

  /// 侧边栏两级分组（#67）；通用与 MCP 没有子页，分组本身可选中。
  static const List<NativeGlassSidebarSection<SettingsPage>> _sidebarSections =
      [
        (
          title: '通用',
          icon: Icons.tune,
          value: SettingsPage.general,
          children: {},
        ),
        (
          title: '翻译',
          icon: Icons.translate,
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
          icon: Icons.crop_free,
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
          icon: Icons.hub_outlined,
          value: SettingsPage.mcp,
          children: {},
        ),
      ];

  /// page 为子页；返回右侧顶部显示的子页标题，与侧边栏名称一致。
  static String _pageTitle(SettingsPage page) {
    for (final section in _sidebarSections) {
      if (section.value == page) return section.title;
      final title = section.children[page];
      if (title != null) return title;
    }
    throw StateError('侧边栏缺少子页 $page');
  }

  /// page 为点选的子页；切换展示并中止未完成的热键录制、清理已提交页的非持久化提示，无返回值。
  void _openPage(SettingsPage page) {
    setState(() {
      _page = page;
      _recordingTarget = null;
      // 离开已稳定页时清除一次性状态说明，避免跨子页残留误导；活跃校验失败与冲突仍保留（U-17）。
      if (!_dirty && !_conflicted) {
        _message = null;
        _failed = false;
      }
    });
    // _checkLanguagePacks 按已提交的主次语言查询，语言设置改动后回到通用页即可看到新状态。
    if (page == SettingsPage.general) _checkLanguagePacks();
    // _loadSystemShortcuts 每次进入工具栏页重新读取，系统设置中的修改随即生效（#141）。
    if (page == SettingsPage.toolbar) _loadSystemShortcuts();
  }

  /// 已启用的系统快捷键落在截图工具栏网格上的格位；工具栏页打开时读取。
  Set<({int modifiers, int digit})> _systemShortcutSlots = const {};

  /// 无参数；读取已启用的系统快捷键并换算为网格格位，非数字行 1–6 或带 ⇧ 的忽略，无返回值。
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

  /// 无参数；向主引擎查询 Apple 系统翻译语言包状态并显示说明，缺少或不支持时显示失败原因，无返回值。
  Future<void> _checkLanguagePacks() async {
    // initState 调用时尚无状态可清空；再次进入通用页时先显示检查中。
    if (_languagePackStatus != null) {
      setState(() => _languagePackStatus = null);
    }
    String status;
    try {
      status = (await _channel.invokeMethod<String>(
        MethodNames.checkSystemTranslation,
      ))!;
    } on PlatformException catch (error) {
      // 主引擎以测试失败返回缺少或不支持的语言包说明。
      status = error.message!;
    }
    if (mounted) setState(() => _languagePackStatus = status);
  }

  /// 翻译语言组正在编辑输入翻译（true）还是全局翻译（false）的语言；不保存，每次打开回到全局翻译（#99）。
  bool _inputLanguages = false;

  /// 无参数；加载主引擎偏好，并监听菜单引起的偏好变化，无返回值。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler((call) async {
      if (call.method == MethodNames.refreshSettings) await _load();
    });
    _load();
    // 初始子页为通用页，同样查询语言包状态。
    _checkLanguagePacks();
    // 贴纸缩略图按「目录/id.png」读取（#103）。
    _channel.invokeMethod<String>(MethodNames.stickerDirectory).then((path) {
      if (mounted) setState(() => _stickerDirectory = path);
    });
  }

  /// 我的贴纸所在目录；读取完成前为 null（#103）。
  String? _stickerDirectory;

  /// 无参数；选择图片并在上传框设定默认大小后写入贴纸文件，再把贴纸加入设置并自动保存；
  /// 任一步取消则不添加，返回结束的 Future（#103）。
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
    // saveSticker 先写文件，设置中只记录 id 与默认大小。
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

  /// sticker 为要删除的贴纸；从设置中移除并自动保存，同时删除贴纸文件，无返回值（#103）。
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

  /// sticker 为待删除贴纸；经破坏性二次确认后再移除记录与本地 PNG 文件（U-11）。
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

  /// 无参数；解除引擎内的回调和生命周期监听，无返回值。
  @override
  void dispose() {
    _gifMaximumWidth.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  /// state 为窗口活动状态；从系统设置返回时刷新权限，不覆盖未保存表单。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshStatus();
  }

  /// 无参数；读取系统真实权限和登录项状态，完成后刷新界面。
  Future<void> _refreshStatus() async {
    final status = await _channel.invokeMapMethod<Object?, Object?>(
      MethodNames.systemStatus,
    );
    if (mounted) setState(() => _status = status!);
  }

  /// 无参数；读取主引擎偏好与系统状态，错误显示在窗口中。
  Future<void> _load() async {
    try {
      final map = (await _channel.invokeMapMethod<Object?, Object?>(
        MethodNames.getSettings,
      ))!;
      await _refreshStatus();
      if (!mounted) return;
      // 系统状态查询期间可能完成自动保存，旧加载快照不能回退表单及其版本。
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

  /// 无参数；串行提交有效草稿并等待当前队列完成，返回是否全部提交成功；失败保留编辑和错误。
  Future<bool> _save() async {
    if (_saving) return _saveCompletion!.future;
    if (!_dirty || _conflicted || _adjustingOpacity) {
      return !_dirty && !_conflicted;
    }
    // 显式导入与后台自动保存等待同一队列；导入不能把“正在保存”当成成功。
    final completion = Completer<bool>();
    _saveCompletion = completion;
    setState(() {
      _saving = true;
      _failed = false;
      // 后台保存不改变布局；仅失败或冲突需要用户可见反馈。
      _message = null;
    });
    try {
      while (_dirty && !_conflicted && !_adjustingOpacity) {
        _settings!.validate();
        final generation = _editGeneration;
        // 深拷贝本次事务；请求等待期间的新编辑不能修改已提交快照。
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
          // 只移除已确认的凭据变更；后续新密钥或删除操作仍留在下一笔事务。
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
        // 状态查询期间也可能继续编辑；下一轮仍检查最新草稿，不遗漏尾部更改。
        await _refreshStatus();
      }
    } catch (error) {
      if (!mounted) return false;
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

  /// target 为正在录制的热键标题，apply 把录制到的键码、修饰键与显示名写入对应快捷键；
  /// 切换页面后自动放弃迟到回包，避免覆盖其他快捷键（U-17）。
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

  /// 无参数；使用 macOS 应用选择器添加一个排除项，取消不改变表单。
  Future<void> _addExclusion() async {
    final app = await _channel.invokeMapMethod<String, String>(
      MethodNames.chooseExcludedApp,
    );
    if (app == null || !mounted) return;
    _edit(() => _settings!.excludedApps[app['id']!] = app['name']!);
  }

  /// 无参数；选择固定截图目录，取消保留当前草稿目录。
  Future<void> _chooseScreenshotDirectory() async {
    final path = await _channel.invokeMethod<String>(
      MethodNames.chooseScreenshotDirectory,
    );
    if (!mounted || path == null) return;
    _edit(() => _settings!.screenshotSaveDirectory = path);
  }

  /// 无参数；由本进程向 TCC 申请屏幕录制，失败则打开系统屏幕录制页。
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
            : '请在系统设置中允许 TranslateApp 的屏幕录制。';
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

  /// change 修改当前草稿；submit 为 false 时由连续控件结束回调提交，返回 void。
  void _edit(VoidCallback change, {bool submit = true}) {
    setState(() {
      change();
      _editGeneration += 1;
      _dirty = true;
    });
    // 同一时刻只有一个事务；正在保存时由回包后的循环提交最新草稿。
    if (submit) _save();
  }

  /// service 为待删除翻译服务；经破坏性二次确认后从列表移除并标记删除对应钥匙串凭据（U-11）。
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
        _settings!.defaultServiceId = ServiceConfig.builtinId;
      }
    });
  }

  /// config 为已有配置或空；确认后自动提交完整服务事务，取消不写入配置或凭据。
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

  /// 无参数；打开术语管理弹窗，单条增删改自动保存，整批导入等待事务，返回弹窗关闭的 Future。
  Future<void> _manageGlossary() => showDialog<void>(
    context: context,
    barrierDismissible: false,
    // GlossaryManager 交回完整列表，单条编辑由 _edit 自动保存，文件导入由 _importGlossary 等待提交。
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

  /// entries 为预览确认的完整术语列表；等待真实事务，失败恢复父页术语并抛出错误，文件草稿由预览保留。
  Future<void> _importGlossary(List<GlossaryEntry> entries) async {
    // _save 先结束已有事务，再记录父页草稿，避免取消失败导入时回退已成功保存的字段。
    if (_saving) await _save();
    if (!mounted) return;
    final previous = [..._settings!.glossary];
    final wasDirty = _dirty;
    // _edit 标记一次完整导入；不在回调外再发起一笔后台提交。
    _edit(
      () => _settings!.glossary
        ..clear()
        ..addAll(entries),
      submit: false,
    );
    // _save 等待真实事务；失败仅由预览保留导入草稿，取消后其他设置保存不会夹带未成功导入的术语。
    if (!await _save()) {
      if (!mounted) return;
      setState(() {
        _settings!.glossary
          ..clear()
          ..addAll(previous);
        _dirty = wasDirty;
      });
      // 冲突要先刷新设置才能保存；其余失败沿用保存时的提示。
      throw FormatException(
        _conflicted ? '设置已在其他窗口修改，请关闭设置窗口后重新打开再导入。' : _message ?? '导入保存失败，请重试。',
      );
    }
  }

  /// 无参数；打开提示词弹窗，保存后把提示词与思考开关写入草稿并自动提交，取消不改变，返回弹窗关闭的 Future（#100）。
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

  /// label/value 为字段名和语言码；optional 允许空值，caption 为标题下方说明，onChanged 写回表单；返回下拉控件。
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

  /// title 为按钮标题，code/label 为当前组合，apply 把录制结果写入对应快捷键，leading 为可选左侧语义图标锚点；
  /// 只对当前正在录制的按钮展示等待文案与忙碌环，常规态以独立机械键帽渲染组合。
  List<Widget> _shortcutBlock({
    required String title,
    required int code,
    required String label,
    required void Function(AppSettings, int, int, String) apply,
    Widget? leading,
  }) {
    final isThisRecording = _recordingTarget == title;
    final tokens = [
      if (code & ShortcutKeys.control != 0) '⌃',
      if (code & ShortcutKeys.option != 0) '⌥',
      if (code & ShortcutKeys.shift != 0) '⇧',
      if (code & ShortcutKeys.command != 0) '⌘',
      label,
    ];
    return [
      // 同一行保留图标、标题和录制命中区，不通过常驻说明增加页面高度。
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
                // 统一常规组合的按钮最小宽度，避免窄字符与宽字符快捷键左右不齐；录制提示文案超宽时仍自然撑开。
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(
                    GlassMetrics.shortcutButtonMinWidth,
                    GlassMetrics.buttonHeight,
                  ),
                ),
                onPressed: _recordingTarget != null
                    ? null
                    : () => _recordShortcut(title, apply),
                icon: const Icon(Icons.keyboard_outlined),
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

  /// 无参数；就地校验 GIF 最大宽度输入框内容，留空或正整数返回 null，否则返回行内纠错文案（U-24）。
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
      // 侧边栏在滚动视口之外，任何滚动位置都能切换子页（#67）。
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NativeGlassSidebar<SettingsPage>(
            key: const ValueKey('settings-sidebar'),
            value: _page,
            sections: _sidebarSections,
            onChanged: _openPage,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    GlassMetrics.pagePadding,
                    12,
                    GlassMetrics.pagePadding,
                    8,
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
                    padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
                    children: [
                      _SubpageReveal(
                        key: ValueKey(_page),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_page == SettingsPage.general) ...[
                              NativeGlassGroup(
                                title: '外观与材质',
                                children: [
                                  NativeGlassSettingRow(
                                    title: '外观',
                                    leading: const NativeGlassRowIcon(
                                      icon: Icons.contrast_outlined,
                                      tint: Color(0xFF0A84FF),
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
                                    title:
                                        '玻璃透明度 ${(100 * (1 - settings.glassOpacity)).round()}%',
                                    leading: const NativeGlassRowIcon(
                                      icon: Icons.blur_on_outlined,
                                      tint: Color(0xFF5E5CE6),
                                    ),
                                    caption:
                                        '更改后自动保存并应用到所有窗口；系统“减少透明度”开启时保持材料不透明。',
                                    // 滑块仅绘制轨道和滑点，不创建整条玻璃外壳。
                                    child: SizedBox(
                                      width: 200,
                                      height: GlassMetrics.sliderHeight,
                                      child: Slider(
                                        value: 1 - settings.glassOpacity,
                                        min: 0,
                                        max: 0.8,
                                        divisions: 80,
                                        label:
                                            '${(100 * (1 - settings.glassOpacity)).round()}%',
                                        // 按滑块的整数百分比换算，避免 1 - 0.8 略小于合法下限 0.2。
                                        onChanged: (value) => _edit(
                                          () => settings.glassOpacity =
                                              (100 - (value * 100).round()) /
                                              100,
                                          submit: false,
                                        ),
                                        onChangeStart: (_) =>
                                            _adjustingOpacity = true,
                                        onChangeEnd: (_) {
                                          _adjustingOpacity = false;
                                          _save();
                                        },
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              // 系统权限与 Apple 离线翻译语言包集中在一张卡片，登录启动单独成组放在最下方（#67）。
                              NativeGlassGroup(
                                title: '系统权限与离线翻译',
                                children: [
                                  ListTile(
                                    minTileHeight: 56,
                                    contentPadding: EdgeInsets.zero,
                                    leading: const NativeGlassRowIcon(
                                      icon: Icons.verified_user_outlined,
                                      tint: Color(0xFF34C759),
                                    ),
                                    title: Row(
                                      children: [
                                        const Text('辅助功能权限'),
                                        const SizedBox(width: 8),
                                        NativeGlassStatus(
                                          granted:
                                              _status['accessibility'] == true,
                                        ),
                                      ],
                                    ),
                                    trailing: NativeGlassSurface(
                                      material: true,
                                      child: TextButton(
                                        onPressed: () =>
                                            _channel.invokeMethod<void>(
                                              MethodNames.openAccessibility,
                                            ),
                                        child: const Text('打开设置'),
                                      ),
                                    ),
                                  ),
                                  ListTile(
                                    key: const ValueKey('屏幕录制权限'),
                                    minTileHeight: 56,
                                    contentPadding: EdgeInsets.zero,
                                    leading: const NativeGlassRowIcon(
                                      icon: Icons.desktop_mac_outlined,
                                      tint: Color(0xFF0A84FF),
                                    ),
                                    title: Row(
                                      children: [
                                        const Text('屏幕录制权限'),
                                        const SizedBox(width: 8),
                                        NativeGlassStatus(
                                          granted:
                                              _status['screenAccess'] == true,
                                        ),
                                      ],
                                    ),
                                    trailing: NativeGlassSurface(
                                      material: true,
                                      child: TextButton(
                                        onPressed: _requestScreenAccess,
                                        child: Text(
                                          _status['screenAccess'] == true
                                              ? '重新检查'
                                              : '申请权限',
                                        ),
                                      ),
                                    ),
                                  ),
                                  // Apple 系统翻译的离线语言包由系统下载，按钮只打开对应设置页（#98）。
                                  // 双行 ListTile 不应用 minTileHeight；外层保证行高不小于 56pt 并垂直居中。
                                  ConstrainedBox(
                                    key: const ValueKey('离线翻译语言'),
                                    constraints: const BoxConstraints(
                                      minHeight: 56,
                                    ),
                                    child: Center(
                                      child: ListTile(
                                        contentPadding: EdgeInsets.zero,
                                        leading: const NativeGlassRowIcon(
                                          icon: Icons.language_outlined,
                                          tint: Color(0xFFAF52DE),
                                        ),
                                        title: const Text(
                                          '安装 Apple 离线翻译语言包',
                                        ),
                                        // 打开通用页时查询的语言包状态；查询完成前显示检查中。
                                        subtitle: Text(
                                          _languagePackStatus ?? '正在检查语言包…',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        ),
                                        trailing: NativeGlassSurface(
                                          material: true,
                                          child: TextButton(
                                            onPressed: () =>
                                                _channel.invokeMethod<void>(
                                                  MethodNames
                                                      .openTranslationLanguages,
                                                ),
                                            child: const Text('前往下载'),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              NativeGlassGroup(
                                title: '启动项',
                                children: [
                                  NativeGlassSwitchTile(
                                    leading: const NativeGlassRowIcon(
                                      icon: Icons.bolt_outlined,
                                      tint: Color(0xFFFF9500),
                                    ),
                                    title: '登录时启动',
                                    value: settings.launchAtLogin,
                                    onChanged: (v) =>
                                        _edit(() => settings.launchAtLogin = v),
                                  ),
                                  if (_status['loginNeedsApproval'] == true)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: NativeGlassSurface(
                                          material: true,
                                          child: TextButton(
                                            onPressed: () =>
                                                _channel.invokeMethod<void>(
                                                  MethodNames.openLoginItems,
                                                ),
                                            child: const Text('在系统设置中允许登录项'),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                      ] else if (_page == SettingsPage.languages) ...[
                        NativeGlassGroup(
                          children: [
                            // 标题行右侧切换编辑哪一组语言；输入翻译与全局翻译各自保存（#99）。
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
                                    onChanged: (value) =>
                                        setState(() => _inputLanguages = value),
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
                                  settings.inputSecondaryLanguage = secondary;
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
                                icon: Icons.hub_outlined,
                                tint: Color(0xFF0A84FF),
                              ),
                              value: settings.defaultServiceId,
                              items: {
                                ServiceConfig.builtinId:
                                    ServiceConfig.builtinName,
                                ServiceConfig.systemId:
                                    ServiceConfig.systemName,
                                for (final service in settings.services)
                                  service.id: service.displayName,
                              },
                              onChanged: (value) => _edit(
                                () => settings.defaultServiceId = value,
                              ),
                            ),

                            // 术语表（#104）与润色、纠错、解释的处理提示词（#100）同属模型服务设置，共用一行，不增加翻译页高度。
                            NativeGlassSettingRow(
                              title: '术语与提示词',
                              leading: const NativeGlassRowIcon(
                                icon: Icons.auto_awesome_outlined,
                                tint: Color(0xFFAF52DE),
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
                                  const SizedBox(width: GlassMetrics.actionGap),
                                  NativeGlassSurface(
                                    material: true,
                                    child: TextButton(
                                      onPressed: _editPrompts,
                                      child: const Text('编辑提示词…'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ] else if (_page == SettingsPage.services) ...[
                        NativeGlassGroup(
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
                                      icon: const Icon(Icons.add, size: 18),
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
                                  style: Theme.of(context).textTheme.bodySmall,
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
                                        tooltip: '编辑 ${service.displayName}',
                                        icon: const Icon(Icons.edit_outlined),
                                        onPressed: () => _editService(service),
                                      ),
                                    ),
                                    const SizedBox(
                                      width: GlassMetrics.actionGap,
                                    ),
                                    NativeGlassSurface(
                                      material: true,
                                      child: IconButton(
                                        tooltip: '删除 ${service.displayName}',
                                        onPressed: () =>
                                            _confirmDeleteService(service),
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ] else if (_page == SettingsPage.shortcuts) ...[
                        NativeGlassGroup(
                          title: '触发方式',
                          children: [
                            NativeGlassSwitchTile(
                              leading: const NativeGlassRowIcon(
                                icon: Icons.bolt_outlined,
                                tint: Color(0xFF0A84FF),
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
                                icon: Icons.translate_outlined,
                                tint: Color(0xFF0A84FF),
                              ),
                              title: '全局翻译快捷键',
                              code: settings.shortcutModifiers,
                              label: settings.shortcutLabel,
                              apply: (target, keyCode, modifiers, label) =>
                                  target
                                    ..shortcutKeyCode = keyCode
                                    ..shortcutModifiers = modifiers
                                    ..shortcutLabel = label,
                            ),
                            // 输入翻译把来源输入框的原文替换为译文（#99）。
                            ..._shortcutBlock(
                              leading: const NativeGlassRowIcon(
                                icon: Icons.edit_note_outlined,
                                tint: Color(0xFF34C759),
                              ),
                              title: '输入翻译快捷键',
                              code: settings.inputShortcutModifiers,
                              label: settings.inputShortcutLabel,
                              apply: (target, keyCode, modifiers, label) =>
                                  target
                                    ..inputShortcutKeyCode = keyCode
                                    ..inputShortcutModifiers = modifiers
                                    ..inputShortcutLabel = label,
                            ),
                          ],
                        ),
                      ] else if (_page == SettingsPage.exclusions) ...[
                        NativeGlassGroup(
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
                                      icon: const Icon(Icons.add, size: 18),
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
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            for (final app in settings.excludedApps.entries)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(app.value),
                                trailing: NativeGlassSurface(
                                  material: true,
                                  child: IconButton(
                                    tooltip: '移除排除项',
                                    icon: const Icon(
                                      Icons.remove_circle_outline,
                                    ),
                                    onPressed: () => _edit(
                                      () =>
                                          settings.excludedApps.remove(app.key),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ] else if (_page == SettingsPage.screenshotSave) ...[
                        NativeGlassGroup(
                          title: '截图目录',
                          children: [
                            ListTile(
                              key: const ValueKey('截图目录'),
                              contentPadding: EdgeInsets.zero,
                              leading: const NativeGlassRowIcon(
                                icon: Icons.folder_outlined,
                                tint: Color(0xFF0A84FF),
                              ),
                              title: Text(
                                settings.screenshotSaveDirectory.isEmpty
                                    ? '系统图片目录/截图'
                                    : settings.screenshotSaveDirectory,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: const Text('默认截图存放路径'),
                              trailing: Wrap(
                                spacing: 4,
                                children: [
                                  NativeGlassSurface(
                                    material: true,
                                    child: TextButton(
                                      onPressed: _chooseScreenshotDirectory,
                                      child: const Text('选择路径'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        NativeGlassGroup(
                          title: 'GIF 导出',
                          children: [
                            NativeGlassDropdown<int>(
                              label: '帧率',
                              leading: const NativeGlassRowIcon(
                                icon: Icons.movie_outlined,
                                tint: Color(0xFFAF52DE),
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
                                  // 留空保留原宽；非法非空值进入统一设置校验，不能当作无限制保存。
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
                                icon: Icons.fiber_manual_record_outlined,
                                tint: Color(0xFF0A84FF),
                              ),
                              title: '实时翻译时同时录制',
                              value: settings.liveRecording,
                              onChanged: (v) =>
                                  _edit(() => settings.liveRecording = v),
                            ),
                            // 只作用于区域截图的冻结帧（#105）。
                            NativeGlassSwitchTile(
                              leading: const NativeGlassRowIcon(
                                icon: Icons.mouse_outlined,
                                tint: Color(0xFF0A84FF),
                              ),
                              title: '截图包含鼠标指针',
                              value: settings.screenshotIncludesCursor,
                              onChanged: (v) => _edit(
                                () => settings.screenshotIncludesCursor = v,
                              ),
                            ),
                            // 区域与全屏录制在鼠标点击处绘制对应特效（#143）。
                            NativeGlassDropdown<RecordingClickEffect>(
                              label: '录制点击特效',
                              leading: const NativeGlassRowIcon(
                                icon: Icons.touch_app_outlined,
                                tint: Color(0xFFAF52DE),
                              ),
                              value: settings.recordingClickEffect,
                              items: {
                                for (final effect
                                    in RecordingClickEffect.values)
                                  effect: effect.label,
                              },
                              onChanged: (v) => _edit(
                                () => settings.recordingClickEffect = v,
                              ),
                            ),
                            // 关闭点击特效时右键与拖动区分开关不生效，随动禁用以保持清晰因果（U-24）。
                            NativeGlassSwitchTile(
                              leading: const NativeGlassRowIcon(
                                icon: Icons.gesture_outlined,
                                tint: Color(0xFFFF9500),
                              ),
                              title: '区分右键与拖动轨迹',
                              value: settings.recordingClickRightDistinct,
                              onChanged:
                                  settings.recordingClickEffect ==
                                      RecordingClickEffect.off
                                  ? null
                                  : (v) => _edit(
                                      () => settings
                                          .recordingClickRightDistinct = v,
                                    ),
                            ),
                          ],
                        ),
                      ] else if (_page == SettingsPage.screenshotActions) ...[
                        NativeGlassGroup(
                          title: '截图触发快捷键',
                          children: [
                            ..._shortcutBlock(
                              leading: const NativeGlassRowIcon(
                                icon: Icons.crop_outlined,
                                tint: Color(0xFF0A84FF),
                              ),
                              title: '区域截图快捷键',
                              code: settings.screenshotShortcutModifiers,
                              label: settings.screenshotShortcutLabel,
                              apply: (target, keyCode, modifiers, label) =>
                                  target
                                    ..screenshotShortcutKeyCode = keyCode
                                    ..screenshotShortcutModifiers = modifiers
                                    ..screenshotShortcutLabel = label,
                            ),
                          ],
                        ),
                        // 回车或双击确认截图时执行的动作（#111）。
                        NativeGlassGroup(
                          title: '确认截图',
                          children: [
                            NativeGlassDropdown<ScreenshotConfirmAction>(
                              label: '回车或双击确认时',
                              leading: const NativeGlassRowIcon(
                                icon: Icons.check_circle_outline,
                                tint: Color(0xFF34C759),
                              ),
                              value: settings.screenshotConfirmAction,
                              items: const {
                                ScreenshotConfirmAction.copy: '复制图片',
                                ScreenshotConfirmAction.copyAndSave: '复制并保存',
                              },
                              onChanged: (action) => _edit(
                                () => settings.screenshotConfirmAction = action,
                              ),
                            ),
                          ],
                        ),
                        // 长截图默认手动滚动；自动时由 App 滚动来源窗口，用户在选区内滚动即接管（#112）。
                        NativeGlassGroup(
                          title: '长截图',
                          children: [
                            NativeGlassDropdown<ScrollCaptureMode>(
                              label: '滚动方式',
                              leading: const NativeGlassRowIcon(
                                icon: Icons.swap_vert_outlined,
                                tint: Color(0xFFAF52DE),
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
                        // 我的贴纸：缩略图、悬停删除与添加图片（#103）。
                        NativeGlassGroup(
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Text(
                                  '贴纸',
                                  style: TextStyle(fontWeight: FontWeight.w600),
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
                                      runSpacing: StickerMetrics.thumbnailGap,
                                      children: [
                                        for (final sticker in settings.stickers)
                                          _StickerThumbnail(
                                            key: ValueKey(
                                              'sticker-${sticker.id}',
                                            ),
                                            path: _stickerDirectory == null
                                                ? null
                                                : '$_stickerDirectory/${sticker.id}.png',
                                            onDelete: () =>
                                                _confirmRemoveSticker(sticker),
                                          ),
                                      ],
                                    ),
                                  const SizedBox(height: GlassMetrics.space8),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: NativeGlassSurface(
                                      material: true,
                                      child: TextButton(
                                        onPressed: _addSticker,
                                        child: const Text('添加图片…'),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ] else if (_page == SettingsPage.toolbar) ...[
                          NativeGlassGroup(
                            children: [
                              ScreenshotToolbarEditor(
                                value: settings.screenshotToolbar,
                                onChanged: (value) => _edit(
                                  () => _settings!.screenshotToolbar = value,
                                ),
                                // 全局快捷键占用的格位不可放入；系统快捷键冲突只提示（#141）。
                                reserved: settings.globalShortcutSlots,
                                systemSlots: _systemShortcutSlots,
                              ),
                            ],
                          ),
                        ] else if (_page == SettingsPage.mcp) ...[
                          // McpSettingsPage 提供 MCP 开关、helper 路径、配置复制与接入平台列表；开关走同一自动保存。
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
                        // 只在有冲突、自动保存失败或一次性状态提示时渲染，正常无错误状态不占高度（#67）。
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

/// 设置子页可打断微距物理浮现（#67 方案 A、#144）：切页时以 8pt 微距淡入，依赖 ValueKey 切换即时重置并遵守减少动态效果设置。
class _SubpageReveal extends StatelessWidget {
  /// child 为当前选中的设置子页列。
  const _SubpageReveal({super.key, required this.child});

  final Widget child;

  /// context 提供无障碍减动效偏好；返回轻量化物理浮现包裹后的子页内容。
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

/// 设置页的一张贴纸缩略图：48×48pt、圆角 6pt，悬停或键盘聚焦时右上角显示 24pt 删除命中区（#103、U-19）。
class _StickerThumbnail extends StatefulWidget {
  /// path 为贴纸文件路径（目录未读取时为 null），onDelete 为删除动作（为空时禁用）。
  const _StickerThumbnail({
    super.key,
    required this.path,
    required this.onDelete,
  });
  final String? path;
  final VoidCallback? onDelete;

  /// 无参数；返回持有悬停与焦点状态的状态。
  @override
  State<_StickerThumbnail> createState() => _StickerThumbnailState();
}

/// 持有悬停与焦点状态，确保键鼠均可发现与删除贴纸，并在文件损坏时显示降级占位图（U-19、U-24）。
class _StickerThumbnailState extends State<_StickerThumbnail> {
  bool _hovered = false;
  bool _focused = false;

  /// context 为构建上下文；返回带焦点边框、损坏降级与 24pt 删除热区的缩略图。
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
                              color: Theme.of(
                                context,
                              ).colorScheme.surfaceContainerHighest,
                              child: const Center(
                                child: Icon(
                                  Icons.broken_image_outlined,
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
                              child: Icon(
                                Icons.close,
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
