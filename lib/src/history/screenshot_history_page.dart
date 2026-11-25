import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/widgets/line_icon.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/utils/date_text.dart';
import '../common/widgets/app_motion.dart';
import '../common/widgets/native_glass.dart';
import 'history_empty_state.dart';
import 'screenshot_compose_dialogs.dart';
import 'screenshot_history.dart';

/// 截图历史操作失败且主引擎没有给出原因时的提示（#131）。
const _operationFailed = '操作失败，请重试。';

/// 历史窗口的截图分段；数据以主引擎为准，文件操作交给原生（#29）。
class ScreenshotHistoryPage extends StatefulWidget {
  /// channel 为历史窗口通道，version 递增时重新读取（主引擎通知变更后由窗口传入），
  /// screenshotShortcutTokens 为当前区域截图快捷键键帽序列。
  const ScreenshotHistoryPage({
    super.key,
    required this.channel,
    required this.version,
    this.screenshotShortcutTokens = const ['⌥', '⌃', 'S'],
  });
  final MethodChannel channel;
  final int version;
  final List<String> screenshotShortcutTokens;

  /// 缩略图宽度与最高高度，单位为点，对应样式Spec #67。
  static const thumbnailWidth = 240.0;
  static const thumbnailMaxHeight = 180.0;

  /// 无参数；返回维护截图列表与开关的界面状态。
  @override
  State<ScreenshotHistoryPage> createState() => _ScreenshotHistoryPageState();
}

/// 持有最近一次读取的截图记录、开关、勾选与操作反馈；不在窗口内另存数据。
class _ScreenshotHistoryPageState extends State<ScreenshotHistoryPage> {
  List<ScreenshotRecord>? _records;
  bool? _recording;
  String? _loadError;
  String? _errorMessage;
  bool _loading = true;
  String? _busyAction;

  /// 勾选的记录 id，用于拼接、拆分与比较（#109）；只在本页保存。
  Set<int> _selected = {};

  /// 每条截图记录的复制按钮触发计数，用于驱动 CopyConfirmIcon 反馈动效。
  final Map<int, int> _copyTriggers = {};

  /// 无参数；返回勾选的记录，按截图时间先后（同一时刻按 id）排列。
  List<ScreenshotRecord> get _chosen =>
      [
        for (final record in _records ?? const <ScreenshotRecord>[])
          if (_selected.contains(record.id)) record,
      ]..sort(
        (a, b) => a.capturedAt != b.capturedAt
            ? a.capturedAt.compareTo(b.capturedAt)
            : a.id.compareTo(b.id),
      );

  /// 无参数；首次读取列表与开关，无返回值。
  @override
  void initState() {
    super.initState();
    _load();
  }

  /// old 为上一版组件；主引擎通知变更（version 变化）时重新读取，无返回值。
  @override
  void didUpdateWidget(ScreenshotHistoryPage old) {
    super.didUpdateWidget(old);
    if (old.version != widget.version) _load();
  }

