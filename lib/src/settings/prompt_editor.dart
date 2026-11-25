import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/widgets/line_icon.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/text_mode.dart';
import '../common/widgets/native_glass.dart';

/// 提示词弹窗：编辑翻译、润色、纠错、解释的系统提示词与思考开关，提示词可分别恢复默认；
/// 保存返回完整的提示词与思考开关，取消返回 null（#100）。
class PromptEditor extends StatefulWidget {
  /// prompts 为四种模式的当前提示词，thinking 为四种模式的当前思考开关。
  const PromptEditor({
    super.key,
    required this.prompts,
    required this.thinking,
  });
  final Map<TextMode, String> prompts;
  final Map<TextMode, bool> thinking;

  /// 弹窗中四个字段的模式与名称，顺序即显示顺序。
  static const labels = {
    TextMode.translate: '翻译',
    TextMode.polish: '润色',
    TextMode.correct: '纠错',
    TextMode.explain: '解释',
  };

  /// 无参数；返回持有四个输入框与思考开关的状态。
  @override
  State<PromptEditor> createState() => _PromptEditorState();
}

/// 持有四个输入框与思考开关；只在保存时把内容交回设置页。
class _PromptEditorState extends State<PromptEditor> {
  late final _controllers = {
    for (final mode in PromptEditor.labels.keys)
      mode: TextEditingController(text: widget.prompts[mode]),
  };
  late final _thinking = {...widget.thinking};

  /// 无参数；释放四个输入框控制器。
  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 无参数；返回是否有空提示词，有则禁用保存。
  bool get _hasEmpty =>
      _controllers.values.any((controller) => controller.text.trim().isEmpty);

  /// mode 为处理模式，label 为字段名；经二次确认后将提示词恢复为默认模板。
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

  /// context 为弹窗上下文；返回说明、四个提示词字段与取消/保存操作。
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

  /// mode 为处理模式，label 为字段名；返回独立分卡、标题行带紧凑图标、思考开关与恢复默认的多行提示词字段，空值在框内底部就地报错。
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
                  // 内容已是默认值时无需恢复。
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
              // 顶行已渲染标题，此处置空 label 仅保留 semanticLabel 并由输入框内置 errorText 归属报错（U-13）。
              NativeGlassField(
                label: null,
                semanticLabel: label,
                errorText: error,
                child: TextField(
                  key: ValueKey('提示词-$label'),
                  controller: controller,
                  minLines: 4,
                  maxLines: 8,
                  // 修改后重新判断「恢复默认」与「保存」是否可用。
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
