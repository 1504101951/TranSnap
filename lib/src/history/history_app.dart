import 'dart:async';

import '../common/constants/channel_names.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/constants/preference_keys.dart';
import '../common/utils/date_text.dart';
import '../common/utils/shortcut_tokens.dart';
import '../common/widgets/app_motion.dart';
import '../common/widgets/native_glass.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'history_empty_state.dart';
import 'history_list_card.dart';
import 'screenshot_history_page.dart';
import 'translation_history.dart';
import 'vocabulary_page.dart';

/// 历史窗口的分段；翻译历史、生词本（#102）与截图历史（#29）共用同一窗口。
enum _HistorySection { history, vocabulary, screenshots }

/// 独立历史窗口；只展示主引擎持久化结果，不持有第二份数据库。
class HistoryApp extends StatefulWidget {
  /// channel 为历史查询和记录开关通道；创建独立窗口内容。
  const HistoryApp({
    super.key,
    this.channel = const MethodChannel(ChannelNames.settings),
  });

  /// SQLite 统一由主引擎管理，避免多个窗口重复写入。
  final MethodChannel channel;

  /// 无参数；返回维护分页和记录开关的窗口状态。
  @override
  State<HistoryApp> createState() => _HistoryAppState();
}

/// 按本地日期分组后的历史条目集合。
class _DateRecordGroup {
  const _DateRecordGroup({required this.label, required this.records});

  final String label;
  final List<TranslationRecord> records;
}

/// 维护当前浏览列表；游标分页使新增记录不影响已加载的卡片。
class _HistoryAppState extends State<HistoryApp> {
  /// 保持数据库倒序，长文不截断。
  final _items = <TranslationRecord>[];

  /// 读取成功前禁用开关，避免猜测偏好覆盖真实设置。
  bool? _recording;
  bool _savingRecording = false;
  bool _loading = false;
  int _requestVersion = 0;
  bool _done = false;
  String? _pageError;
  String? _recordingError;
  bool _failedReset = false;
  final _search = TextEditingController();
  final _pageKey = GlobalKey();
  final _filterMenu = MenuController();
  final _moreMenu = MenuController();
  String _source = '';
  List<String> _sources = [];
  DateTime? _from;
  DateTime? _to;
  int? _retentionDays;
  bool _retentionConfirmed = true;
  bool _managing = false;
  String? _managementError;

  /// 当前设置的全局翻译与区域截图快捷键键帽，供各分段空状态展示（#67）。
  List<String> _globalShortcutTokens = shortcutTokens(6144, 'T');
  List<String> _screenshotShortcutTokens = shortcutTokens(6144, 'S');

  /// 当前分段；记录开关仅在翻译历史分段显示。
  _HistorySection _section = _HistorySection.history;

  /// 已访问的分段；延迟初始化未打开的分段，切换回来时保留滚动与筛选状态（U-22）。
  final Set<_HistorySection> _visited = {_HistorySection.history};

  /// 搜索防抖计时器；避免逐字输入高频触发分页通道调用。
  Timer? _searchDebounce;

  /// 每条翻译历史卡片的复制确认动效触发计数。
  final Map<int, int> _copyTriggers = {};

  /// 主引擎通知历史、生词本或截图历史变化的次数；递增后对应分段重新读取。
  int _changeVersion = 0;

  /// section 为历史分段；返回原生窗口与应用标题（不重复 App 名，#1）。
  static String _sectionTitle(_HistorySection section) => switch (section) {
    _HistorySection.history => '翻译历史',
    _HistorySection.vocabulary => '生词本',
    _HistorySection.screenshots => '截图历史',
  };

  /// 无参数；返回当前是否处于搜索或筛选状态。
  bool get _hasActiveFilters =>
      _search.text.trim().isNotEmpty ||
      _source.isNotEmpty ||
      _from != null ||
      _to != null;

  /// 无参数；读取首批记录、开关、管理元信息与快捷键设置，无返回值。
  @override
  void initState() {
    super.initState();
    widget.channel.setMethodCallHandler((call) async {
      if (call.method != MethodNames.historyChanged) return;
      // 同一变更通知覆盖翻译历史、生词本与截图历史，都按最新数据重载。
      setState(() => _changeVersion += 1);
      await _refresh();
    });
    // 首屏与开关独立读取，开关失败不阻止历史浏览。
    _loadMore();
    _loadRecording();
    _loadManagement(prompt: true);
    _loadShortcuts();
  }

