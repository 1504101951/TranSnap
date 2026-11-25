import 'package:flutter/material.dart';

import '../constants/glass_metrics.dart';
import 'app_tooltip.dart';
import 'native_glass.dart';

class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    this.buttonKey,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.visual = GlassMetrics.hitSize,
    this.radius = GlassMetrics.controlRadius,
    this.iconSize = GlassMetrics.icon,
    this.material = true,
    this.busy = false,
    this.tooltipAbove = true,
  });

  final Key? buttonKey;
  final String tooltip;
  final Widget icon;
  final VoidCallback? onPressed;
  final double visual;
  final double radius;
  final double iconSize;
  final bool material;
  final bool busy;
  final bool tooltipAbove;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: GlassMetrics.hitSize,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: GestureDetector(
            excludeFromSemantics: true,
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
          ),
        ),
        SizedBox.square(
          dimension: visual,
          child: NativeGlassSurface(
            material: material,
            radius: radius,
            busy: busy,
            child: AppTooltip(
              message: tooltip,
              preferAbove: tooltipAbove,
              child: IconButton(
                key: buttonKey,
                onPressed: onPressed,
                padding: EdgeInsets.zero,
                constraints: BoxConstraints.tight(Size.square(visual)),
                iconSize: iconSize,
                icon: icon,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
