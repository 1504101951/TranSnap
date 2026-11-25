import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'line_icon.dart';
import '../constants/glass_metrics.dart';
import 'native_glass.dart';

class ToolbarFeedback extends StatelessWidget {
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

class _FeedbackLayout extends SingleChildLayoutDelegate {
  const _FeedbackLayout(this.toolbar);
  final Rect toolbar;

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

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final space = _space(constraints.biggest);
    return BoxConstraints.loose(Size(math.min(240, space.width), space.height));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
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

  @override
  bool shouldRelayout(_FeedbackLayout oldDelegate) =>
      toolbar != oldDelegate.toolbar;
}