  /// 无参数；读取截图记录与「记录截图历史」开关，首次失败展示可重试错误，刷新失败以横幅提示。
  Future<void> _load() async {
    setState(() {
      _loading = true;
      if (_records == null) _loadError = null;
    });
    try {
      final rows = await widget.channel.invokeListMethod<Map<Object?, Object?>>(
        MethodNames.screenshotHistoryList,
      );
      final recording = await widget.channel.invokeMethod<bool>(
        MethodNames.screenshotHistoryRecording,
      );
      if (!mounted) return;
      final records = (rows ?? const []).map(ScreenshotRecord.fromMap).toList();
      setState(() {
        _records = records;
        _recording = recording ?? false;
        _loading = false;
        _loadError = null;
        // 只保留仍存在且图片未缺失的勾选。
        _selected = {
          for (final record in records)
            if (record.exists && _selected.contains(record.id)) record.id,
        };
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      final reason = error.message ?? '无法读取截图历史';
      setState(() {
        _loading = false;
        if (_records == null) {
          _loadError = reason;
        } else {
          _errorMessage = reason;
        }
      });
    }
  }

  /// method/arguments 为原生调用参数，reload 控制完成后是否重读列表，busyKey 为忙碌锁键；返回是否执行成功。
  Future<bool> _run(
    String method, [
    Map<String, Object>? arguments,
    bool reload = false,
    String? busyKey,
  ]) async {
    if (_busyAction != null) return false;
    setState(() {
      _errorMessage = null;
      if (busyKey != null) _busyAction = busyKey;
    });
    try {
      await widget.channel.invokeMethod<Object?>(method, arguments);
      if (!mounted) return false;
      if (reload) await _load();
      return true;
    } on PlatformException catch (error) {
      if (!mounted) return false;
      setState(() {
        _errorMessage = error.message ?? _operationFailed;
      });
      return false;
    } finally {
      if (mounted && busyKey != null) setState(() => _busyAction = null);
    }
  }

  /// 无参数；经确认弹窗后清空全部截图历史与磁盘文件，防止误触清空。
  Future<void> _clearAll() async {
    if (_busyAction != null) return;
    final confirmed = await NativeGlassDialog.confirm(
      context: context,
      title: '清空截图历史',
      message: '确定要清空全部截图历史吗？此操作将移除所有历史记录和截图文件，且不可撤销。',
      confirmLabel: '清空',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _run(MethodNames.clearScreenshotHistory, null, true, 'clear');
  }

  /// record 为待删截图记录；经确认弹窗后删除记录与文件，防止误删。
  Future<void> _deleteRecord(ScreenshotRecord record) async {
    if (_busyAction != null) return;
    final timestamp = dateTimeText(
      DateTime.fromMillisecondsSinceEpoch(record.capturedAt),
    );
    final confirmed = await NativeGlassDialog.confirm(
      context: context,
      title: '删除截图',
      message:
          '确定要删除 $timestamp（${record.width}×${record.height}）的截图吗？此操作不可撤销。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _run(
      MethodNames.deleteScreenshotHistory,
      {'id': record.id},
      true,
      'delete-${record.id}',
    );
  }

  /// record 为目标截图记录；复制图片到剪贴板并触发图标确认动效。
  Future<void> _copyImage(ScreenshotRecord record) async {
    final copied = await _run(MethodNames.copyImageFile, {'path': record.path});
    if (!copied || !mounted) return;
    setState(() {
      _copyTriggers[record.id] = (_copyTriggers[record.id] ?? 0) + 1;
    });
  }

  /// action 为操作标识（'stitch' / 'split'），produce 调用原生生成结果图片；
  /// 把结果加入截图历史、清空勾选并重新读取，失败显示错误横幅（#109）。
  Future<void> _compose(
    String action,
    Future<List<Uint8List>> Function() produce,
  ) async {
    if (_busyAction != null) return;
    setState(() {
      _busyAction = action;
      _errorMessage = null;
    });
    try {
      final images = await produce();
      await widget.channel.invokeMethod<void>(
        MethodNames.addScreenshotHistory,
        {'images': images},
      );
      if (!mounted) return;
      setState(() => _selected = {});
      await _load();
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.message ?? _operationFailed;
      });
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  /// 无参数；选择方向后按时间先后拼接勾选的截图，返回结束的 Future。
  Future<void> _stitch() async {
    final chosen = _chosen;
    if (_busyAction != null || chosen.length < 2) return;
    // StitchDialog 返回纵向（true）或横向（false），取消为 null。
    final vertical = await showDialog<bool>(
      context: context,
      builder: (_) => StitchDialog(count: chosen.length),
    );
    if (vertical == null || !mounted) return;
    await _compose('stitch', () async {
      final result = await widget.channel.invokeMethod<Uint8List>(
        MethodNames.stitchScreenshots,
        {
          'paths': [for (final record in chosen) record.path],
          'vertical': vertical,
        },
      );
      if (result == null) {
        throw PlatformException(
          code: 'INVALID_RESULT',
          message: _operationFailed,
        );
      }
      return [result];
    });
  }

  /// 无参数；选择段数后按高度等分勾选的截图，返回结束的 Future。
  Future<void> _split() async {
    final chosen = _chosen;
    if (_busyAction != null || chosen.length != 1) return;
    final record = chosen.single;
    if (record.height < 2) return;
    // SplitDialog 返回 2–10 的段数，取消为 null。
    final parts = await showDialog<int>(
      context: context,
      builder: (_) => SplitDialog(height: record.height),
    );
    if (parts == null || !mounted) return;
    await _compose('split', () async {
      final result = await widget.channel.invokeListMethod<Uint8List>(
        MethodNames.splitScreenshot,
        {'path': record.path, 'parts': parts},
      );
      if (result == null) {
        throw PlatformException(
          code: 'INVALID_RESULT',
          message: _operationFailed,
        );
      }
      return result;
    });
  }

  /// 无参数；原生逐像素比较勾选的两张截图后打开并排比较弹窗，失败显示原因，返回结束的 Future。
  Future<void> _compare() async {
    final chosen = _chosen;
    if (_busyAction != null || chosen.length != 2) return;
    setState(() {
      _busyAction = 'compare';
      _errorMessage = null;
    });
    Map<String, Object?>? result;
    try {
      result = await widget.channel.invokeMapMethod<String, Object?>(
        MethodNames.compareScreenshots,
        {'first': chosen[0].path, 'second': chosen[1].path},
      );
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = error.message ?? _operationFailed;
        });
      }
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
    if (!mounted || result == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => ScreenshotCompareDialog(
        first: chosen[0],
        second: chosen[1],
        mask: result!['mask'] as Uint8List,
        different: result['different'] as int,
        total: result['total'] as int,
      ),
    );
  }

  /// context 提供主题；返回开关栏、批量合成工具条、状态横幅与截图卡片列表。
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final records = _records;
    final chosen = _chosen;
    final canSplit = chosen.length == 1 && chosen.single.height >= 2;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            GlassMetrics.pagePadding,
            GlassMetrics.space12,
            GlassMetrics.pagePadding,
            GlassMetrics.space8,
          ),
          child: SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: GlassMetrics.actionGap,
              runSpacing: GlassMetrics.space8,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('记录截图历史'),
                    const SizedBox(width: GlassMetrics.actionGap),
                    NativeGlassSwitch(
                      label: '记录截图历史',
                      value: _recording ?? false,
                      onChanged: _recording == null || _busyAction != null
                          ? null
                          : (enabled) async {
                              await _run(
                                MethodNames.setScreenshotHistoryRecording,
                                {'enabled': enabled},
                                true,
                              );
                            },
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    NativeGlassSurface(
                      material: true,
                      busy: _loading && records != null,
                      child: IconButton(
                        tooltip: '刷新截图历史',
                        onPressed: _loading ? null : _load,
                        icon: const LineIcon(
                          LucideIcons.refreshCw,
                          size: GlassMetrics.icon,
                        ),
                        visualDensity: VisualDensity.standard,
                      ),
                    ),
                    const SizedBox(width: GlassMetrics.actionGap),
                    NativeGlassSurface(
                      material: true,
                      busy: _busyAction == 'clear',
                      child: TextButton(
                        onPressed:
                            _busyAction != null ||
                                records == null ||
                                records.isEmpty
                            ? null
                            : _clearAll,
                        child: const Text('清空截图历史'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        // 勾选后的拼接（≥2 张）、拆分（1 张且高度≥2px）与比较（2 张）（#109）。
        if (records != null && records.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              GlassMetrics.pagePadding,
              0,
              GlassMetrics.pagePadding,
              GlassMetrics.space8,
            ),
            child: SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: GlassMetrics.actionGap,
                runSpacing: GlassMetrics.space8,
                children: [
                  Text(
                    '已选 ${_selected.length} 张',
                    style: theme.textTheme.bodySmall,
                  ),
                  Wrap(
                    spacing: GlassMetrics.actionGap,
                    runSpacing: GlassMetrics.space8,
                    children: [
                      for (final (id, label, enabled, action) in [
                        ('stitch', '拼接', _selected.length >= 2, _stitch),
                        ('split', '拆分', canSplit, _split),
                        ('compare', '比较', _selected.length == 2, _compare),
                      ])
                        NativeGlassSurface(
                          material: true,
                          busy: _busyAction == id,
                          child: TextButton(
                            onPressed: _busyAction == null && enabled
                                ? action
                                : null,
                            child: Text(label),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        const Divider(height: 1, thickness: GlassMetrics.groupDividerThickness),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              GlassMetrics.pagePadding,
              GlassMetrics.space12,
              GlassMetrics.pagePadding,
              0,
            ),
            child: NativeGlassBanner(message: _errorMessage!, isError: true),
          ),
        Expanded(
          child: records == null && _loadError != null
              ? Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 360),
                    child: Padding(
                      padding: const EdgeInsets.all(GlassMetrics.pagePadding),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          NativeGlassBanner(
                            message: _loadError!,
                            isError: true,
                          ),
                          const SizedBox(height: GlassMetrics.space12),
                          NativeGlassSurface(
                            material: true,
                            child: FilledButton(
                              onPressed: _load,
                              child: const Text('重试加载'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : records == null
              ? const Center(child: CircularProgressIndicator())
              : records.isEmpty
              ? HistoryEmptyState(
                  icon: LucideIcons.scan,
                  title: '还没有截图记录',
                  prefix: '按',
                  shortcutTokens: widget.screenshotShortcutTokens,
                  suffix: '截图后自动记录',
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(GlassMetrics.pagePadding),
                  itemCount: records.length,
                  itemBuilder: (context, index) => _card(theme, records[index]),
                ),
        ),
      ],
    );
  }

  /// theme 为当前主题，record 为一条截图历史；返回缩略图、时间、尺寸与操作按钮组成的卡片。
  Widget _card(ThemeData theme, ScreenshotRecord record) {
    final timestamp = dateTimeText(
      DateTime.fromMillisecondsSinceEpoch(record.capturedAt),
    );
    // 缩略图按原图比例缩放到 240pt 宽，过高时限制在 180pt。
    final height = record.width == 0
        ? ScreenshotHistoryPage.thumbnailMaxHeight
        : (ScreenshotHistoryPage.thumbnailWidth * record.height / record.width)
              .clamp(1.0, ScreenshotHistoryPage.thumbnailMaxHeight);
    final path = {'path': record.path};
    final deleting = _busyAction == 'delete-${record.id}';

    /// tooltip/icon/onPressed 为按钮提示、图标与回调；返回统一样式的玻璃图标按钮。
    Widget action(
      String tooltip,
      Widget icon,
      VoidCallback? onPressed, {
      bool busy = false,
      String? semanticsLabel,
    }) => Semantics(
      label: semanticsLabel,
      button: semanticsLabel != null,
      child: NativeGlassSurface(
        material: true,
        busy: busy,
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          icon: icon,
          visualDensity: VisualDensity.standard,
        ),
      ),
    );

    return Card(
      key: ValueKey('screenshot-history-${record.id}'),
      margin: const EdgeInsets.only(bottom: GlassMetrics.groupGap),
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(GlassMetrics.panelPadding),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 图片缺失的记录不可勾选（#109）。
            Checkbox(
              value: _selected.contains(record.id),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              semanticLabel: '选择 $timestamp 截图',
              onChanged: record.exists && _busyAction == null
                  ? (checked) => setState(
                      () => checked == true
                          ? _selected.add(record.id)
                          : _selected.remove(record.id),
                    )
                  : null,
            ),
            const SizedBox(width: GlassMetrics.actionGap),
            SizedBox(
              width: ScreenshotHistoryPage.thumbnailWidth,
              height: height,
              child: record.exists
                  ? Image.file(
                      File(record.path),
                      fit: BoxFit.contain,
                      cacheWidth: (ScreenshotHistoryPage.thumbnailWidth * 2)
                          .round(),
                      errorBuilder: (context, error, stackTrace) => ColoredBox(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Center(
                          child: Text(
                            '截图文件不可用',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ),
                    )
                  : const Center(child: Text('图片文件已缺失')),
            ),
            const SizedBox(width: GlassMetrics.space12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(timestamp, style: theme.textTheme.bodySmall),
                  const SizedBox(height: GlassMetrics.space4),
                  Text(
                    '${record.width} × ${record.height}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: GlassMetrics.space8),
                  Wrap(
                    spacing: GlassMetrics.actionGap,
                    runSpacing: GlassMetrics.actionGap,
                    children: [
                      // 文件缺失时只保留删除。
                      if (record.exists) ...[
                        action(
                          '打开',
                          const LineIcon(
                            LucideIcons.externalLink,
                            size: GlassMetrics.icon,
                          ),
                          _busyAction == null
                              ? () => _run(MethodNames.openFile, path)
                              : null,
                        ),
                        action(
                          '复制图片',
                          CopyConfirmIcon(
                            trigger: _copyTriggers[record.id] ?? 0,
                            size: GlassMetrics.icon,
                          ),
                          _busyAction == null ? () => _copyImage(record) : null,
                        ),
                        action(
                          '在 Finder 中显示',
                          const LineIcon(
                            LucideIcons.folderOpen,
                            size: GlassMetrics.icon,
                          ),
                          _busyAction == null
                              ? () => _run(MethodNames.revealFile, path)
                              : null,
                        ),
                      ],
                      action(
                        '删除截图',
                        const LineIcon(
                          LucideIcons.trash2,
                          size: GlassMetrics.icon,
                        ),
                        _busyAction == null
                            ? () => _deleteRecord(record)
                            : null,
                        busy: deleting,
                        semanticsLabel: '删除 $timestamp 截图',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
