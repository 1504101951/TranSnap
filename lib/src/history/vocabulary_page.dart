import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/widgets/line_icon.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/utils/date_text.dart';
import '../common/widgets/app_motion.dart';
import '../common/widgets/glass_icon_button.dart';
import '../common/widgets/native_glass.dart';
import '../overlay/dictionary_definition.dart';
import 'history_empty_state.dart';
import 'history_list_card.dart';
import 'vocabulary.dart';

class VocabularyPage extends StatefulWidget {
  const VocabularyPage({
    super.key,
    required this.channel,
    required this.version,
  });
  final MethodChannel channel;
  final int version;

  @override
  State<VocabularyPage> createState() => _VocabularyPageState();
}

class _VocabularyPageState extends State<VocabularyPage> {
  List<VocabularyEntry>? _entries;
  String? _loadError;
  String? _errorMessage;
  bool _loading = true;
  bool _exporting = false;
  final Set<String> _deletingWords = {};
  final Map<String, int> _copyTriggers = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(VocabularyPage old) {
    super.didUpdateWidget(old);
    if (old.version != widget.version) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      if (_entries == null) _loadError = null;
    });
    try {
      final rows = await widget.channel.invokeListMethod<Map<Object?, Object?>>(
        MethodNames.vocabularyList,
      );
      if (!mounted) return;
      setState(() {
        _entries = (rows ?? const []).map(VocabularyEntry.fromMap).toList();
        _loading = false;
        _loadError = null;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      final reason = error.message ?? '无法读取生词本';
      setState(() {
        _loading = false;
        if (_entries == null) {
          _loadError = reason;
        } else {
          _errorMessage = reason;
        }
      });
    }
  }

  Future<void> _delete(String word) async {
    if (_deletingWords.contains(word)) return;
    final confirmed = await NativeGlassDialog.confirm(
      context: context,
      title: '删除生词',
      message: '确定要删除“$word”吗？此操作不可撤销。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _deletingWords.add(word);
      _errorMessage = null;
    });
    try {
      await widget.channel.invokeMethod<void>(MethodNames.deleteVocabulary, {
        'word': word,
      });
      if (!mounted) return;
      await _load();
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.message ?? '删除生词失败，请重试。';
      });
    } finally {
      if (mounted) setState(() => _deletingWords.remove(word));
    }
  }

  Future<void> _copyEntry(VocabularyEntry entry) async {
    final content = [
      entry.word,
      if (entry.translation.trim().isNotEmpty) entry.translation,
      if (entry.definition.trim().isNotEmpty) entry.definition,
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    setState(() {
      _copyTriggers[entry.word] = (_copyTriggers[entry.word] ?? 0) + 1;
    });
  }

  Future<void> _export() async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _errorMessage = null;
    });
    try {
      final csv = await widget.channel.invokeMethod<String>(
        MethodNames.vocabularyCsv,
      );
      if (csv == null) {
        if (!mounted) return;
        setState(() => _errorMessage = '未获取到生词本导出内容。');
        return;
      }
      final date = dateText(DateTime.now());
      await widget.channel.invokeMethod<String>(MethodNames.saveTextFile, {
        'text': csv,
        'suggestedName': 'TranSnap 生词本 $date.csv',
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _errorMessage = error.message ?? '导出失败，请重试。');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Widget _buildEntryRow(BuildContext context, VocabularyEntry entry) {
    final colors = Theme.of(context).colorScheme;
    final date = DateTime.fromMillisecondsSinceEpoch(entry.addedAt);
    final deleting = _deletingWords.contains(entry.word);
    return HistoryHoverRow(
      key: ValueKey('vocabulary-${entry.word}'),
      builder: (context, showActions) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  entry.word,
                  style: TextStyle(
                    fontSize: 14,
                    height: 20 / 14,
                    color: colors.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: GlassMetrics.space12),
              Text(
                dateText(date),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (entry.translation.trim().isNotEmpty)
                      SelectableText(
                        entry.translation,
                        style: TextStyle(
                          fontSize: GlassMetrics.captionFont,
                          height:
                              GlassMetrics.captionLine /
                              GlassMetrics.captionFont,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    if (entry.definition.trim().isNotEmpty) ...[
                      if (entry.translation.trim().isNotEmpty)
                        const SizedBox(height: GlassMetrics.space4),
                      DefaultTextStyle(
                        style: TextStyle(
                          fontSize: GlassMetrics.captionFont,
                          height:
                              GlassMetrics.captionLine /
                              GlassMetrics.captionFont,
                          color: colors.onSurfaceVariant,
                        ),
                        child: DictionaryDefinitionView(
                          definition: entry.definition,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: GlassMetrics.space8),
              HistoryHoverActions(
                visible: showActions,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HistoryHoverIconButton(
                      tooltip: '复制生词',
                      semanticsLabel: '复制生词 ${entry.word}',
                      onPressed: () => _copyEntry(entry),
                      icon: CopyConfirmIcon(
                        trigger: _copyTriggers[entry.word] ?? 0,
                        size: GlassMetrics.icon,
                      ),
                    ),
                    HistoryHoverIconButton(
                      tooltip: '删除生词',
                      semanticsLabel: '删除生词 ${entry.word}',
                      busy: deleting,
                      onPressed: deleting ? null : () => _delete(entry.word),
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _entries;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            GlassMetrics.pagePadding,
            GlassMetrics.space8,
            GlassMetrics.pagePadding,
            GlassMetrics.space8,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  entries == null ? '正在读取生词本' : '共 ${entries.length} 个生词',
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              GlassIconButton(
                tooltip: '刷新生词本',
                busy: _loading && entries != null,
                onPressed: _loading ? null : _load,
                icon: const LineIcon(
                  LucideIcons.refreshCw,
                  size: GlassMetrics.icon,
                ),
              ),
              const SizedBox(width: GlassMetrics.actionGap),
              NativeGlassSurface(
                material: true,
                busy: _exporting,
                child: TextButton(
                  onPressed: _exporting || (entries?.isEmpty ?? true)
                      ? null
                      : _export,
                  child: const Text('导出 CSV'),
                ),
              ),
            ],
          ),
        ),
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              GlassMetrics.pagePadding,
              0,
              GlassMetrics.pagePadding,
              GlassMetrics.space8,
            ),
            child: NativeGlassBanner(message: _errorMessage!, isError: true),
          ),
        Expanded(
          child: entries == null && _loadError != null
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
              : entries == null
              ? const Center(child: CircularProgressIndicator())
              : entries.isEmpty
              ? const HistoryEmptyState(
                  icon: LucideIcons.bookmark,
                  title: '还没有生词',
                  prefix: '查词后在译文卡片点「加入生词本」',
                )
              : ListView(
                  padding: const EdgeInsets.all(GlassMetrics.pagePadding),
                  children: [
                    HistoryGroupCard(
                      children: [
                        for (final entry in entries)
                          _buildEntryRow(context, entry),
                      ],
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
