import 'package:flutter/material.dart';

import '../common/widgets/line_icon.dart';
import '../common/constants/glass_metrics.dart';
import '../common/widgets/native_glass.dart';

class HistoryEmptyState extends StatelessWidget {
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
              LineIcon(icon, size: 32, color: colors.onSurfaceVariant),
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
