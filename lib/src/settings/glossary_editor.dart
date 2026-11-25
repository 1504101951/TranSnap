import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/widgets/line_icon.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/widgets/native_glass.dart';
import '../translation/glossary.dart';
import '../translation/glossary_file.dart';
import 'app_settings.dart';

class GlossaryManager extends StatefulWidget {
  const GlossaryManager({
    super.key,
    required this.glossary,
    required this.defaultLanguage,
    required this.onChanged,
    required this.channel,
    required this.onImport,
  });

  final List<GlossaryEntry> glossary;
  final String defaultLanguage;
  final ValueChanged<List<GlossaryEntry>> onChanged;
  final MethodChannel channel;
  final Future<void> Function(List<GlossaryEntry>) onImport;

  @override
  State<GlossaryManager> createState() => _GlossaryManagerState();
}

class _GlossaryManagerState extends State<GlossaryManager> {
  late final List<GlossaryEntry> _entries = [...widget.glossary];
  String? _workingAction;
  String? _message;
  bool _messageIsError = false;

  bool get _working => _workingAction != null;

  Future<void> _import() async {
    if (_working) return;
    setState(() {
      _workingAction = 'import';
      _message = null;
      _messageIsError = false;
    });
    try {
      final file = await widget.channel.invokeMapMethod<String, String>(
        MethodNames.openGlossaryFile,
      );
      if (file == null || !mounted) return;
      final draft = parseGlossaryFile(file['text']!, format: file['format']!);
      setState(() => _workingAction = null);
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => GlossaryImportPreview(
          name: file['name']!,
          draft: draft,
          existing: [..._entries],
          onSubmit: (entries) async {
            await widget.onImport(entries);
            if (!mounted) return;
            setState(() {
              _entries
                ..clear()
                ..addAll(entries);
            });
          },
        ),
      );
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _message = error.message ?? '无法读取术语文件。';
          _messageIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _workingAction = null);
    }
  }

  Future<void> _export() async {
    if (_working) return;
    final format = await showDialog<String>(
      context: context,
      builder: (context) => NativeGlassDialog(
        maxWidth: 420,
        title: const Text('导出术语表'),
        content: const Text('选择导出格式。'),
        actions: [
          for (final (value, label) in [
            (null, '取消'),
            ('csv', 'CSV'),
            ('json', 'JSON'),
          ])
            NativeGlassSurface(
              material: true,
              child: TextButton(
                onPressed: () => Navigator.pop(context, value),
                child: Text(label),
              ),
            ),
        ],
      ),
    );
    if (format == null || !mounted) return;
    setState(() {
      _workingAction = 'export';
      _message = null;
      _messageIsError = false;
    });
    try {
      final text = exportGlossaryFile(_entries, format: format);
      final path = await widget.channel.invokeMethod<String>(
        MethodNames.saveTextFile,
        {'text': text, 'suggestedName': 'TranSnap 术语表.$format'},
      );
      if (mounted && path != null) {
        setState(() {
          _message = '已导出到 $path';
          _messageIsError = false;
        });
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() {
          _message = error.message ?? '导出失败，请重试。';
          _messageIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _workingAction = null);
    }
  }

  void _change(VoidCallback change) {
    setState(change);
    widget.onChanged([..._entries]);
  }

  Future<void> _confirmDelete(int index) async {
    final entry = _entries[index];
    final confirmed = await NativeGlassDialog.confirm(
      context: context,
      title: '删除术语',
      message: '确定删除术语“${entry.term}”吗？此操作不可撤销。',
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    _change(() => _entries.removeAt(index));
  }

  Future<void> _edit([int? index]) async {
    final entry = await showDialog<GlossaryEntry>(
      context: context,
      barrierDismissible: false,
      builder: (_) => GlossaryEditor(
        entry: index == null ? null : _entries[index],
        others: [
          for (final (i, other) in _entries.indexed)
            if (i != index) other,
        ],
        defaultLanguage: widget.defaultLanguage,
      ),
    );
    if (entry == null || !mounted) return;
    _change(() {
      if (index == null) {
        _entries.add(entry);
      } else {
        _entries[index] = entry;
      }
    });
  }

  @override
  Widget build(BuildContext context) => NativeGlassDialog(
    title: const Text('术语表'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '只对模型服务（OpenAI、DeepSeek、Anthropic）的翻译生效；译法留空表示保留原文不译。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: GlassMetrics.space8),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: GlassMetrics.space8),
            child: NativeGlassBanner(
              message: _message!,
              isError: _messageIsError,
            ),
          ),
        if (_entries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: GlassMetrics.space16),
            child: Text('暂无术语'),
          )
        else
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final (index, entry) in _entries.indexed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      entry.translation.isEmpty
                          ? '${entry.term}（保留原文）'
                          : '${entry.term} → ${entry.translation}',
                    ),
                    subtitle: Text(
                      AppSettings.languages[entry.language] ?? entry.language,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        NativeGlassSurface(
                          material: true,
                          child: IconButton(
                            tooltip: '编辑 ${entry.term}',
                            icon: const LineIcon(
                              LucideIcons.pencil,
                              size: GlassMetrics.icon,
                            ),
                            visualDensity: VisualDensity.standard,
                            onPressed: _working ? null : () => _edit(index),
                          ),
                        ),
                        const SizedBox(width: GlassMetrics.actionGap),
                        NativeGlassSurface(
                          material: true,
                          child: IconButton(
                            tooltip: '删除 ${entry.term}',
                            icon: const LineIcon(
                              LucideIcons.trash2,
                              size: GlassMetrics.icon,
                            ),
                            visualDensity: VisualDensity.standard,
                            onPressed: _working
                                ? null
                                : () => _confirmDelete(index),
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
    actions: [
      NativeGlassSurface(
        material: true,
        busy: _workingAction == 'import',
        child: TextButton(
          onPressed: _working ? null : _import,
          child: const Text('导入…'),
        ),
      ),
      NativeGlassSurface(
        material: true,
        busy: _workingAction == 'export',
        child: TextButton(
          onPressed: _working ? null : _export,
          child: const Text('导出…'),
        ),
      ),
      NativeGlassSurface(
        material: true,
        child: TextButton.icon(
          onPressed: _working ? null : () => _edit(),
          icon: const LineIcon(LucideIcons.plus, size: 18),
          label: const Text('添加术语'),
        ),
      ),
      NativeGlassSurface(
        material: true,
        child: FilledButton(
          onPressed: _working ? null : () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ),
    ],
  );
}

class GlossaryImportPreview extends StatefulWidget {
  const GlossaryImportPreview({
    super.key,
    required this.name,
    required this.draft,
    required this.existing,
    required this.onSubmit,
  });

  final String name;
  final GlossaryImport draft;
  final List<GlossaryEntry> existing;
  final Future<void> Function(List<GlossaryEntry>) onSubmit;

  @override
  State<GlossaryImportPreview> createState() => _GlossaryImportPreviewState();
}

class _GlossaryImportPreviewState extends State<GlossaryImportPreview> {
  bool _overwrite = false;
  bool _saving = false;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final entries = widget.draft.merge(
        widget.existing,
        overwrite: _overwrite,
      );
      await widget.onSubmit(entries);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = switch (error) {
          PlatformException(:final message) => message ?? '导入保存失败，请重试。',
          FormatException(:final message) => message,
          _ => '导入保存失败，请重试。',
        },
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    final duplicates = draft.duplicatePositions(widget.existing);
    final added = draft.addedCount(widget.existing);
    return PopScope(
      canPop: !_saving,
      child: NativeGlassDialog(
        title: const Text('导入术语表'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.name),
            const SizedBox(height: GlassMetrics.space8),
            Text(
              '新增 $added · 重复 ${duplicates.length} · 错误 ${draft.errorCount}',
            ),
            NativeGlassDropdown<bool>(
              label: '重复术语',
              value: _overwrite,
              items: const {false: '保留已有值', true: '覆盖已有值'},
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _overwrite = value),
            ),
            const SizedBox(height: GlassMetrics.space4),
            Text(
              '按文件顺序处理；保留取首条，覆盖取最后一条。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: GlassMetrics.space8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final row in draft.rows)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        row.error ??
                            '${row.entry!.term} → ${row.entry!.translation.isEmpty ? '（保留原文）' : row.entry!.translation}',
                        style: row.error == null
                            ? null
                            : TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                      ),
                      subtitle: Text(
                        '位置 ${row.position} · ${row.error != null
                            ? '错误'
                            : duplicates.contains(row.position)
                            ? '重复'
                            : '新增'}${row.entry == null ? '' : ' · ${row.entry!.language}'}',
                      ),
                    ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: GlassMetrics.space8),
                child: NativeGlassBanner(message: _error!, isError: true),
              ),
          ],
        ),
        actions: [
          NativeGlassSurface(
            material: true,
            child: TextButton(
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ),
          NativeGlassSurface(
            material: true,
            busy: _saving,
            child: FilledButton(
              onPressed: _saving || draft.errorCount != 0 || draft.rows.isEmpty
                  ? null
                  : _submit,
              child: Text(_saving ? '保存中…' : '确认导入'),
            ),
          ),
        ],
      ),
    );
  }
}

