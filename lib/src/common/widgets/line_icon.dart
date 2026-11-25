import 'package:flutter/widgets.dart';

import '../constants/line_icon_weights.dart';

/// 线性图标（#67「图标风格」）：按显示尺寸选用 Lucide 字重，使任何尺寸的屏幕线宽都接近 1.6pt；
/// 用法与 Icon 相同。不在字重表里的图标（新增后未重新生成表）按常规字重显示。
class LineIcon extends StatelessWidget {
  /// icon 为常规字重的 Lucide 图标（null 时只占位），size 为边长（缺省取 IconTheme），
  /// color 为线条颜色（缺省取 IconTheme），semanticLabel 为读屏名称。
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

  /// 目标屏幕线宽（pt）。
  static const targetStroke = 1.6;

  /// 可选字重到 24 单位线宽；400 为常规字重（图标原样显示）。
  static const strokes = {200: 1.0, 300: 1.55, 400: 2.0, 500: 2.5, 600: 3.0};

  /// size 为显示边长；返回屏幕线宽（线宽 × size / 24）最接近 1.6pt 的字重。
  static int weightFor(double size) => strokes.entries
      .reduce(
        (best, next) =>
            (next.value * size / 24 - targetStroke).abs() <
                (best.value * size / 24 - targetStroke).abs()
            ? next
            : best,
      )
      .key;

  /// icon 为常规字重图标，size 为显示边长；返回所选字重的常量图标，常规字重或未收录时返回原图标。
  static IconData resolve(IconData icon, double size) =>
      LineIconWeights.byWeight[weightFor(size)]?[icon.codePoint] ?? icon;

  /// context 提供 IconTheme；返回所选字重的 Icon。
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
