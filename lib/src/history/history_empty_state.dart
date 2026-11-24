import 'package:flutter/material.dart';

import '../common/constants/glass_metrics.dart';
import '../common/widgets/native_glass.dart';

/// 历史窗口三个分段共用的空状态视图（#67「历史空状态」）：
/// 列表区居中依次展示 32pt 线性图标、15/22 粗体标题与 13/18 次要说明（可选内嵌键帽快捷键）。
class HistoryEmptyState extends StatelessWidget {
  /// icon 为 32pt 线性图标，title 为 15/22 粗体标题，prefix 为说明前缀（或完整说明），
  /// shortcutTokens 为可选键帽按键列表，suffix 为键帽后的说明后缀。
  const HistoryEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.prefix,
    this.shortcutTokens = const [],
    this.suffix = '',
  });

  final IconData icon;
  final String title;
  final String prefix;
  final List<String> shortcutTokens;
  final String suffix;

  /// context 提供明暗文字色；返回居中的空状态图标、标题及说明。
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bodyStyle = TextStyle(
      fontSize: GlassMetrics.bodyFont,
      height: GlassMetrics.bodyLine / GlassMetrics.bodyFont,
      color: colors.onSurfaceVariant,
    );
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(GlassMetrics.pagePadding),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 32, color: colors.onSurfaceVariant),
              const SizedBox(height: GlassMetrics.space8),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  height: 22 / 15,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(height: GlassMetrics.space8),
              if (shortcutTokens.isEmpty)
                Text(
                  '$prefix$suffix',
                  textAlign: TextAlign.center,
                  style: bodyStyle,
                )
              else
                Text.rich(
                  TextSpan(
                    style: bodyStyle,
                    children: [
                      TextSpan(text: prefix),
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: GlassMetrics.space4,
                          ),
                          child: NativeGlassKeycaps(tokens: shortcutTokens),
                        ),
                      ),
                      if (suffix.isNotEmpty) TextSpan(text: suffix),
                    ],
                  ),
                  textAlign: TextAlign.center,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
