import 'package:flutter/widgets.dart';

import '../constants/line_icon_weights.dart';

class LineIcon extends StatelessWidget {
  const LineIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
  });

  final IconData? icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  static const targetStroke = 1.6;

  static const strokes = {200: 1.0, 300: 1.55, 400: 2.0, 500: 2.5, 600: 3.0};

  static int weightFor(double size) => strokes.entries
      .reduce(
        (best, next) =>
            (next.value * size / 24 - targetStroke).abs() <
                (best.value * size / 24 - targetStroke).abs()
            ? next
            : best,
      )
      .key;

  static IconData resolve(IconData icon, double size) =>
      LineIconWeights.byWeight[weightFor(size)]?[icon.codePoint] ?? icon;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    final resolvedSize = size ?? IconTheme.of(context).size ?? 24;
    return Icon(
      icon == null ? null : resolve(icon, resolvedSize),
      size: size,
      color: color,
      semanticLabel: semanticLabel,
    );
  }
}
