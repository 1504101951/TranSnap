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
  /// thickness为工具栏各行厚度之和加行间距（默认单个分区行），available为显示器可用局部点坐标，imageRect为等比图片在视口中的矩形；
  /// 返回完整位于窗口内的工具栏；优先选区外侧，空间不足时贴选区内缘。
  factory ScreenshotEditorLayout.place({
    required Size viewport,
    required Size image,
    required Rect crop,
    double toolbarLength = 640,
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
    final left = _safeClamp(
      selection.left,
      safe.left + margin,
      safe.right - margin - horizontalLength,
    );
    final top = _safeClamp(
      selection.top,
      safe.top + margin,
      safe.bottom - margin - verticalLength,
    );

    // 先用下/上方的横栏；纵向没有足够空间时使用右/左侧竖栏。
    if (selection.bottom + gap + thickness <= safe.bottom - margin) {
      return ScreenshotEditorLayout(
        canvas: canvas,
        toolbar: Rect.fromLTWH(
          left,
          _safeClamp(
            selection.bottom + gap,
            safe.top + margin,
            safe.bottom - margin - thickness,
          ),
          horizontalLength,
          thickness,
        ),
        axis: Axis.horizontal,
      );
    }
    if (selection.top - gap - thickness >= safe.top + margin) {
      return ScreenshotEditorLayout(
        canvas: canvas,
        toolbar: Rect.fromLTWH(
          left,
          _safeClamp(
            selection.top - gap - thickness,
            safe.top + margin,
            safe.bottom - margin - thickness,
          ),
          horizontalLength,
          thickness,
        ),
        axis: Axis.horizontal,
      );
    }
    if (selection.right + gap + thickness <= safe.right - margin) {
      return ScreenshotEditorLayout(
        canvas: canvas,
        toolbar: Rect.fromLTWH(
          _safeClamp(
            selection.right + gap,
            safe.left + margin,
            safe.right - margin - thickness,
          ),
          top,
          thickness,
          verticalLength,
        ),
        axis: Axis.vertical,
      );
    }
    if (selection.left - gap - thickness >= safe.left + margin) {
      return ScreenshotEditorLayout(
        canvas: canvas,
        toolbar: Rect.fromLTWH(
          _safeClamp(
            selection.left - gap - thickness,
            safe.left + margin,
            safe.right - margin - thickness,
          ),
          top,
          thickness,
          verticalLength,
        ),
        axis: Axis.vertical,
      );
    }

    // 横向空间不足时使用屏幕内侧竖栏，仍保留每个按钮的命中尺寸。
    if (safe.height - margin * 2 < thickness) {
      return ScreenshotEditorLayout(
        canvas: canvas,
        axis: Axis.vertical,
        toolbar: Rect.fromLTWH(
          math.max(safe.left + margin, safe.right - margin - thickness),
          top,
          thickness,
          verticalLength,
        ),
      );
    }
    // 没有外部空白时允许覆盖选区内缘；画布不为工具栏改变位置或显示比例。
    // 原生复制/保存只接收 EditDocument 导出，不会截入这层 UI。
    return ScreenshotEditorLayout(
      canvas: canvas,
      toolbar: Rect.fromLTWH(
        _safeClamp(
          selection.right - horizontalLength,
          safe.left + margin,
          safe.right - margin - horizontalLength,
        ),
        _safeClamp(
          selection.bottom - gap - thickness,
          safe.top + margin,
          safe.bottom - margin - thickness,
        ),
        horizontalLength,
        thickness,
      ),
      axis: Axis.horizontal,
    );
  }
}
