import '../common/constants/toolbar_grid.dart';

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../common/utils/geometry.dart';

class ScreenshotEditorLayout {
  const ScreenshotEditorLayout({
    required this.canvas,
    required this.toolbar,
    required this.axis,
  });

  final Rect canvas;
  final Rect toolbar;
  final Axis axis;

  static double _safeClamp(double value, double lo, double hi) =>
      value.clamp(lo, math.max(lo, hi)).toDouble();

  factory ScreenshotEditorLayout.place({
    required Size viewport,
    required Size image,
    required Rect crop,
    double toolbarLength = 640,
    double? centerLength,
    double thickness = ToolbarGrid.blockThickness,
    Rect? available,
    Rect? imageRect,
  }) {
    const margin = 8.0;
    const gap = 8.0;
    final viewportRect = Offset.zero & viewport;
    final canvas = imageRect ?? viewportRect;
    final safe = available?.intersect(viewportRect) ?? viewportRect;
    final selection = mapRectToFitted(crop, image, canvas);
    final horizontalLength = math.max(
      0.0,
      math.min(toolbarLength.clamp(48.0, 640.0), safe.width - margin * 2),
    );
    final verticalLength = math.max(
      0.0,
      math.min(toolbarLength.clamp(48.0, 640.0), safe.height - margin * 2),
    );
    final spanX = math.min(centerLength ?? toolbarLength, horizontalLength);
    final spanY = math.min(centerLength ?? toolbarLength, verticalLength);
    final startX = selection.center.dx - spanX / 2;
    final startY = selection.center.dy - spanY / 2;
    final left = _safeClamp(
      startX,
      safe.left + margin,
      safe.right - margin - horizontalLength,
    );
    final top = _safeClamp(
      startY,
      safe.top + margin,
      safe.bottom - margin - verticalLength,
    );
    ScreenshotEditorLayout horizontalAt(double y) => ScreenshotEditorLayout(
      canvas: canvas,
      toolbar: Rect.fromLTWH(
        left,
        _safeClamp(y, safe.top + margin, safe.bottom - margin - thickness),
        horizontalLength,
        thickness,
      ),
      axis: Axis.horizontal,
    );
    ScreenshotEditorLayout verticalAt(double x) => ScreenshotEditorLayout(
      canvas: canvas,
      toolbar: Rect.fromLTWH(
        _safeClamp(x, safe.left + margin, safe.right - margin - thickness),
        top,
        thickness,
        verticalLength,
      ),
      axis: Axis.vertical,
    );

    final rightX = selection.right + gap;
    final leftX = selection.left - gap - thickness;
    final fitsRight = rightX + thickness <= safe.right - margin;
    final fitsLeft = leftX >= safe.left + margin;
    final below = selection.bottom + gap + thickness <= safe.bottom - margin;
    final above = selection.top - gap - thickness >= safe.top + margin;
    if (below || above) {
      final centersVertically =
          startY >= safe.top + margin && startY + spanY <= safe.bottom - margin;
      if (centersVertically && startX < safe.left + margin && fitsRight) {
        return verticalAt(rightX);
      }
      if (centersVertically &&
          startX + spanX > safe.right - margin &&
          fitsLeft) {
        return verticalAt(leftX);
      }
      return horizontalAt(
        below ? selection.bottom + gap : selection.top - gap - thickness,
      );
    }
    if (fitsRight) return verticalAt(rightX);
    if (fitsLeft) return verticalAt(leftX);

    if (safe.height - margin * 2 < thickness) {
      return verticalAt(safe.right - margin - thickness);
    }
    return horizontalAt(selection.bottom - gap - thickness);
  }
}
