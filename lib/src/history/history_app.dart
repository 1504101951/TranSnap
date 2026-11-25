import 'dart:async';

import '../common/widgets/line_icon.dart';
import '../common/constants/channel_names.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/constants/motion_metrics.dart';
import '../common/constants/preference_keys.dart';
import '../common/utils/date_text.dart';
import '../common/utils/shortcut_tokens.dart';
import '../common/widgets/app_motion.dart';
import '../common/widgets/window_drag_area.dart';
import '../common/widgets/native_glass.dart';

import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'history_empty_state.dart';
import 'history_list_card.dart';
import 'screenshot_history_page.dart';
import 'translation_history.dart';
import 'vocabulary_page.dart';

enum _HistorySection { history, vocabulary, screenshots }

class HistoryApp extends StatefulWidget {
  const HistoryApp({
    super.key,
    this.channel = const MethodChannel(ChannelNames.settings),
  });

  final MethodChannel channel;

  @override
  State<HistoryApp> createState() => _HistoryAppState();
}

class _DateRecordGroup {
  const _DateRecordGroup({required this.label, required this.records});

  final String label;
  final List<TranslationRecord> records;
}

class _HistoryAppState extends State<HistoryApp> {
  final _items = <TranslationRecord>[];

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

  List<String> _globalShortcutTokens = shortcutTokens(6144, 'T');
  List<String> _screenshotShortcutTokens = shortcutTokens(6144, 'S');

  _HistorySection _section = _HistorySection.history;

  final Set<_HistorySection> _visited = {_HistorySection.history};

  Timer? _searchDebounce;

  final Map<int, int> _copyTriggers = {};

  int _changeVersion = 0;

  static String _sectionTitle(_HistorySection section) => switch (section) {
    _HistorySection.history => '翻译历史',
    _HistorySection.vocabulary => '生词本',
    _HistorySection.screenshots => '截图历史',
  };

  bool get _hasActiveFilters =>
      _search.text.trim().isNotEmpty ||
      _source.isNotEmpty ||
      _from != null ||
      _to != null;

