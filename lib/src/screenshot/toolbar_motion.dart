import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../common/constants/motion_metrics.dart';
import '../common/widgets/app_motion.dart';
import '../common/widgets/app_tooltip.dart';
import 'toolbar_layout.dart';

typedef _Ghost = ({ToolbarCells group, Offset offset, Size size});

class ToolbarMotion extends StatefulWidget {
  const ToolbarMotion({
    super.key,
    required this.builder,
    required this.ghostBuilder,
  });

  final Widget Function(BuildContext context, ToolbarMotionState motion)
  builder;
  final Widget Function(ToolbarCells group) ghostBuilder;

  @override
  State<ToolbarMotion> createState() => ToolbarMotionState();
}

class ToolbarMotionState extends State<ToolbarMotion>
    with TickerProviderStateMixin {
  final _favoritesKey = GlobalKey();
  final _blockKeys = <String, GlobalKey>{};
  late final _glide = AnimationController.unbounded(vsync: this, value: 1);
  late final _merge = AnimationController.unbounded(vsync: this, value: 1);
  Offset _shift = Offset.zero;
  bool _splitting = false;
  List<_Ghost> _ghosts = const [];
  Size _ghostTarget = Size.zero;

  Offset get _offset => _shift * (1 - _glide.value);

  void reset() {
    _shift = Offset.zero;
    _glide.value = 1;
    _merge.value = 1;
    _ghosts = const [];
    _splitting = false;
  }

  void prepare({required bool expand, required List<ToolbarCells> grid}) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final before = _favoritesPosition();
    final ghosts = expand || reduced || before == null
        ? const <_Ghost>[]
        : _departing(grid, before);
    final favorites = _favoritesKey.currentContext?.size ?? Size.zero;
    _merge.stop();
    setState(() {
      _splitting = expand;
      _ghosts = ghosts;
      _ghostTarget = favorites;
    });
    if (expand) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _splitting = false);
    } else if (ghosts.isNotEmpty) {
      _merge.value = 0;
      _merge
          .animateWith(SpringSimulation(AppMotion.settleSpring, 0, 1, 0))
          .then((_) {
            if (mounted) setState(() => _ghosts = const []);
          });
    }
    _glideFrom(before);
  }

  Widget favorites(Widget child) =>
      KeyedSubtree(key: _favoritesKey, child: child);

  Widget gridBlock(String key, Widget child) => LiquidBlockSplit(
    key: ValueKey('split-$key'),
    origin: _favoritesKey,
    order: int.tryParse(key.split('-').last) ?? 0,
    entering: _splitting,
    child: KeyedSubtree(
      key: _blockKeys.putIfAbsent(key, GlobalKey.new),
      child: child,
    ),
  );

  Offset? _favoritesPosition() {
    final box = _favoritesKey.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize
        ? box.localToGlobal(Offset.zero)
        : null;
  }

  List<_Ghost> _departing(List<ToolbarCells> grid, Offset favorites) => [
    for (final group in grid)
      if (_blockKeys[group.key]?.currentContext?.findRenderObject()
          case final RenderBox box when box.attached && box.hasSize)
        (
          group: group,
          offset: box.localToGlobal(Offset.zero) - favorites,
          size: box.size,
        ),
  ];

  void _glideFrom(Offset? before) {
    if (before == null || MediaQuery.disableAnimationsOf(context)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final after = _favoritesPosition();
      if (!mounted || after == null) return;
      final shift = before - (after - _offset);
      if (shift.distance < 0.5) return;
      _shift = shift;
      _glide.value = 0;
      _glide
          .animateWith(SpringSimulation(AppMotion.bouncySpring, 0, 1, 0))
          .then((_) => _glide.value = 1);
    });
  }

  @override
  void dispose() {
    _glide.dispose();
    _merge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final toolbar = widget.builder(context, this);
    return AnimatedBuilder(
      animation: _glide,
      builder: (context, child) =>
          Transform.translate(offset: _offset, child: child),
      child: _ghosts.isEmpty
          ? toolbar
          : Stack(
              clipBehavior: Clip.none,
              children: [
                toolbar,
                for (final ghost in _ghosts)
                  AnimatedBuilder(
                    animation: _merge,
                    child: IgnorePointer(
                      child: ExcludeSemantics(
                        child: widget.ghostBuilder(ghost.group),
                      ),
                    ),
                    builder: (context, child) {
                      final t = _merge.value;
                      final progress = t.clamp(0.0, 1.0);
                      final target = Offset(
                        (_ghostTarget.width - ghost.size.width) / 2,
                        0,
                      );
                      final at = Offset.lerp(ghost.offset, target, t)!;
                      final blur = MotionMetrics.blockSplitBlur * progress;
                      return Positioned(
                        key: ValueKey('ghost-${ghost.group.key}'),
                        left: at.dx,
                        top: at.dy,
                        child: Opacity(
                          opacity: (1 - t).clamp(0.0, 1.0),
                          child: Transform(
                            alignment: Alignment.topCenter,
                            transform: Matrix4.diagonal3Values(
                              1 +
                                  (_ghostTarget.width / ghost.size.width - 1) *
                                      progress,
                              1,
                              1,
                            ),
                            child: ImageFiltered(
                              enabled: blur > 0.01,
                              imageFilter: ui.ImageFilter.blur(
                                sigmaX: blur,
                                sigmaY: blur,
                              ),
                              child: child,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
    );
  }
}

class ToolbarDragHandle extends StatefulWidget {
  const ToolbarDragHandle({
    super.key,
    required this.tooltip,
    required this.lifted,
    required this.extent,
    required this.duration,
    required this.hint,
    required this.grip,
    required this.onLift,
    required this.onDrag,
    required this.onDoubleTap,
  });

  final String tooltip;
  final bool lifted;
  final Size extent;
  final Duration duration;
  final Widget hint;
  final Widget grip;
  final ValueChanged<bool> onLift;
  final ValueChanged<Offset> onDrag;
  final VoidCallback onDoubleTap;

  @override
  State<ToolbarDragHandle> createState() => _ToolbarDragHandleState();
}

class _ToolbarDragHandleState extends State<ToolbarDragHandle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final active = _hovered || widget.lifted;
    return AppTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: widget.lifted
            ? SystemMouseCursors.grabbing
            : SystemMouseCursors.grab,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          key: const Key('toolbar-drag-handle'),
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (_) => widget.onLift(true),
          onPanUpdate: (details) => widget.onDrag(details.delta),
          onPanEnd: (_) => widget.onLift(false),
          onPanCancel: () => widget.onLift(false),
          onDoubleTap: widget.onDoubleTap,
          child: AnimatedContainer(
            duration: widget.duration,
            decoration: ShapeDecoration(
              color: active
                  ? colors.onSurface.withValues(alpha: 0.06)
                  : Colors.transparent,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: AppMotion.iconSwitcher(
              context,
              active
                  ? SizedBox(
                      key: const Key('toolbar-drag-grip'),
                      width: widget.extent.width,
                      height: widget.extent.height,
                      child: Center(child: widget.grip),
                    )
                  : KeyedSubtree(
                      key: const ValueKey('toolbar-drag-hint'),
                      child: widget.hint,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class ToolbarTrayCaret extends CustomPainter {
  const ToolbarTrayCaret({required this.color, required this.axis});

  final Color color;
  final Axis axis;

  @override
  void paint(Canvas canvas, Size size) {
    final path = axis == Axis.horizontal
        ? (Path()
            ..moveTo(0, size.height)
            ..lineTo(size.width / 2, 0)
            ..lineTo(size.width, size.height)
            ..close())
        : (Path()
            ..moveTo(size.width, 0)
            ..lineTo(0, size.height / 2)
            ..lineTo(size.width, size.height)
            ..close());
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(ToolbarTrayCaret old) =>
      old.color != color || old.axis != axis;
}
