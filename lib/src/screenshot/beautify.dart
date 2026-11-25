import 'package:flutter/painting.dart';

import '../common/constants/drawing_metrics.dart';
import 'drawing_style.dart';

class BeautifyStyle {
  const BeautifyStyle({
    required this.background,
    this.padding = BeautifyMetrics.defaultPadding,
    this.cornerRadius = BeautifyMetrics.roundRadius,
    this.shadow = true,
  });
  final ColorFill background;
  final double padding;
  final double cornerRadius;
  final bool shadow;

  BeautifyStyle copyWith({
    ColorFill? background,
    double? padding,
    double? cornerRadius,
    bool? shadow,
  }) => BeautifyStyle(
    background: background ?? this.background,
    padding: padding ?? this.padding,
    cornerRadius: cornerRadius ?? this.cornerRadius,
    shadow: shadow ?? this.shadow,
  );
}

void paintBeautifyBackdrop(
  Canvas canvas,
  Rect content,
  BeautifyStyle style, {
  double unit = 1,
}) {
  final outer = content.inflate(style.padding * unit);
  final inner = RRect.fromRectAndRadius(
    content,
    Radius.circular(style.cornerRadius * unit),
  );
  final band = Path.combine(
    PathOperation.difference,
    Path()..addRect(outer),
    Path()..addRRect(inner),
  );
  final background = style.background;
  final paint = Paint()..color = background.color;
  if (background.gradient case final gradient?) {
    paint.shader = gradient.shader(background.color, outer);
  }
  canvas.drawPath(band, paint);
  if (!style.shadow) return;
  canvas.save();
  canvas.clipPath(band);
  canvas.drawRRect(
    inner.shift(Offset(0, BeautifyMetrics.shadowOffset * unit)),
    Paint()
      ..color = BeautifyMetrics.shadowColor
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        BeautifyMetrics.shadowBlur * unit / 2,
      ),
  );
  canvas.restore();
}
