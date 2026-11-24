import '../common/constants/toolbar_grid.dart';

import 'dart:math' as math;

import 'package:flutter/painting.dart';

import '../common/utils/geometry.dart';

/// 截图预览与工具栏的位置；仅改变屏幕布局，不改变源图或导出裁剪坐标。
class ScreenshotEditorLayout {
  /// canvas 为图片显示矩形，toolbar 为工具栏矩形，axis 为按钮滚动方向。
  const ScreenshotEditorLayout({
    required this.canvas,
    required this.toolbar,
    required this.axis,
  });

  final Rect canvas;
  final Rect toolbar;
  final Axis axis;

  /// 将 value 夹紧到 [lo, hi]；当极窄视口导致 hi < lo 时返回 lo，避免 clamp 抛异常（U-24）。
  static double _safeClamp(double value, double lo, double hi) =>
      value.clamp(lo, math.max(lo, hi)).toDouble();

  /// viewport为窗口尺寸，image为源像素尺寸，crop为源图选区，toolbarLength为工具栏沿主轴的长度，
  /// centerLength为居中时使用的长度（分区行中最长一行，缺省为toolbarLength），
  /// thickness为工具栏各行厚度之和加行间距（默认单个分区行），available为显示器可用局部点坐标，imageRect为等比图片在视口中的矩形；
  /// 返回完整位于窗口内的工具栏（#67）：依次尝试选区下方横放、上方横放、右侧竖放、左侧竖放，都没有空白时放进选区内底边；
  /// 横放水平中心对齐选区中心，竖放竖直中心对齐选区中心。横放居中被屏幕左（右）边挡住、选区右（左）侧放得下竖放
  /// 且竖放能居中时改为竖放在该侧；选区在屏幕边角时竖放无法居中，仍横放并收回屏幕内。
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
    // 已提交选区决定布局，拖动预览不改变图片坐标系。
    final selection = mapRectToFitted(crop, image, canvas);
    final horizontalLength = math.max(
      0.0,
      math.min(toolbarLength.clamp(48.0, 640.0), safe.width - margin * 2),
    );
    final verticalLength = math.max(
      0.0,
      math.min(toolbarLength.clamp(48.0, 640.0), safe.height - margin * 2),
    );
    // 居中只按分区行长度计算，展开托盘时起点不变、托盘向尾端伸出；不超过工具栏实际长度。
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
    // horizontalAt / verticalAt 返回给定交叉轴位置的横栏与竖栏，交叉轴位置同样夹紧在屏幕内。
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
      // 横放居中被屏幕一侧挡住时改竖放到选区另一侧；竖放也无法居中（边角）时保持横放。
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

    // 横向空间不足时使用屏幕内侧竖栏，仍保留每个按钮的命中尺寸。
    if (safe.height - margin * 2 < thickness) {
      return verticalAt(safe.right - margin - thickness);
    }
    // 没有外部空白时放进选区内底边并水平居中；画布不为工具栏改变位置或显示比例。
    // 原生复制/保存只接收 EditDocument 导出，不会截入这层 UI。
    return horizontalAt(selection.bottom - gap - thickness);
  }
}
