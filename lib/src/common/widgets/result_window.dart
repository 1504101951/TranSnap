import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'line_icon.dart';
import '../constants/glass_metrics.dart';
import '../constants/motion_metrics.dart';
import 'app_motion.dart';
import 'native_glass.dart';

abstract final class ResultWindowColors {
  static Color canvas(bool dark) =>
      dark ? const Color(0xFF1C1C1E) : const Color(0xFFE9E9EB);

  static Color bar(bool dark) =>
      dark ? const Color(0xFF2A2A2D) : const Color(0xFFFBFBFC);

  static Color tray(bool dark) =>
      dark ? const Color(0xFF1D1D1F) : const Color(0xFFECECED);

  static Color hairline(bool dark) =>
      (dark ? Colors.white : Colors.black).withValues(alpha: 0.12);

  static Color mediaBorder(bool dark) =>
      dark ? const Color(0x1AFFFFFF) : const Color(0x2E000000);

  static Color mediaShadow(bool dark) =>
      dark ? const Color(0x73000000) : const Color(0x2E000000);
}

class ResultWindowCanvas extends StatelessWidget {
  const ResultWindowCanvas({
    super.key,
    required this.child,
    this.alignment = Alignment.center,
    this.backgroundColor,
  });

  final Widget child;
  final AlignmentGeometry alignment;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ColoredBox(
      key: const Key('result-window-canvas'),
      color: backgroundColor ?? ResultWindowColors.canvas(dark),
      child: Align(alignment: alignment, child: child),
    );
  }
}

class ResultMediaFrame extends StatelessWidget {
  const ResultMediaFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: ResultWindowColors.mediaShadow(dark),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: Border.all(
            color: ResultWindowColors.mediaBorder(dark),
            width: 0.5,
          ),
        ),
        child: child,
      ),
    );
  }
}

class ResultWindowBar extends StatelessWidget {
  const ResultWindowBar({
    super.key,
    required this.leading,
    required this.trailing,
  });

  final List<Widget> leading;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      key: const Key('result-window-bar'),
      height: GlassMetrics.resultBarHeight,
      decoration: BoxDecoration(
        color: ResultWindowColors.bar(dark),
        border: Border(
          top: BorderSide(color: ResultWindowColors.hairline(dark), width: 0.5),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          primary: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: GlassMetrics.space12,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: _withGap(leading),
                  ),
                  const SizedBox(width: GlassMetrics.space12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: _withGap(trailing),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _withGap(List<Widget> items) {
    if (items.isEmpty) return const [];
    return [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) const SizedBox(width: GlassMetrics.space4),
        items[i],
      ],
    ];
  }
}

class ResultBarDivider extends StatelessWidget {
  const ResultBarDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: GlassMetrics.resultDividerGap,
      ),
      child: SizedBox(
        width: GlassMetrics.resultDividerWidth,
        height: GlassMetrics.resultDividerHeight,
        child: ColoredBox(color: ResultWindowColors.hairline(dark)),
      ),
    );
  }
}

class ResultTextButton extends StatelessWidget {
  const ResultTextButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.trailing,
    this.primary = false,
    this.weak = false,
    this.busy = false,
    this.tooltip,
    this.buttonKey,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final IconData? trailing;
  final bool primary;
  final bool weak;
  final bool busy;
  final String? tooltip;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final accentFill = NativeGlassTheme.accentFillOf(context);
    final onAccent = NativeGlassTheme.onAccentOf(context);
    final fg = primary
        ? onAccent
        : weak
        ? colors.onSurfaceVariant
        : colors.onSurface;
    final effectiveFg = enabled ? fg : fg.withValues(alpha: 0.42);
    final bg = primary
        ? (enabled ? accentFill : accentFill.withValues(alpha: 0.42))
        : Colors.transparent;

