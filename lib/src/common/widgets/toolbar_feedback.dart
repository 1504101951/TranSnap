import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'line_icon.dart';
import '../constants/glass_metrics.dart';
import 'native_glass.dart';

/// 工具栏外侧的文字反馈；支持普通轻提示与可悬停停读、带关闭入口的错误气泡（#67、#144）。
class ToolbarFeedback extends StatelessWidget {
  /// toolbar 为窗口内工具栏矩形，message 为完整响应，isError 决定错误语义图标与颜色，
  /// onHoverChanged 接收鼠标移入与移出状态以暂停错误倒计时，onDismiss 可选提供右侧关闭按钮，
  /// liveRegion 控制是否启用屏幕阅读器即时播报（连续进度刷新时可关闭）。
  const ToolbarFeedback({
    super.key,
    required this.toolbar,
    required this.message,
    this.isError = false,
    this.onHoverChanged,
    this.onDismiss,
    this.liveRegion = true,
  });

  final Rect toolbar;
  final String message;
  final bool isError;
  final ValueChanged<bool>? onHoverChanged;
  final VoidCallback? onDismiss;
  final bool liveRegion;

  /// context 为窗口主题；返回占据父 Stack 的定位层，气泡绝不进入工具栏矩形。
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final bubble = MouseRegion(
      onEnter: (_) => onHoverChanged?.call(true),
      onExit: (_) => onHoverChanged?.call(false),
      child: NativeGlassSurface(
        key: const Key('toolbar-feedback-bubble'),
        radius: GlassMetrics.controlRadius,
        child: SingleChildScrollView(
          primary: false,
          padding: EdgeInsets.fromLTRB(
            12,
            5,
            onDismiss == null ? 12 : 6,
            5,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (isError) ...[
                LineIcon(
                  LucideIcons.circleAlert,
                  size: 14,
                  color: colors.error,
                ),
                const SizedBox(width: GlassMetrics.space4),
              ],
              Flexible(
                child: Text(
                  message,
                  style: TextStyle(color: isError ? colors.error : null),
                ),
              ),
              if (onDismiss != null) ...[
                const SizedBox(width: GlassMetrics.space4),
                NativeGlassButtonFeedback(
                  radius: GlassMetrics.menuItemRadius,
                  enabled: true,
                  child: IconButton(
                    key: const Key('toolbar-feedback-dismiss'),
                    tooltip: '关闭提示',
                    onPressed: onDismiss,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: GlassMetrics.minTouchTarget,
                      height: GlassMetrics.minTouchTarget,
                    ),
                    iconSize: 14,
                    icon: const LineIcon(LucideIcons.x),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _FeedbackLayout(toolbar),
        child: liveRegion
            ? Semantics(liveRegion: true, child: bubble)
            : bubble,
      ),
    );
  }
}

/// 选择工具栏外侧空闲矩形；尺寸受该区域约束，不用覆盖工具栏的兜底坐标。
class _FeedbackLayout extends SingleChildLayoutDelegate {
  /// toolbar为逻辑点矩形；反馈优先上、下，再选择侧边。
  const _FeedbackLayout(this.toolbar);
  final Rect toolbar;

  /// size为窗口尺寸；返回一个与工具栏隔8pt的空闲矩形。
  Rect _space(Size size) {
    const gap = GlassMetrics.toastGap;
    final safe = Rect.fromLTWH(
      gap,
      gap,
      math.max(0, size.width - gap * 2),
      math.max(0, size.height - gap * 2),
    );
    final spaces = [
      Rect.fromLTRB(
        safe.left,
        safe.top,
        safe.right,
        math.max(safe.top, toolbar.top - gap),
      ),
      Rect.fromLTRB(
        safe.left,
        math.min(safe.bottom, toolbar.bottom + gap),
        safe.right,
        safe.bottom,
      ),
      Rect.fromLTRB(
        math.min(safe.right, toolbar.right + gap),
        safe.top,
        safe.right,
        safe.bottom,
      ),
      Rect.fromLTRB(
        safe.left,
        safe.top,
        math.max(safe.left, toolbar.left - gap),
        safe.bottom,
      ),
    ];
    // 常规窗口优先完整容纳一行；极窄结果窗仍限制在剩余空间，保留全部按钮命中区。
    for (final space in spaces) {
      if (space.width >= GlassMetrics.hitSize &&
          space.height >= GlassMetrics.buttonHeight) {
        return space;
      }
    }
    return spaces.reduce(
      (a, b) => a.width * a.height >= b.width * b.height ? a : b,
    );
  }

  /// constraints为窗口约束；返回不超过空闲区和240pt宽度的文字约束。
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    // _space先确定不会遮挡工具栏的区域，再允许长文字在该区域内滚动。
    final space = _space(constraints.biggest);
    return BoxConstraints.loose(Size(math.min(240, space.width), space.height));
  }

  /// size/childSize为窗口和实际气泡尺寸；返回完全位于选定空闲区内的坐标，极窄视口下保护夹紧上下界顺序。
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // _space与测量阶段使用相同区域，避免测量后重新夹紧而覆盖工具栏。
    final space = _space(size);
    final maxX = math.max(space.left, space.right - childSize.width);
    final maxY = math.max(space.top, space.bottom - childSize.height);
    return Offset(
      (toolbar.center.dx - childSize.width / 2).clamp(space.left, maxX),
      space.bottom <= toolbar.top
          ? math.max(space.top, space.bottom - childSize.height)
          : toolbar.top.clamp(space.top, maxY),
    );
  }

  /// oldDelegate为先前布局；工具栏变化时重新选择空闲区域。
  @override
  bool shouldRelayout(_FeedbackLayout oldDelegate) =>
      toolbar != oldDelegate.toolbar;
}
