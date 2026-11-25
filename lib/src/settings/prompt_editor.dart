import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/widgets/line_icon.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/text_mode.dart';
import '../common/widgets/native_glass.dart';

class PromptEditor extends StatefulWidget {
  const PromptEditor({
    super.key,
    required this.prompts,
    required this.thinking,
  });
  final Map<TextMode, String> prompts;
  final Map<TextMode, bool> thinking;

  static const labels = {
    TextMode.translate: '翻译',
    TextMode.polish: '润色',
    TextMode.correct: '纠错',
    TextMode.explain: '解释',
  };

  @override
  State<PromptEditor> createState() => _PromptEditorState();
}

class _PromptEditorState extends State<PromptEditor> {
  late final _controllers = {
    for (final mode in PromptEditor.labels.keys)
      mode: TextEditingController(text: widget.prompts[mode]),
  };
  late final _thinking = {...widget.thinking};

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _hasEmpty =>
      _controllers.values.any((controller) => controller.text.trim().isEmpty);

  Future<void> _confirmReset(TextMode mode, String label) async {
    final confirmed = await NativeGlassDialog.confirm(
      context: context,
      title: '恢复默认提示词',
      message: '确定将“$label”提示词恢复为默认内容吗？当前修改将被替换。',
      confirmLabel: '恢复默认',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _controllers[mode]!.text = defaultPrompts[mode]!);
  }

  @override
  Widget build(BuildContext context) => NativeGlassDialog(
    title: const Text('提示词'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '以下提示词所有模型服务共用。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: GlassMetrics.space8),
          for (final entry in PromptEditor.labels.entries)
            _field(entry.key, entry.value),
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
          onPressed: _hasEmpty
              ? null
              : () => Navigator.pop(context, (
                  prompts: {
                    for (final entry in _controllers.entries)
                      entry.key: entry.value.text,
                  },
                  thinking: _thinking,
                )),
          child: const Text('保存'),
        ),
      ),
    ],
  );

  Widget _field(TextMode mode, String label) {
    final controller = _controllers[mode]!;
    final fallback = defaultPrompts[mode]!;
    final error = controller.text.trim().isEmpty ? '提示词不能为空。' : null;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (icon, tint) = switch (mode) {
      TextMode.translate => (LucideIcons.languages, const Color(0xFF0A84FF)),
      TextMode.polish => (LucideIcons.wandSparkles, const Color(0xFFAF52DE)),
      TextMode.correct => (LucideIcons.spellCheck, const Color(0xFF34C759)),
      TextMode.explain => (LucideIcons.lightbulb, const Color(0xFFFF9500)),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: GlassMetrics.space12),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: dark
              ? Colors.white.withValues(alpha: 0.04)
              : Colors.black.withValues(alpha: 0.025),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(GlassMetrics.space12),
            side: BorderSide(
              color: (dark ? Colors.white : Colors.black).withValues(
                alpha: dark ? 0.10 : 0.07,
              ),
              width: GlassMetrics.groupBorderWidth,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(GlassMetrics.space12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  ExcludeSemantics(
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [tint, tint.withValues(alpha: 0.78)],
                        ),
                        shape: RoundedSuperellipseBorder(
                          borderRadius: BorderRadius.circular(
                            GlassMetrics.sidebarIconRadius,
                          ),
                        ),
                      ),
                      child: SizedBox.square(
                        dimension: 24,
                        child: Center(
                          child: LineIcon(
                            icon,
                            size: 13,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: GlassMetrics.space8),
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const Text('思考', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 6),
                  NativeGlassSwitch(
                    key: ValueKey('思考-$label'),
                    label: '$label思考',
                    value: _thinking[mode]!,
                    onChanged: (value) =>
                        setState(() => _thinking[mode] = value),
                  ),
                  const SizedBox(width: GlassMetrics.actionGap),
                  NativeGlassSurface(
                    material: true,
                    child: TextButton(
                      key: ValueKey('恢复默认-$label'),
                      onPressed: controller.text == fallback
                          ? null
                          : () => _confirmReset(mode, label),
                      child: const Text('恢复默认'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: GlassMetrics.space8),
              NativeGlassField(
                label: null,
                semanticLabel: label,
                errorText: error,
                child: TextField(
                  key: ValueKey('提示词-$label'),
                  controller: controller,
                  minLines: 4,
                  maxLines: 8,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
