import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../common/constants/drawing_metrics.dart';

String colorHex(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

String rulerLabel(Offset start, Offset end) {
  final delta = end - start;
  return '${delta.distance.toStringAsFixed(1)} px'
      '（${delta.dx.abs().round()} × ${delta.dy.abs().round()}）';
}

class MeasureLayer extends StatelessWidget {
  const MeasureLayer({
    super.key,
    required this.imageSize,
    required this.ruler,
    required this.picker,
    required this.pickerColor,
  });

  final Size imageSize;
  final ({Offset start, Offset end})? ruler;
  final Offset? picker;
  final Color? pickerColor;

  @override
  Widget build(BuildContext context) {
    if (imageSize.width <= 0 || imageSize.height <= 0) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          Offset toLocal(Offset point) => Offset(
            point.dx / imageSize.width * size.width,
            point.dy / imageSize.height * size.height,
          );
          final ruler = this.ruler;
          final picker = this.picker;
          final pickerColor = this.pickerColor;
          return Stack(
            fit: StackFit.expand,
            children: [
              if (ruler != null) ...[
                CustomPaint(
                  painter: _RulerPainter(
                    start: toLocal(ruler.start),
                    end: toLocal(ruler.end),
                  ),
                ),
                _label(
                  anchor: toLocal(ruler.end),
                  canvas: size,
                  key: const Key('ruler-label'),
                  child: Text(
                    rulerLabel(ruler.start, ruler.end),
                    style: _style,
                  ),
                ),
              ],
              if (picker != null && pickerColor != null)
                _label(
                  anchor: toLocal(picker),
                  canvas: size,
                  key: const Key('eyedropper-label'),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: MeasureMetrics.swatchSize,
                        height: MeasureMetrics.swatchSize,
                        decoration: BoxDecoration(
                          color: pickerColor,
                          border: Border.all(
                            color: Colors.white,
                            width: MeasureMetrics.swatchBorder,
                          ),
                          borderRadius: BorderRadius.circular(
                            MeasureMetrics.swatchRadius,
                          ),
                        ),
                      ),
                      const SizedBox(width: MeasureMetrics.swatchGap),
                      Text(colorHex(pickerColor), style: _style),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  static const _style = TextStyle(
    color: Colors.white,
    fontSize: CropMetrics.labelFontSize,
    fontFeatures: [ui.FontFeature.tabularFigures()],
  );

  static Widget _label({
    required Offset anchor,
    required Size canvas,
    required Key key,
    required Widget child,
  }) {
    const offset = MeasureMetrics.labelOffset;
    final left = anchor.dx <= canvas.width / 2;
    final below = anchor.dy + offset + CropMetrics.labelHeight <= canvas.height;
    final rawTop = below
        ? anchor.dy + offset
        : anchor.dy - offset - CropMetrics.labelHeight;
    final clampedTop = rawTop
        .clamp(0.0, math.max(0.0, canvas.height - CropMetrics.labelHeight))
        .toDouble();
    return Positioned(
      left: left ? math.max(0.0, anchor.dx + offset) : null,
      right: left ? null : math.max(0.0, canvas.width - anchor.dx + offset),
      top: clampedTop,
      child: Container(
        key: key,
        height: CropMetrics.labelHeight,
        padding: const EdgeInsets.symmetric(
          horizontal: CropMetrics.labelPadding,
        ),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: CropMetrics.labelBackground,
          borderRadius: BorderRadius.circular(CropMetrics.labelRadius),
        ),
        child: child,
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  const _RulerPainter({required this.start, required this.end});

  final Offset start;
  final Offset end;

  @override
  void paint(Canvas canvas, Size size) {
    final delta = end - start;
    final normal = delta.distance == 0
        ? Offset.zero
        : Offset(-delta.dy, delta.dx) /
              delta.distance *
              (MeasureMetrics.tickLength / 2);
    for (final (width, color) in [
      (MeasureMetrics.outlineWidth, CropMetrics.labelBackground),
      (MeasureMetrics.lineWidth, Colors.white),
    ]) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(start, end, paint);
      if (normal == Offset.zero) continue;
      for (final point in [start, end]) {
        canvas.drawLine(point - normal, point + normal, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RulerPainter oldDelegate) =>
      oldDelegate.start != start || oldDelegate.end != end;
}
