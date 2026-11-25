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

/// 设置窗口子页（#67）；仅控制展示，不进入持久化偏好。
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
    title: '权限与启动',
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
        // 「通用」为分组标签：权限与启动、个性化（外观、强调色、窗口透明度）两个子页（#1、#67）。
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

  /// page 为子页；返回右侧顶部显示的子页标题，与侧边栏名称一致。
  static String _pageTitle(SettingsPage page) {
    for (final section in _sidebarSections) {
      if (section.value == page) return section.title;
      final title = section.children[page];
      if (title != null) return title;
    }
    throw StateError('侧边栏缺少子页 $page');
  }

  /// page 为点选的子页；切换展示并同步原生窗口标题、中止未完成的热键录制、清理已提交页的非持久化提示，无返回值。
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
    // 窗口标题只写当前子页名，测试未注册该通道时静默忽略。
    unawaited(_syncWindowTitle(_pageTitle(page)));
    // _checkLanguagePacks 按已提交的主次语言查询，语言设置改动后回到通用页即可看到新状态。
    if (page == SettingsPage.general) _checkLanguagePacks();
    // _loadSystemShortcuts 每次进入工具栏页重新读取，系统设置中的修改随即生效（#141）。
    if (page == SettingsPage.toolbar) _loadSystemShortcuts();
  }

  /// title 为当前子页标题；同步到原生设置窗口标题，忽略未实现的通道调用。
  Future<void> _syncWindowTitle(String title) async {
    try {
      await _channel.invokeMethod<void>(MethodNames.setWindowTitle, {
        'title': title,
      });
    } on MissingPluginException {
      // 无原生窗口或测试夹具未处理标题同步时保持静默。
    } on PlatformException {
      // 标题同步不影响子页浏览。
    }
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

  /// granted 为权限是否已开启，onGrant 为前往授权的动作；返回右侧状态，未开启时附带主要按钮「授权…」（#142 第 14 条）。
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

  /// label 为按钮文字，onPressed 为动作；返回 28pt 高、强调色实底的紧凑主要按钮，用于需要用户处理的设置行。
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

  /// context 提供当前外观的强调色，settings 为草稿；前景色不是「自动」且与强调色对比度低于 4.5:1 时
  /// 返回提示文字，否则返回 null（#144）。
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

  /// fields 为待预览的视觉字段（PreferenceKeys.glassOpacity / accentColor），null 清除预览；
  /// 原生只广播到所有窗口、不写偏好，保存成功后原生自动清除。返回发送完成的 Future（#144）。
  Future<void> _previewAppearance(Map<String, Object>? fields) =>
      _channel.invokeMethod<void>(MethodNames.previewAppearance, fields);

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
      // 保存失败时清除外观预览，各窗口回到上次已保存的透明度与强调色（#144）。
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
    final tokens = shortcutTokens(code, label);
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
            topPadding: GlassMetrics.sidebarTopInset,
            onChanged: _openPage,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 右侧顶部 28pt 为窗口拖动区：Flutter 盖住了系统标题栏，空白处拖动交给原生窗口（#67）。
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
                              // 权限与 Apple 离线翻译语言包集中在一张卡片，登录启动单独一张无眉标卡片放在最下方（#67）。
                              // 已开启只显示状态；只有未开启的权限出现主要按钮，让唯一需要处理的那行跳出来（#142 第 14 条）。
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
                                  // Apple 系统翻译的离线语言包由系统下载，按钮只打开对应设置页（#98）。
                                  NativeGlassSettingRow(
                                    key: const ValueKey('离线翻译语言'),
                                    title: 'Apple 离线翻译语言包',
                                    // 打开通用页时查询的语言包状态；查询完成前显示检查中。
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
                                      // 调色时只预览不保存；取消时清除预览，各窗口回到已保存的强调色。
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
                                  // 强调色实底上的前景（图标线条与文字）；非自动且对比度不足时说明行改为橙色提示（#144）。
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
                                    // 滑块仅绘制轨道和滑点，不创建整条玻璃外壳；数值用等宽数字放在滑块右侧。
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
                                            // 按滑块的整数百分比换算，避免 1 - 0.8 略小于合法下限 0.2；
                                            // 拖动中逐帧预览到所有窗口，松手才保存（#144）。
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
                            ] else if (_page == SettingsPage.languages) ...[
                              NativeGlassGroup(
                                dividerIndent: 0,
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
                              // 只有一行的分组不加眉标（#67）。
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
                                  // 输入翻译把来源输入框的原文替换为译文（#99）。
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
                              // 只有一行的分组不加眉标（#67）。
                              NativeGlassGroup(
                                children: [
                                  ListTile(
                                    key: const ValueKey('截图目录'),
                                    contentPadding: EdgeInsets.zero,
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.folder,
                                    ),
                                    // 去掉眉标后由标题说明这是什么，当前路径放在说明行（#67）。
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
                                      icon: LucideIcons.circleDot,
                                    ),
                                    title: '实时翻译时同时录制',
                                    value: settings.liveRecording,
                                    onChanged: (v) =>
                                        _edit(() => settings.liveRecording = v),
                                  ),
                                  // 只作用于区域截图的冻结帧（#105）。
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
                                  // 区域与全屏录制在鼠标点击处绘制对应特效（#143）。
                                  NativeGlassDropdown<RecordingClickEffect>(
                                    label: '录制点击特效',
                                    leading: const NativeGlassRowIcon(
                                      icon: LucideIcons.hand,
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
                                      icon: LucideIcons.penTool,
                                    ),
                                    title: '区分右键与拖动轨迹',
                                    value: settings.recordingClickRightDistinct,
                                    onChanged:
                                        settings.recordingClickEffect ==
                                            RecordingClickEffect.off
                                        ? null
                                        : (v) => _edit(
                                            () =>
                                                settings.recordingClickRightDistinct =
                                                    v,
                                          ),
                                  ),
                                ],
                              ),
                            ] else if (_page ==
                                SettingsPage.screenshotActions) ...[
                              // 区域截图快捷键、确认方式与长截图滚动方式各只有一行，合并为一张无眉标卡片（#67）。
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
                                  // 回车或双击确认截图时执行的动作（#111）。
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
                                  // 长截图默认手动滚动；自动时由 App 滚动来源窗口，用户在选区内滚动即接管（#112）。
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
                              // 我的贴纸：缩略图、悬停删除与添加图片（#103）。
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

/// 色点选择器中的一个预设：id 为偏好值，label 为提示与读屏名，colors 为浅/深外观实心色，
/// sweep 为多色圆环，icon 为未选中时的中心图标；三者都为空时为中性底。
typedef _SwatchOption = ({
  String id,
  String label,
  ({Color light, Color dark})? colors,
  List<Color>? sweep,
  IconData? icon,
});

/// 个性化页色点选择器（#67、#144），强调色与前景色两行共用：若干预设与末位「自定义」调色盘，
/// 支持鼠标悬停微放、按下微缩、键盘焦点环与选中白点指示。预设点击即保存；自定义在色点下方展开纯色调色盘，
/// 调色时实时预览，「应用」保存，「取消」恢复。
class _SwatchPicker extends StatefulWidget {
  /// keyPrefix 为色点测试键前缀，options 为预设，value 为当前偏好（预设 id 或 #RRGGBB），
  /// customColors 返回自定义值在浅/深外观下的显示色，onChanged 回传要保存的新值，
  /// onPreview 回传调色中的 #RRGGBB 供全窗口预览，null 表示清除预览。
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

/// 持有自定义调色盘是否展开；颜色与保存状态由设置草稿承载。
class _SwatchPickerState extends State<_SwatchPicker> {
  bool _editing = false;

  /// context 提供明暗环境与强调色主题；返回 32×32pt 命中圆点行，自定义展开时在下方显示调色盘。
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final custom = AccentColors.isCustom(widget.value);
    final customColors = custom ? widget.customColors(widget.value) : null;
    // 调色盘初始色：已有自定义色用它，否则用当前生效的强调色。
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
            // 「自定义」未选中时为中性底加取色笔图标，与多色圆环区分；选中后显示所选颜色。
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

/// 单个可聚焦/可悬停的强调色色点按钮：swatchColor 为实心色，sweep 为多色圆环（跟随系统），
/// 两者都为空时为中性底（未设置的自定义）；icon 为未选中时叠在中心的图标。
class _AccentColorSwatch extends StatefulWidget {
  /// id 为协议值，label 为提示与读屏名，selected 为选中态，swatchColor 为实心色值，
  /// sweep 为多色圆环的颜色序列，icon 为中心图标，onSelected 为选中回调。
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

  /// 「跟随系统」的多色圆环，取 macOS 常见系统强调色。
  static const systemSweep = [
    Color(0xFF007AFF),
    Color(0xFFAF52DE),
    Color(0xFFF74F9E),
    Color(0xFFF7821B),
    Color(0xFF28A745),
    Color(0xFF007AFF),
  ];

  final String id;

  /// 测试键前缀：强调色为 accent-color，前景色为 accent-foreground。
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

  /// context 提供外观与减动效设置；返回 32×32 命中区内的 22pt 立体色点。
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

    // 实心色、多色圆环（跟随系统）或中性底（未设置的自定义）三选一，外加 0.5pt 浅描边。
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