class GlossaryEditor extends StatefulWidget {
  const GlossaryEditor({
    super.key,
    this.entry,
    required this.others,
    required this.defaultLanguage,
  });

  final GlossaryEntry? entry;
  final List<GlossaryEntry> others;
  final String defaultLanguage;

  @override
  State<GlossaryEditor> createState() => _GlossaryEditorState();
}

class _GlossaryEditorState extends State<GlossaryEditor> {
  final _term = TextEditingController();
  final _translation = TextEditingController();
  late String _language;
  bool _duplicate = false;

  @override
  void initState() {
    super.initState();
    _term.text = widget.entry?.term ?? '';
    _translation.text = widget.entry?.translation ?? '';
    _language = widget.entry?.language ?? widget.defaultLanguage;
  }

  @override
  void dispose() {
    _term.dispose();
    _translation.dispose();
    super.dispose();
  }

  void _submit() {
    final entry = GlossaryEntry(
      term: _term.text.trim(),
      translation: _translation.text.trim(),
      language: _language,
    );
    if (widget.others.any((other) => other.key == entry.key)) {
      setState(() => _duplicate = true);
      return;
    }
    Navigator.pop(context, entry);
  }

  @override
  Widget build(BuildContext context) => NativeGlassDialog(
    title: Text(widget.entry == null ? '添加术语' : '编辑术语'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NativeGlassField(
            label: '原文术语',
            errorText: _duplicate ? '该目标语言下已有此术语。' : null,
            child: TextField(
              key: const ValueKey('原文术语'),
              controller: _term,
              onChanged: (_) => setState(() => _duplicate = false),
              decoration: const InputDecoration(),
            ),
          ),
          NativeGlassField(
            label: '译法',
            helper: '留空表示保留原文不译',
            child: TextField(
              key: const ValueKey('译法'),
              controller: _translation,
              decoration: const InputDecoration(),
            ),
          ),
          NativeGlassDropdown<String>(
            label: '目标语言',
            value: _language,
            items: {
              ...AppSettings.languages,
              if (!AppSettings.languages.containsKey(_language))
                _language: _language,
            },
            onChanged: (value) => setState(() {
              _language = value;
              _duplicate = false;
            }),
          ),
        ],
      ),
    ),
    actions: [
      NativeGlassSurface(
        material: true,
        child: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ),
      NativeGlassSurface(
        material: true,
        child: FilledButton(
          onPressed: _term.text.trim().isEmpty ? null : _submit,
          child: const Text('确定'),
        ),
      ),
    ],
  );
}
