import 'package:flutter/material.dart';

import '../common/constants/glass_metrics.dart';
import '../common/constants/motion_metrics.dart';
import '../common/widgets/app_motion.dart';
import '../common/widgets/native_glass.dart';

class HistoryGroupCard extends StatelessWidget {
  const HistoryGroupCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final line = (dark ? Colors.white : Colors.black).withValues(alpha: 0.10);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: dark ? const Color(0xFF232326) : Colors.white,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.groupRadius),
          side: BorderSide(color: line, width: GlassMetrics.groupBorderWidth),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: GlassMetrics.panelPadding,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: GlassMetrics.groupDividerThickness,
                    thickness: GlassMetrics.groupDividerThickness,
                    color: line,
                  ),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class HistoryHoverIconButton extends StatefulWidget {
  const HistoryHoverIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.semanticsLabel,
    this.busy = false,
  });

  final String tooltip;
  final Widget icon;
  final VoidCallback? onPressed;
  final String? semanticsLabel;
  final bool busy;

  @override
  State<HistoryHoverIconButton> createState() => _HistoryHoverIconButtonState();
}

class _HistoryHoverIconButtonState extends State<HistoryHoverIconButton> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = widget.onPressed != null && !widget.busy;
    final fillAlpha = !enabled
        ? 0.0
        : _pressed
        ? GlassMetrics.pressedOpacity
        : (_hovered || _focused)
        ? GlassMetrics.hoverOpacity
        : 0.0;

    return Semantics(
      label: widget.semanticsLabel,
      button: true,
      enabled: enabled,
      child: Tooltip(
        message: widget.tooltip,
        child: SizedBox.square(
          dimension: GlassMetrics.hitSize,
          child: Center(
            child: InkWell(
              onTap: enabled ? widget.onPressed : null,
              onHover: (value) => setState(() => _hovered = value),
              onHighlightChanged: (value) => setState(() => _pressed = value),
              onFocusChange: (value) => setState(() => _focused = value),
              borderRadius: BorderRadius.circular(GlassMetrics.menuItemRadius),
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              splashColor: Colors.transparent,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: fillAlpha > 0
                      ? colors.onSurface.withValues(alpha: fillAlpha)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(
                    GlassMetrics.menuItemRadius,
                  ),
                  border: _focused
                      ? Border.all(
                          color: colors.primary,
                          width: GlassMetrics.focusRingWidth,
                        )
                      : null,
                ),
                child: SizedBox.square(
                  dimension: 24,
                  child: Center(
                    child: IconTheme(
                      data: IconThemeData(
                        size: GlassMetrics.icon,
                        color: enabled
                            ? colors.onSurfaceVariant
                            : colors.onSurfaceVariant.withValues(alpha: 0.38),
                      ),
                      child: widget.icon,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class HistoryHoverRow extends StatefulWidget {
  const HistoryHoverRow({
    super.key,
    required this.builder,
    this.forceActionsVisible = false,
  });

  final Widget Function(BuildContext context, bool showActions) builder;
  final bool forceActionsVisible;

  @override
  State<HistoryHoverRow> createState() => _HistoryHoverRowState();
}

class _HistoryHoverRowState extends State<HistoryHoverRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final visible = _hovered || _focused || widget.forceActionsVisible;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        skipTraversal: true,
        onFocusChange: (hasFocus) {
          if (_focused != hasFocus) setState(() => _focused = hasFocus);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: widget.builder(context, visible),
        ),
      ),
    );
  }
}

class HistoryHoverActions extends StatelessWidget {
  const HistoryHoverActions({
    super.key,
    required this.visible,
    required this.child,
  });

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.reduced(context)
        ? Duration.zero
        : GlassMetrics.transition;
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: duration,
      child: IgnorePointer(ignoring: !visible, child: child),
    );
  }
}

class HistoryFieldBox extends StatelessWidget {
  const HistoryFieldBox({super.key, required this.child, this.busy = false});

  final Widget child;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return BusyRing(
      active: busy,
      color: NativeGlassTheme.accentOf(context),
      radius: GlassMetrics.controlRadius + MotionMetrics.busyRingOutset,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: dark ? const Color(0xFF232326) : Colors.white,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
            side: BorderSide(
              color: (dark ? Colors.white : Colors.black).withValues(
                alpha: 0.10,
              ),
              width: GlassMetrics.groupBorderWidth,
            ),
          ),
        ),
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
  }
}
