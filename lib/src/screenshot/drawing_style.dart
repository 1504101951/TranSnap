import 'dart:ui';

import '../common/constants/screenshot_enums.dart';

class FillGradient {
  const FillGradient({
    required this.end,
    this.direction = GradientDirection.downRight,
  });
  final Color end;
  final GradientDirection direction;

  Shader shader(Color start, Rect bounds, {double opacity = 1}) {
    final (from, to) = switch (direction) {
      GradientDirection.right => (bounds.centerLeft, bounds.centerRight),
      GradientDirection.down => (bounds.topCenter, bounds.bottomCenter),
      GradientDirection.downRight => (bounds.topLeft, bounds.bottomRight),
      GradientDirection.upRight => (bounds.bottomLeft, bounds.topRight),
    };
    return Gradient.linear(from, to, [
      start.withValues(alpha: opacity),
      end.withValues(alpha: opacity),
    ]);
  }

  Map<String, Object> toMap() => {
    'to': end.toARGB32(),
    'direction': direction.name,
  };

  factory FillGradient.fromMap(Map<Object?, Object?> value) {
    final argb = value['to'] as int;
    if (argb < 0xFF000000 || argb > 0xFFFFFFFF) {
      throw const FormatException('渐变颜色无效。');
    }
    return FillGradient(
      end: Color(argb),
      direction: GradientDirection.values.byName(value['direction'] as String),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is FillGradient && other.end == end && other.direction == direction;

  @override
  int get hashCode => Object.hash(end, direction);
}

typedef ColorFill = ({Color color, FillGradient? gradient});

class DrawingStyle {
  const DrawingStyle({
    this.color = ScreenshotDefaults.strokeColor,
    this.strokeWidth = 3,
    this.gradient,
  });

  final Color color;
  final double strokeWidth;
  final FillGradient? gradient;

  ColorFill get fill => (color: color, gradient: gradient);

  DrawingStyle copyWith({Color? color, double? strokeWidth, ColorFill? fill}) =>
      DrawingStyle(
        color: fill?.color ?? color ?? this.color,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        gradient: fill != null ? fill.gradient : gradient,
      );
}

bool supportsStrokeWidth(ScreenshotTool tool) => const {
  ScreenshotTool.rect,
  ScreenshotTool.arrow,
  ScreenshotTool.brush,
}.contains(tool);

bool supportsDrawingColor(ScreenshotTool tool, ShapeMode mode) =>
    (tool == ScreenshotTool.brush && mode != ShapeMode.mosaic) ||
    tool == ScreenshotTool.rect ||
    tool == ScreenshotTool.arrow ||
    tool == ScreenshotTool.step ||
    tool == ScreenshotTool.text;