    Widget button = DecoratedBox(
      decoration: ShapeDecoration(
        color: bg,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
        ),
      ),
      child: NativeGlassButtonFeedback(
        radius: GlassMetrics.controlRadius,
        enabled: enabled,
        bezel: false,
        child: SizedBox(
          height: GlassMetrics.buttonHeight,
          child: TextButton(
            key: buttonKey,
            onPressed: onPressed,
            style: ButtonStyle(
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: GlassMetrics.space12),
              ),
              minimumSize: const WidgetStatePropertyAll(
                Size(0, GlassMetrics.buttonHeight),
              ),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
              overlayColor: WidgetStatePropertyAll(
                primary
                    ? onAccent.withValues(alpha: 0.10)
                    : colors.onSurface.withValues(
                        alpha: GlassMetrics.hoverOpacity,
                      ),
              ),
              foregroundColor: WidgetStatePropertyAll(effectiveFg),
              shape: WidgetStatePropertyAll(
                RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(
                    GlassMetrics.controlRadius,
                  ),
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  LineIcon(icon, size: 14, color: effectiveFg),
                  const SizedBox(width: GlassMetrics.iconGap),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: GlassMetrics.bodyFont,
                    height: GlassMetrics.bodyLine / GlassMetrics.bodyFont,
                    fontWeight: primary ? FontWeight.w500 : FontWeight.w400,
                    color: effectiveFg,
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 2),
                  LineIcon(trailing, size: 14, color: effectiveFg),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (tooltip != null) {
      button = Tooltip(message: tooltip!, child: button);
    }
    return BusyRing(
      active: busy,
      color: NativeGlassTheme.accentOf(context),
      radius: GlassMetrics.controlRadius + MotionMetrics.busyRingOutset,
      child: button,
    );
  }
}

class ResultIconButton extends StatelessWidget {
  const ResultIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.compact = false,
    this.busy = false,
    this.buttonKey,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final bool compact;
  final bool busy;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final accentFill = NativeGlassTheme.accentFillOf(context);
    final onAccent = NativeGlassTheme.onAccentOf(context);
    final size = compact ? 28.0 : GlassMetrics.hitSize;
    final radius = compact ? 7.0 : GlassMetrics.controlRadius;
    final iconSize = compact ? 14.0 : GlassMetrics.icon;
    final fg = selected ? onAccent : colors.onSurface;
    final effectiveFg = enabled ? fg : fg.withValues(alpha: 0.42);
    final bg = selected
        ? (enabled ? accentFill : accentFill.withValues(alpha: 0.42))
        : Colors.transparent;

    return BusyRing(
      active: busy,
      color: NativeGlassTheme.accentOf(context),
      radius: radius + MotionMetrics.busyRingOutset,
      child: Semantics(
        selected: selected,
        label: tooltip,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: bg,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(radius),
            ),
          ),
          child: NativeGlassButtonFeedback(
            radius: radius,
            enabled: enabled,
            bezel: false,
            child: SizedBox.square(
              dimension: size,
              child: IconButton(
                key: buttonKey,
                tooltip: tooltip,
                onPressed: onPressed,
                style: ButtonStyle(
                  padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                  backgroundColor: const WidgetStatePropertyAll(
                    Colors.transparent,
                  ),
                  overlayColor: WidgetStatePropertyAll(
                    selected
                        ? onAccent.withValues(alpha: 0.10)
                        : colors.onSurface.withValues(
                            alpha: GlassMetrics.hoverOpacity,
                          ),
                  ),
                  foregroundColor: WidgetStatePropertyAll(effectiveFg),
                  shape: WidgetStatePropertyAll(
                    RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(radius),
                    ),
                  ),
                ),
                icon: LineIcon(icon, size: iconSize, color: effectiveFg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ResultUpwardTray extends StatelessWidget {
  const ResultUpwardTray({
    super.key,
    required this.children,
    required this.anchorCenterX,
  });

  final List<Widget> children;
  final double anchorCenterX;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final trayColor = ResultWindowColors.tray(dark);
    final hairline = ResultWindowColors.hairline(dark);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        DecoratedBox(
          decoration: ShapeDecoration(
            color: trayColor,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(9),
              side: BorderSide(color: hairline, width: 0.5),
            ),
            shadows: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
        Positioned.fill(
          child: LayoutBuilder(
            builder: (context, constraints) => Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: (anchorCenterX - 6).clamp(
                    8.0,
                    math.max(8.0, constraints.maxWidth - 8 - 12),
                  ),
                  bottom: -4,
                  child: CustomPaint(
                    size: const Size(12, 4),
                    painter: _DownCaretPainter(trayColor),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _DownCaretPainter extends CustomPainter {
  const _DownCaretPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_DownCaretPainter old) => old.color != color;
}