  /// 无参数；读取主引擎已提交的全局翻译与区域截图快捷键，失败时保留默认键帽，返回结束 Future。
  Future<void> _loadShortcuts() async {
    try {
      final settings = await widget.channel.invokeMapMethod<Object?, Object?>(
        MethodNames.getSettings,
      );
      if (!mounted || settings == null) return;
      final globalModifiers =
          settings[PreferenceKeys.shortcutModifiers] as int? ?? 6144;
      final globalLabel =
          settings[PreferenceKeys.shortcutLabel] as String? ?? 'T';
      final shotModifiers =
          settings[PreferenceKeys.screenshotShortcutModifiers] as int? ?? 6144;
      final shotLabel =
          settings[PreferenceKeys.screenshotShortcutLabel] as String? ?? 'S';
      setState(() {
        _globalShortcutTokens = shortcutTokens(globalModifiers, globalLabel);
        _screenshotShortcutTokens = shortcutTokens(shotModifiers, shotLabel);
      });
    } on MissingPluginException {
      // 独立测试夹具未实现设置读取时保留默认快捷键。
    } on PlatformException {
      // 快捷键读取失败不阻塞历史列表加载。
    }
  }

  /// title 为当前分段标题；同步原生历史窗口标题，忽略未实现的通道调用。
  Future<void> _syncWindowTitle(String title) async {
    try {
      await widget.channel.invokeMethod<void>(MethodNames.setWindowTitle, {
        'title': title,
      });
    } on MissingPluginException {
      // 无原生窗口或测试夹具未处理标题同步时保持静默。
    } on PlatformException {
      // 标题同步不影响分段切换。
    }
  }

  /// section 为目标分段；更新分段挂载并同步原生窗口标题。
  void _selectSection(_HistorySection section) {
    setState(() {
      _section = section;
      _visited.add(section);
    });
    unawaited(_syncWindowTitle(_sectionTitle(section)));
  }

