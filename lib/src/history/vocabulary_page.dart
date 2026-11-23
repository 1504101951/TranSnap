import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/utils/date_text.dart';
import '../common/widgets/app_motion.dart';
import '../common/widgets/native_glass.dart';
import '../overlay/dictionary_definition.dart';
import 'vocabulary.dart';

/// 历史窗口的生词本分段；只展示主引擎生词本，删除与导出都经通道交给主引擎和系统保存面板（#102）。
class VocabularyPage extends StatefulWidget {
  /// channel 为历史窗口通道，version 递增时重新读取（主引擎通知变更后由窗口传入）。
  const VocabularyPage({
    super.key,
    required this.channel,
    required this.version,
  });
  final MethodChannel channel;
  final int version;

  /// 无参数；返回维护生词列表与导出状态的界面状态。
  @override
  State<VocabularyPage> createState() => _VocabularyPageState();
}

/// 持有最近一次读取的生词与操作反馈；数据以主引擎为准，不在窗口内另存。
class _VocabularyPageState extends State<VocabularyPage> {
  List<VocabularyEntry>? _entries;
  String? _loadError;
  String? _message;
  bool _messageIsError = false;
  bool _loading = true;
  bool _exporting = false;
  final Set<String> _deletingWords = {};
  final Map<String, int> _copyTriggers = {};

  /// 无参数；首次读取生词本，无返回值。
  @override
  void initState() {
    super.initState();
    _load();
  }

  /// old 为上一版组件；主引擎通知变更（version 变化）时重新读取，无返回值。
  @override
  void didUpdateWidget(VocabularyPage old) {
    super.didUpdateWidget(old);
    if (old.version != widget.version) _load();
  }

  /// 无参数；读取全部生词，首次加载失败时展示可重试错误，刷新失败时以横幅保留原列表。
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
          _message = reason;
          _messageIsError = true;
        }
      });
    }
  }

  /// word 为待删除单词；经危险操作确认后删除并重新读取，防止同一词条重复提交。
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
      _message = null;
      _messageIsError = false;
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
        _message = error.message ?? '删除生词失败，请重试。';
        _messageIsError = true;
      });
    } finally {
      if (mounted) setState(() => _deletingWords.remove(word));
    }
  }

  /// entry 为生词条目；复制单词、译文与释义到剪贴板并触发图标确认动效。
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

  /// 无参数；取得 CSV 后经系统保存面板保存，取消不提示，返回结束的 Future。
  Future<void> _export() async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _message = null;
      _messageIsError = false;
    });
    try {
      final csv = await widget.channel.invokeMethod<String>(
        MethodNames.vocabularyCsv,
      );
      if (csv == null) {
        if (!mounted) return;
        setState(() {
          _message = '未获取到生词本导出内容。';
          _messageIsError = true;
        });
        return;
      }
      final date = dateText(DateTime.now());
      final path = await widget.channel.invokeMethod<String>(
        MethodNames.saveTextFile,
        {'text': csv, 'suggestedName': 'TranslateApp 生词本 $date.csv'},
      );
      if (!mounted || path == null) return;
      setState(() {
        _message = '已导出到 $path';
        _messageIsError = false;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _message = error.message ?? '导出失败，请重试。';
        _messageIsError = true;
      });
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// context 提供主题；返回统一顶栏操作、状态横幅与生词卡片列表。
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _entries;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            GlassMetrics.pagePadding,
            GlassMetrics.space12,
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
              NativeGlassSurface(
                material: true,
                busy: _loading && entries != null,
                child: IconButton(
                  tooltip: '刷新生词本',
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh, size: GlassMetrics.icon),
                  visualDensity: VisualDensity.standard,
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
        const Divider(height: 1, thickness: GlassMetrics.groupDividerThickness),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              GlassMetrics.pagePadding,
              GlassMetrics.space12,
              GlassMetrics.pagePadding,
              0,
            ),
            child: NativeGlassBanner(
              message: _message!,
              isError: _messageIsError,
            ),
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
              ? const Center(child: Text('生词本为空'))
              : ListView.builder(
                  padding: const EdgeInsets.all(GlassMetrics.pagePadding),
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final date = DateTime.fromMillisecondsSinceEpoch(
                      entry.addedAt,
                    );
                    final deleting = _deletingWords.contains(entry.word);
                    return Card(
                      key: ValueKey('vocabulary-${entry.word}'),
                      margin: const EdgeInsets.only(
                        bottom: GlassMetrics.groupGap,
                      ),
                      elevation: 0,
                      child: Padding(
                        padding: const EdgeInsets.all(
                          GlassMetrics.panelPadding,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    entry.word,
                                    style: theme.textTheme.titleMedium,
                                  ),
                                ),
                                Text(
                                  dateText(date),
                                  style: theme.textTheme.bodySmall,
                                ),
                                const SizedBox(width: GlassMetrics.actionGap),
                                Semantics(
                                  label: '复制生词 ${entry.word}',
                                  button: true,
                                  child: NativeGlassSurface(
                                    material: true,
                                    child: IconButton(
                                      tooltip: '复制生词',
                                      onPressed: () => _copyEntry(entry),
                                      icon: CopyConfirmIcon(
                                        trigger:
                                            _copyTriggers[entry.word] ?? 0,
                                        size: GlassMetrics.icon,
                                      ),
                                      visualDensity: VisualDensity.standard,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: GlassMetrics.actionGap),
                                Semantics(
                                  label: '删除生词 ${entry.word}',
                                  button: true,
                                  child: NativeGlassSurface(
                                    material: true,
                                    busy: deleting,
                                    child: IconButton(
                                      tooltip: '删除生词',
                                      onPressed: deleting
                                          ? null
                                          : () => _delete(entry.word),
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        size: GlassMetrics.icon,
                                      ),
                                      visualDensity: VisualDensity.standard,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const Divider(
                              height: GlassMetrics.space16,
                              thickness: GlassMetrics.groupDividerThickness,
                            ),
                            Text('译文', style: theme.textTheme.labelLarge),
                            const SizedBox(height: GlassMetrics.space8),
                            SelectableText(
                              entry.translation,
                              style: theme.textTheme.bodyMedium,
                            ),
                            const Divider(
                              height: GlassMetrics.space16,
                              thickness: GlassMetrics.groupDividerThickness,
                            ),
                            Text('释义', style: theme.textTheme.labelLarge),
                            const SizedBox(height: GlassMetrics.space8),
                            // 复用词典结构化分行排版组件，保持与查词弹窗一致的词性、义项与例句层级。
                            DictionaryDefinitionView(
                              definition: entry.definition,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