  @override
  void initState() {
    super.initState();
    widget.channel.setMethodCallHandler((call) async {
      if (call.method != MethodNames.historyChanged) return;
      setState(() => _changeVersion += 1);
      await _refresh();
    });
    _loadMore();
    _loadRecording();
    _loadManagement(prompt: true);
    _loadShortcuts();
  }

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
    } on MissingPluginException catch (_) {
    } on PlatformException catch (_) {
    }
  }

  Future<void> _syncWindowTitle(String title) async {
    try {
      await widget.channel.invokeMethod<void>(MethodNames.setWindowTitle, {
        'title': title,
      });
    } on MissingPluginException catch (_) {
    } on PlatformException catch (_) {
    }
  }

  void _selectSection(_HistorySection section) {
    setState(() {
      _section = section;
      _visited.add(section);
    });
    unawaited(_syncWindowTitle(_sectionTitle(section)));
  }

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

  Future<void> _refresh() async {
    await Future.wait([_loadMore(reset: true), _loadManagement()]);
  }

  Future<void> _loadManagement({bool prompt = false}) async {
    try {
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

  Future<void> _changeRetention(BuildContext context, int days) async {
    setState(() => _managing = true);
    try {
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

  void _onSearchChanged(String value) {
    setState(() {});
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) _loadMore(reset: true);
    });
  }

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

  Future<void> _copyItem(TranslationRecord item) async {
    await Clipboard.setData(ClipboardData(text: item.translatedText));
    if (!mounted) return;
    setState(() {
      _copyTriggers[item.id] = (_copyTriggers[item.id] ?? 0) + 1;
    });
  }

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
    await _loadMore(reset: true);
  }

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

    return LayoutBuilder(
      builder: (context, constraints) {
        final inBand =
            _section == _HistorySection.history && constraints.maxWidth >= 520;
        final below =
            _section == _HistorySection.history && constraints.maxWidth < 520;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            WindowDragArea(
              channel: widget.channel,
              child: SizedBox(
                height: GlassMetrics.compactTitlebarHeight,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    segments,
                    if (inBand)
                      Positioned(
                        right: GlassMetrics.space16,
                        top: 0,
                        bottom: 0,
                        child: recordingControl,
                      ),
                  ],
                ),
              ),
            ),
            if (below)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  GlassMetrics.pagePadding,
                  GlassMetrics.space4,
                  GlassMetrics.space16,
                  0,
                ),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: recordingControl,
                ),
              ),
          ],
        );
      },
    );
  }

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
        child: HistoryFieldBox(
          child: TextButton.icon(
            key: const ValueKey('history-filter-button'),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: const LineIcon(
              LucideIcons.listFilter,
              size: GlassMetrics.icon,
            ),
            label: const Text('筛选'),
          ),
        ),
      ),
    );
  }

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
        child: BusyRing(
          active: _loading && _items.isNotEmpty,
          color: NativeGlassTheme.accentOf(context),
          radius: GlassMetrics.controlRadius + MotionMetrics.busyRingOutset,
          child: IconButton(
            key: const ValueKey('history-more-button'),
            tooltip: '更多操作',
            padding: EdgeInsets.zero,
            style: IconButton.styleFrom(
              hoverColor: colors.onSurface.withValues(
                alpha: GlassMetrics.hoverOpacity,
              ),
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
              ),
            ),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: const LineIcon(LucideIcons.ellipsis, size: GlassMetrics.icon),
          ),
        ),
      ),
    );
  }

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
        padding: const EdgeInsets.only(left: 10),
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
            const SizedBox(width: 2),
            Tooltip(
              message: '移除$label筛选',
              child: InkWell(
                onTap: onRemove,
                borderRadius: BorderRadius.circular(
                  GlassMetrics.menuItemRadius,
                ),
                child: SizedBox.square(
                  dimension: GlassMetrics.minTouchTarget,
                  child: LineIcon(
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
                  child: HistoryFieldBox(
                    child: TextField(
                      key: const ValueKey('history-search'),
                      controller: _search,
                      decoration: InputDecoration(
                        enabledBorder: InputBorder.none,
                        hintText: '搜索原文或译文',
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: GlassMetrics.hitSize,
                          minHeight: GlassMetrics.hitSize,
                        ),
                        prefixIcon: const LineIcon(
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
                                icon: const LineIcon(
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
                    fontSize: 14,
                    height: 20 / 14,
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
                      icon: const LineIcon(
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

  @override
  void dispose() {
    _searchDebounce?.cancel();
    widget.channel.setMethodCallHandler(null);
    _search.dispose();
    super.dispose();
  }

  Widget _buildFooter() {
    if (_loading) {
      final muted = Theme.of(context).colorScheme.onSurfaceVariant;
      return Row(
        key: const ValueKey('history-loading-more'),
        mainAxisSize: MainAxisSize.min,
        children: [
          CupertinoActivityIndicator(radius: 8, color: muted),
          const SizedBox(width: GlassMetrics.space8),
          Text(
            '正在加载更早的记录',
            style: TextStyle(
              fontSize: GlassMetrics.captionFont,
              height: GlassMetrics.captionLine / GlassMetrics.captionFont,
              color: muted,
            ),
          ),
        ],
      );
    }
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
    return NativeGlassSurface(
      material: true,
      child: TextButton(onPressed: _loadMore, child: const Text('加载更多')),
    );
  }

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

  @override
  Widget build(BuildContext context) {
    return NativeGlassApp(
      title: _sectionTitle(_section),
      home: Builder(key: _pageKey, builder: _buildPage),
    );
  }

  Widget _buildPage(BuildContext context) {
    return NativeGlassWindowPage(
      child: Scaffold(
        body: Column(
          children: [
            _buildHeader(context),
            Expanded(
              child: IndexedStack(
                index: _section.index,
                children: [
                  Column(
                    children: [
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

class _DateGroupHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _DateGroupHeaderDelegate({
    required this.label,
    required this.background,
    required this.textColor,
  });

  final String label;
  final Color background;
  final Color textColor;

  @override
  double get minExtent => 32;

  @override
  double get maxExtent => 32;

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

  @override
  bool shouldRebuild(_DateGroupHeaderDelegate oldDelegate) =>
      oldDelegate.label != label ||
      oldDelegate.background != background ||
      oldDelegate.textColor != textColor;
}