  /// 无参数；读取持久化开关，返回读取结束的 Future。
  Future<void> _loadRecording() async {
    try {
      final value = await widget.channel.invokeMethod<bool>(
        MethodNames.historyRecording,
      );
      if (!mounted) return;
      setState(() {
        _recording = value!;
        _recordingError = null;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _recordingError = error.message ?? '无法读取记录设置');
    }
  }

  /// enabled 为用户选择；持久化成功后才更新显示，返回保存结束的 Future。
  Future<void> _setRecording(bool enabled) async {
    setState(() => _savingRecording = true);
    try {
      await widget.channel.invokeMethod<void>(MethodNames.setHistoryRecording, {
        'enabled': enabled,
      });
      if (!mounted) return;
      setState(() {
        _recording = enabled;
        _recordingError = null;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _recordingError = error.message ?? '无法保存记录设置');
    } finally {
      if (mounted) setState(() => _savingRecording = false);
    }
  }

  /// reset 决定替换首批或按原游标追加；失败保留记录与重试语义，返回读取结束的 Future。
  Future<void> _loadMore({bool reset = false}) async {
    if (!reset && (_loading || _done)) return;
    final version = reset ? ++_requestVersion : _requestVersion;
    setState(() {
      _loading = true;
      _pageError = null;
    });
    try {
      final last = reset ? null : _items.lastOrNull;
      final page = await widget.channel.invokeListMethod<Map<Object?, Object?>>(
        MethodNames.historyPage,
        {
          'limit': 10,
          'query': _search.text.trim(),
          'source': _source,
          if (_from != null) 'from': _from!.millisecondsSinceEpoch,
          if (_to != null)
            'to': DateTime(
              _to!.year,
              _to!.month,
              _to!.day + 1,
            ).millisecondsSinceEpoch,
          if (last != null)
            'before': {'completedAt': last.completedAt, 'id': last.id},
        },
      );
      if (!mounted || version != _requestVersion) return;
      // 完整解析后再追加，避免失败的一页留下部分记录。
      final records = page!.map(TranslationRecord.fromMap).toList();
      setState(() {
        if (reset) _items.clear();
        _items.addAll(records);
        _done = records.length < 10;
      });
    } on PlatformException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _failedReset = reset;
        _pageError = error.message ?? '无法读取翻译历史';
      });
    } finally {
      if (mounted && version == _requestVersion) {
        setState(() => _loading = false);
      }
    }
  }

  /// 无参数；回到最新记录并重新加载首批，返回刷新完成的 Future。
  Future<void> _refresh() async {
    // 列表与管理元数据分别显示失败，互不阻塞。
    await Future.wait([_loadMore(reset: true), _loadManagement()]);
  }

  /// prompt 为首次读取标记；读取来源与期限，必要时提示默认期限确认，返回读取结束的 Future。
  Future<void> _loadManagement({bool prompt = false}) async {
    try {
      // 来源与期限互不依赖，并发读取；任一失败按原异常进入下方的 PlatformException 处理。
      final results = await Future.wait<Object?>([
        widget.channel.invokeListMethod<String>(MethodNames.historySources),
        widget.channel.invokeMapMethod<String, Object?>(
          MethodNames.historyRetention,
        ),
      ]);
      final sources = results[0] as List<String>?;
      final retention = results[1] as Map<String, Object?>?;
      if (!mounted) return;
      setState(() {
        _sources = sources!;
        _retentionDays = retention!['days'] as int;
        _retentionConfirmed = retention['confirmed'] as bool;
        _managementError = null;
      });
      if (prompt && !_retentionConfirmed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final context = _pageKey.currentContext;
          if (context != null && mounted) {
            _changeRetention(context, _retentionDays!);
          }
        });
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _managementError = error.message ?? '无法读取历史管理设置');
      }
    }
  }

  /// context 为窗口内上下文，title/message 为确认说明，confirmLabel/destructive 为确认按钮文案与危险样式；返回是否明确确认。
  Future<bool> _confirm(
    BuildContext context,
    String title,
    String message, {
    String confirmLabel = '确认',
    bool destructive = false,
  }) => NativeGlassDialog.confirm(
    context: context,
    title: title,
    message: message,
    confirmLabel: confirmLabel,
    destructive: destructive,
  );

  /// context 为弹窗上下文，days 为待选期限；预览清理数量并确认后提交，返回操作结束的 Future。
  Future<void> _changeRetention(BuildContext context, int days) async {
    setState(() => _managing = true);
    try {
      // 预览不修改设置或记录，取消后保持数据库原状。
      final preview = await widget.channel.invokeMapMethod<String, Object?>(
        MethodNames.historyRetention,
        {'days': days},
      );
      if (!context.mounted) return;
      final count = preview!['expiredCount'] as int;
      if (days != 0 &&
          !await _confirm(
            context,
            '设置历史保留期限',
            '保留最近 $days 天的翻译历史，将清理 $count 条记录。确认后持续自动清理。',
          )) {
        return;
      }
      await widget.channel.invokeMethod<void>(MethodNames.setHistoryRetention, {
        'days': days,
      });
      if (mounted) await _refresh();
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _managementError = error.message ?? '无法保存历史保留期限');
      }
    } finally {
      if (mounted) setState(() => _managing = false);
    }
  }

  /// context 为弹窗上下文；id 非空时删除单条，为空时清空全部翻译历史并重置筛选条件，返回操作结束的 Future。
  Future<void> _deleteHistory(BuildContext context, {int? id}) async {
    final confirmed = await _confirm(
      context,
      id == null ? '清空全部翻译历史' : '删除翻译记录',
      id == null ? '清空全部翻译历史，不受当前筛选范围限制。此操作无法撤销。' : '删除这条翻译记录？此操作无法撤销。',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _managing = true);
    try {
      await widget.channel.invokeMethod<void>(
        id == null ? MethodNames.clearHistory : MethodNames.deleteHistory,
        id == null ? null : {'id': id},
      );
      if (!mounted) return;
      if (id == null) {
        // 清空全部历史后清除筛选状态，避免空列表停留在已筛选视图下造成误解。
        _searchDebounce?.cancel();
        setState(() {
          _search.clear();
          _source = '';
          _from = null;
          _to = null;
        });
      }
      await _refresh();
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _managementError = error.message ?? '无法删除翻译历史');
      }
    } finally {
      if (mounted) setState(() => _managing = false);
    }
  }

  /// value 为搜索输入当前文本；同步清除按钮可见性并在 200ms 防抖后重置查询首批记录。
  void _onSearchChanged(String value) {
    setState(() {});
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) _loadMore(reset: true);
    });
  }

  /// 无参数；取消未触发的搜索防抖，重置搜索、来源与起止日期并重读首批历史。
  void _clearFilters() {
    _searchDebounce?.cancel();
    setState(() {
      _search.clear();
      _source = '';
      _from = null;
      _to = null;
    });
    _loadMore(reset: true);
  }

  /// item 为待复制的历史记录；复制译文到剪贴板并递增对应卡片的复制确认触发计数。
  Future<void> _copyItem(TranslationRecord item) async {
    await Clipboard.setData(ClipboardData(text: item.translatedText));
    if (!mounted) return;
    setState(() {
      _copyTriggers[item.id] = (_copyTriggers[item.id] ?? 0) + 1;
    });
  }

  /// context 为日期控件上下文，start 指定起始或结束日期；选择后回到首批，返回选择结束的 Future。
  Future<void> _pickDate(BuildContext context, {required bool start}) async {
    final first = start ? DateTime(1970) : _from ?? DateTime(1970);
    final last = start ? _to ?? DateTime(2100) : DateTime(2100);
    final chosen = start ? _from : _to;
    final today = DateTime.now();
    final initial =
        chosen ??
        (today.isBefore(first)
            ? first
            : today.isAfter(last)
            ? last
            : today);
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (date == null || !mounted) return;
    setState(() {
      if (start) {
        _from = date;
      } else {
        _to = date;
      }
    });
    // 本地日期按日历的下一天生成排他上界，避免夏令时日长变化。
    await _loadMore(reset: true);
  }

  /// context 为窗口上下文；构建标题栏居中分段与仅在翻译历史显示的记录开关（#67）。
  Widget _buildHeader(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final segments = NativeGlassSegments<_HistorySection>(
      value: _section,
      options: const {
        _HistorySection.history: '翻译历史',
        _HistorySection.vocabulary: '生词本',
        _HistorySection.screenshots: '截图历史',
      },
      navigation: true,
      onChanged: _selectSection,
    );
    final recordingControl = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _recording == false ? '记录 · 已暂停' : '记录',
          style: TextStyle(
            fontSize: GlassMetrics.captionFont,
            height: GlassMetrics.captionLine / GlassMetrics.captionFont,
            color: _recording == false
                ? colors.onSurfaceVariant
                : colors.onSurface,
          ),
        ),
        const SizedBox(width: GlassMetrics.space8),
        NativeGlassSwitch(
          label: '记录翻译历史',
          value: _recording ?? false,
          busy: _savingRecording,
          onChanged: _recording == null || _savingRecording
              ? null
              : _setRecording,
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        GlassMetrics.pagePadding,
        GlassMetrics.space12,
        GlassMetrics.pagePadding,
        GlassMetrics.space8,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 520pt 及以上窗口下居中分段与右侧「记录 · 已暂停」开关互不重叠；窄窗口自动退让避免溢出。
          if (constraints.maxWidth >= 472) {
            return SizedBox(
              width: constraints.maxWidth,
              height: GlassMetrics.hitSize + 4,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Center(child: segments),
                  if (_section == _HistorySection.history)
                    Align(
                      alignment: Alignment.centerRight,
                      child: recordingControl,
                    ),
                ],
              ),
            );
          }
          return SizedBox(
            width: constraints.maxWidth,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: GlassMetrics.space8,
              runSpacing: GlassMetrics.space8,
              children: [
                segments,
                if (_section == _HistorySection.history) recordingControl,
              ],
            ),
          );
        },
      ),
    );
  }

  /// context 为窗口上下文；构建「筛选」下拉面板（来源与起止日期，#67）。
  Widget _buildFilterMenu(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasFilterChoices = _source.isNotEmpty || _from != null || _to != null;
    final sources = {..._sources, if (_source.isNotEmpty) _source};
    return MenuAnchor(
      controller: _filterMenu,
      style: NativeGlassMenuPanel.anchorStyle,
      menuChildren: [
        NativeGlassMenuPanel(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Text(
                '来源',
                style: TextStyle(
                  fontSize: GlassMetrics.groupHeaderFont,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            NativeGlassMenuItem(
              label: '全部来源',
              checked: _source.isEmpty,
              onPressed: () {
                if (_source.isEmpty) return;
                setState(() => _source = '');
                _loadMore(reset: true);
              },
            ),
            for (final source in sources)
              NativeGlassMenuItem(
                label: source,
                checked: _source == source,
                onPressed: () {
                  setState(() => _source = _source == source ? '' : source);
                  _loadMore(reset: true);
                },
              ),
            const Divider(
              height: 8,
              thickness: GlassMetrics.groupDividerThickness,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Text(
                '日期范围',
                style: TextStyle(
                  fontSize: GlassMetrics.groupHeaderFont,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            NativeGlassMenuItem(
              label: _from == null ? '起始日期…' : '起始：${dateText(_from!)}',
              onPressed: () => _pickDate(context, start: true),
            ),
            NativeGlassMenuItem(
              label: _to == null ? '结束日期…' : '结束：${dateText(_to!)}',
              onPressed: () => _pickDate(context, start: false),
            ),
            if (hasFilterChoices) ...[
              const Divider(
                height: 8,
                thickness: GlassMetrics.groupDividerThickness,
              ),
              NativeGlassMenuItem(label: '清除筛选', onPressed: _clearFilters),
            ],
          ],
        ),
      ],
      builder: (context, controller, _) => SizedBox(
        height: GlassMetrics.hitSize,
        child: NativeGlassSurface(
          material: true,
          child: TextButton.icon(
            key: const ValueKey('history-filter-button'),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(LucideIcons.listFilter, size: GlassMetrics.icon),
            label: const Text('筛选'),
          ),
        ),
      ),
    );
  }

  /// context 为窗口上下文；构建「⋯」菜单（刷新、保留期限与未确认标注、清空全部，#67）。
  Widget _buildMoreMenu(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final retentionTitle = _retentionConfirmed ? '保留期限' : '保留期限（未确认）';
    return MenuAnchor(
      controller: _moreMenu,
      style: NativeGlassMenuPanel.anchorStyle,
      menuChildren: [
        NativeGlassMenuPanel(
          children: [
            NativeGlassMenuItem(
              label: '刷新',
              onPressed: _loading ? null : _refresh,
            ),
            const Divider(
              height: 8,
              thickness: GlassMetrics.groupDividerThickness,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Text(
                retentionTitle,
                style: TextStyle(
                  fontSize: GlassMetrics.groupHeaderFont,
                  fontWeight: FontWeight.w600,
                  color: _retentionConfirmed
                      ? colors.onSurfaceVariant
                      : colors.primary,
                ),
              ),
            ),
            for (final option
                in TranslationHistoryStore.retentionOptions.entries)
              NativeGlassMenuItem(
                label:
                    !_retentionConfirmed && option.key == (_retentionDays ?? 30)
                    ? '${option.value}（未确认）'
                    : option.value,
                checked: (_retentionDays ?? 30) == option.key,
                onPressed: _retentionDays == null || _managing
                    ? null
                    : () => _changeRetention(context, option.key),
              ),
            const Divider(
              height: 8,
              thickness: GlassMetrics.groupDividerThickness,
            ),
            NativeGlassMenuItem(
              label: '清空全部',
              onPressed: _managing ? null : () => _deleteHistory(context),
            ),
          ],
        ),
      ],
      builder: (context, controller, _) => SizedBox.square(
        dimension: GlassMetrics.hitSize,
        child: NativeGlassSurface(
          material: true,
          busy: _loading && _items.isNotEmpty,
          child: IconButton(
            key: const ValueKey('history-more-button'),
            tooltip: '更多操作',
            padding: EdgeInsets.zero,
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(LucideIcons.ellipsis, size: GlassMetrics.icon),
          ),
        ),
      ),
    );
  }

  /// label 为标签展示文字，onRemove 为点击移除该筛选条件的回调；返回可单独移除的筛选小标签。
  Widget _buildFilterChip(
    BuildContext context, {
    required String label,
    required VoidCallback onRemove,
  }) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;
    final borderColor = (dark ? Colors.white : Colors.black).withValues(
      alpha: 0.12,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.onSurface.withValues(alpha: dark ? 0.08 : 0.05),
        borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
        border: Border.all(
          color: borderColor,
          width: GlassMetrics.groupBorderWidth,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: 10, right: 4, top: 3, bottom: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: GlassMetrics.captionFont,
                height: GlassMetrics.captionLine / GlassMetrics.captionFont,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(width: GlassMetrics.space4),
            Tooltip(
              message: '移除$label筛选',
              child: InkWell(
                onTap: onRemove,
                borderRadius: BorderRadius.circular(
                  GlassMetrics.menuItemRadius,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    LucideIcons.x,
                    size: 14,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// context 为窗口内上下文；返回单行搜索/筛选/更多控件、生效筛选标签及错误横幅。
  Widget _buildManagement(BuildContext context) {
    final hasChipFilters = _source.isNotEmpty || _from != null || _to != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        GlassMetrics.pagePadding,
        GlassMetrics.space8,
        GlassMetrics.pagePadding,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: GlassMetrics.hitSize,
                  child: NativeGlassSurface(
                    material: true,
                    child: TextField(
                      key: const ValueKey('history-search'),
                      controller: _search,
                      decoration: InputDecoration(
                        hintText: '搜索原文或译文',
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: GlassMetrics.hitSize,
                          minHeight: GlassMetrics.hitSize,
                        ),
                        prefixIcon: const Icon(
                          LucideIcons.search,
                          size: GlassMetrics.icon,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 7,
                        ),
                        suffixIconConstraints: const BoxConstraints(
                          minWidth: GlassMetrics.hitSize,
                          minHeight: GlassMetrics.hitSize,
                        ),
                        suffixIcon: _search.text.isEmpty
                            ? null
                            : IconButton(
                                key: const ValueKey('history-search-clear'),
                                tooltip: '清空搜索',
                                constraints: const BoxConstraints(
                                  minWidth: GlassMetrics.hitSize,
                                  minHeight: GlassMetrics.hitSize,
                                ),
                                padding: EdgeInsets.zero,
                                icon: const Icon(
                                  LucideIcons.x,
                                  size: GlassMetrics.icon,
                                ),
                                onPressed: () {
                                  _searchDebounce?.cancel();
                                  setState(_search.clear);
                                  _loadMore(reset: true);
                                },
                              ),
                      ),
                      onChanged: _onSearchChanged,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: GlassMetrics.space8),
              _buildFilterMenu(context),
              const SizedBox(width: GlassMetrics.space8),
              _buildMoreMenu(context),
            ],
          ),
          if (hasChipFilters) ...[
            const SizedBox(height: GlassMetrics.space8),
            Wrap(
              spacing: GlassMetrics.space8,
              runSpacing: GlassMetrics.space8,
              children: [
                if (_source.isNotEmpty)
                  _buildFilterChip(
                    context,
                    label: '来源：$_source',
                    onRemove: () {
                      setState(() => _source = '');
                      _loadMore(reset: true);
                    },
                  ),
                if (_from != null)
                  _buildFilterChip(
                    context,
                    label: '自 ${dateText(_from!)}',
                    onRemove: () {
                      setState(() => _from = null);
                      _loadMore(reset: true);
                    },
                  ),
                if (_to != null)
                  _buildFilterChip(
                    context,
                    label: '至 ${dateText(_to!)}',
                    onRemove: () {
                      setState(() => _to = null);
                      _loadMore(reset: true);
                    },
                  ),
              ],
            ),
          ],
          if (_managementError != null) ...[
            const SizedBox(height: GlassMetrics.space8),
            NativeGlassBanner(
              message: _managementError!,
              isError: true,
              action: NativeGlassSurface(
                material: true,
                child: TextButton(
                  onPressed: _loadManagement,
                  child: const Text('重新读取管理设置'),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// items 为已加载的按时间倒序排列记录；按本地日历天顺序合并成日期分组。
  List<_DateRecordGroup> _groupByDate(List<TranslationRecord> items) {
    final now = DateTime.now();
    final groups =
        <({String key, String label, List<TranslationRecord> items})>[];
    for (final item in items) {
      final dt = DateTime.fromMillisecondsSinceEpoch(item.completedAt);
      final key = dateText(dt);
      if (groups.isNotEmpty && groups.last.key == key) {
        groups.last.items.add(item);
      } else {
        groups.add((
          key: key,
          label: dateGroupLabel(dt, now: now),
          items: [item],
        ));
      }
    }
    return [
      for (final group in groups)
        _DateRecordGroup(label: group.label, records: group.items),
    ];
  }

  /// context 为当前上下文，item 为单条翻译记录；返回按 #67 排版的悬停感知记录行。
  Widget _buildRecordRow(BuildContext context, TranslationRecord item) {
    final colors = Theme.of(context).colorScheme;
    final dt = DateTime.fromMillisecondsSinceEpoch(item.completedAt);
    final timestamp = dateTimeText(dt);
    final source = item.sourceLabel == null || item.sourceLabel!.isEmpty
        ? TranslationHistoryStore.unknownSource
        : item.sourceLabel!;

    return HistoryHoverRow(
      key: ValueKey('history-${item.id}'),
      builder: (context, showActions) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(
                  item.translatedText,
                  style: TextStyle(
                    fontSize: 15,
                    height: 22 / 15,
                    color: colors.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: GlassMetrics.space12),
              Text(
                '$source · ${timeText(dt)}',
                style: TextStyle(
                  fontSize: GlassMetrics.statusFont,
                  height: 16 / GlassMetrics.statusFont,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: GlassMetrics.space4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: SelectableText(
                  item.sourceText,
                  style: TextStyle(
                    fontSize: GlassMetrics.captionFont,
                    height: GlassMetrics.captionLine / GlassMetrics.captionFont,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: GlassMetrics.space8),
              HistoryHoverActions(
                visible: showActions,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HistoryHoverIconButton(
                      tooltip: '复制译文',
                      semanticsLabel: '复制 $timestamp 的译文',
                      onPressed: () => _copyItem(item),
                      icon: CopyConfirmIcon(
                        trigger: _copyTriggers[item.id] ?? 0,
                        size: GlassMetrics.icon,
                      ),
                    ),
                    HistoryHoverIconButton(
                      tooltip: '删除翻译记录',
                      semanticsLabel: '删除 $timestamp 的翻译记录',
                      onPressed: _managing
                          ? null
                          : () => _deleteHistory(context, id: item.id),
                      icon: const Icon(
                        LucideIcons.trash2,
                        size: GlassMetrics.icon,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 无参数；解除通道回调、取消待触发的搜索防抖并释放搜索输入，无返回值。
  @override
  void dispose() {
    _searchDebounce?.cancel();
    widget.channel.setMethodCallHandler(null);
    _search.dispose();
    super.dispose();
  }

  /// 无参数；返回列表末尾的加载、重试或完成提示组件。
  Widget _buildFooter() {
    if (_loading) return const CircularProgressIndicator();
    if (_pageError != null) {
      return NativeGlassBanner(
        message: _pageError!,
        isError: true,
        action: NativeGlassSurface(
          material: true,
          child: TextButton(
            onPressed: () => _loadMore(reset: _failedReset),
            child: const Text('重试加载'),
          ),
        ),
      );
    }
    if (_items.isEmpty) return const SizedBox.shrink();
    if (_done) return const Text('已显示全部历史');
    // 窗口足够高而未产生滚动时，仍提供可访问的下一批入口。
    return NativeGlassSurface(
      material: true,
      child: TextButton(onPressed: _loadMore, child: const Text('加载更多')),
    );
  }

  /// context 为当前上下文；构建翻译历史主列表区（含空状态、吸顶分组与分页末尾提示）。
  Widget _buildHistoryBody(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (_items.isEmpty && _loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty && _pageError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(GlassMetrics.pagePadding),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: _buildFooter(),
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      if (_hasActiveFilters) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(GlassMetrics.pagePadding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '没有匹配的翻译历史',
                  style: TextStyle(
                    fontSize: 15,
                    height: 22 / 15,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: GlassMetrics.space12),
                NativeGlassSurface(
                  material: true,
                  child: TextButton(
                    onPressed: _clearFilters,
                    child: const Text('清除筛选'),
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return HistoryEmptyState(
        icon: LucideIcons.languages,
        title: '还没有翻译记录',
        prefix: '在任意 App 里选中文字，按',
        shortcutTokens: _globalShortcutTokens,
        suffix: '即可翻译',
      );
    }

    final groups = _groupByDate(_items);
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // 只响应外层列表；错误后由用户显式重试，避免无限失败重试。
        if (notification.depth == 0 &&
            notification.metrics.extentAfter < 160 &&
            _pageError == null) {
          _loadMore();
        }
        return false;
      },
      child: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(
            child: SizedBox(height: GlassMetrics.space12),
          ),
          for (final group in groups)
            SliverMainAxisGroup(
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _DateGroupHeaderDelegate(
                    label: group.label,
                    background: colors.surface,
                    textColor: colors.onSurfaceVariant,
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    GlassMetrics.pagePadding,
                    0,
                    GlassMetrics.pagePadding,
                    GlassMetrics.groupGap,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: HistoryGroupCard(
                      children: [
                        for (final item in group.records)
                          _buildRecordRow(context, item),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                GlassMetrics.pagePadding,
                0,
                GlassMetrics.pagePadding,
                GlassMetrics.space24,
              ),
              child: Center(child: _buildFooter()),
            ),
          ),
        ],
      ),
    );
  }

  /// context 为窗口上下文；返回历史窗口根组件并传递当前分段标题。
  @override
  Widget build(BuildContext context) {
    return NativeGlassApp(
      title: _sectionTitle(_section),
      home: Builder(key: _pageKey, builder: _buildPage),
    );
  }

  /// 内层context订阅当前主题，确保列表缓存的显式文本样式也随外观重建。
  Widget _buildPage(BuildContext context) {
    return NativeGlassWindowPage(
      child: Scaffold(
        body: Column(
          children: [
            _buildHeader(context),
            // 首次切换到对应分段时再实例化，随后保留浏览进度、筛选与勾选状态（U-22）。
            Expanded(
              child: IndexedStack(
                index: _section.index,
                children: [
                  Column(
                    children: [
                      // 管理控件位于分段下方，保持正文独立滚动。
                      _buildManagement(context),
                      if (_recordingError != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                            GlassMetrics.pagePadding,
                            GlassMetrics.space8,
                            GlassMetrics.pagePadding,
                            0,
                          ),
                          child: NativeGlassBanner(
                            message: _recordingError!,
                            isError: true,
                            action: NativeGlassSurface(
                              material: true,
                              child: TextButton(
                                onPressed: _loadRecording,
                                child: const Text('重新读取设置'),
                              ),
                            ),
                          ),
                        ),
                      Expanded(child: _buildHistoryBody(context)),
                    ],
                  ),
                  if (_visited.contains(_HistorySection.vocabulary))
                    VocabularyPage(
                      channel: widget.channel,
                      version: _changeVersion,
                    )
                  else
                    const SizedBox.shrink(),
                  if (_visited.contains(_HistorySection.screenshots))
                    ScreenshotHistoryPage(
                      channel: widget.channel,
                      version: _changeVersion,
                      screenshotShortcutTokens: _screenshotShortcutTokens,
                    )
                  else
                    const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 翻译历史日期吸顶组头（#67）：12pt w600 次要色，左缘对齐卡片正文（24+16）。
class _DateGroupHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _DateGroupHeaderDelegate({
    required this.label,
    required this.background,
    required this.textColor,
  });

  final String label;
  final Color background;
  final Color textColor;

  /// 无参数；固定吸顶高度 32pt。
  @override
  double get minExtent => 32;

  /// 无参数；固定展开高度 32pt。
  @override
  double get maxExtent => 32;

  /// context/shrinkOffset/overlapsContent 为 SliverPersistentHeader 传入参数；返回不透底的吸顶日期标题。
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => ColoredBox(
    color: background,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        GlassMetrics.pagePadding + GlassMetrics.groupHeaderIndent,
        7,
        GlassMetrics.pagePadding,
        8,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: TextStyle(
            fontSize: GlassMetrics.captionFont,
            height: GlassMetrics.captionLine / GlassMetrics.captionFont,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
        ),
      ),
    ),
  );

  /// oldDelegate 为上一帧组头；文案或配色变化时重建。
  @override
  bool shouldRebuild(_DateGroupHeaderDelegate oldDelegate) =>
      oldDelegate.label != label ||
      oldDelegate.background != background ||
      oldDelegate.textColor != textColor;
}
