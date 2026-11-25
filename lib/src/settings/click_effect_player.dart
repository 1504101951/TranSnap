import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/constants/glass_metrics.dart';
import '../common/constants/screenshot_enums.dart';
import '../common/widgets/app_motion.dart';
import '../common/widgets/line_icon.dart';
import '../common/widgets/native_glass.dart';

enum ClickDemoAction {
  left('左键单击'),
  right('右键单击'),
  drag('按住拖动');

  const ClickDemoAction(this.label);

  final String label;
}

abstract final class ClickEffectDemo {
  static const stageSize = Size(176, 99);
  static const segmentSeconds = 1.6;
  static const moveSeconds = 0.5;
  static const dragStart = 0.3;
  static const dragSeconds = 0.9;
  static const staticFrame = 0.68;
  static const leftColor = Color(0xFF007AFF);
  static const rightColor = Color(0xFFFF9500);

  static ({ClickDemoAction action, double time}) frameAt(
    double timeline,
    ClickDemoAction? only,
  ) {
    if (only != null) return (action: only, time: timeline);
    final index = math.min(2, (timeline / segmentSeconds).floor());
    return (
      action: ClickDemoAction.values[index],
      time: timeline - index * segmentSeconds,
    );
  }

  static double cycleSeconds(ClickDemoAction? only) =>
      only == null ? segmentSeconds * 3 : segmentSeconds;
}

class ClickEffectPlayer extends StatefulWidget {
  const ClickEffectPlayer({
    super.key,
    required this.effect,
    required this.onChanged,
  });

  final RecordingClickEffect effect;
  final ValueChanged<RecordingClickEffect> onChanged;

  @override
  State<ClickEffectPlayer> createState() => _ClickEffectPlayerState();
}

class _ClickEffectPlayerState extends State<ClickEffectPlayer>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;
  double _timeline = 0;
  ClickDemoAction? _only;
  bool _playing = true;
  bool _once = false;
  bool? _reduced;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = AppMotion.reduced(context);
    if (reduced == _reduced) return;
    _reduced = reduced;
    if (reduced) {
      _stop(ClickEffectDemo.staticFrame);
    } else {
      _start(once: false);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _start({required bool once}) {
    _once = once;
    _playing = true;
    _last = Duration.zero;
    if (_ticker.isActive) _ticker.stop();
    _ticker.start();
  }

  void _stop(double timeline) {
    if (_ticker.isActive) _ticker.stop();
    _playing = false;
    _timeline = timeline;
  }

  void _tick(Duration elapsed) {
    final delta = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final cycle = ClickEffectDemo.cycleSeconds(_only);
    setState(() {
      final next = _timeline + delta;
      if (_once && next >= cycle) {
        _stop(ClickEffectDemo.staticFrame);
      } else {
        _timeline = next % cycle;
      }
    });
  }

  void _playAction(ClickDemoAction action) {
    setState(() {
      _only = action;
      _timeline = 0;
      _start(once: _reduced!);
    });
  }

  void _togglePlaying() {
    setState(() {
      if (_playing) {
        _stop(_timeline);
      } else {
        _start(once: _reduced!);
      }
    });
  }

  void _selectEffect(RecordingClickEffect effect) {
    final frame = ClickEffectDemo.frameAt(_timeline, _only);
    setState(() {
      _timeline = _only == null
          ? frame.action.index * ClickEffectDemo.segmentSeconds
          : 0;
      if (_reduced!) _start(once: true);
    });
    widget.onChanged(effect);
  }

  @override
  Widget build(BuildContext context) {
    final frame = ClickEffectDemo.frameAt(_timeline, _only);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final quietFill = colors.onSurface.withValues(alpha: dark ? 0.08 : 0.05);
    final label = theme.textTheme.bodySmall!.copyWith(
      fontSize: GlassMetrics.captionFont,
    );
    ButtonStyle buttonStyle({
      required Color background,
      required Color foreground,
    }) => TextButton.styleFrom(
      minimumSize: const Size(0, GlassMetrics.buttonHeight),
      fixedSize: const Size.fromHeight(GlassMetrics.buttonHeight),
      padding: const EdgeInsets.symmetric(horizontal: GlassMetrics.space8),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      backgroundColor: background,
      foregroundColor: foreground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GlassMetrics.controlRadius - 1),
      ),
    );
    final accentFill = NativeGlassTheme.accentFillOf(context);
    final onAccent = NativeGlassTheme.onAccentOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(GlassMetrics.primaryRadius),
          child: CustomPaint(
            key: const Key('click-effect-stage'),
            size: ClickEffectDemo.stageSize,
            painter: _ClickEffectPainter(
              effect: widget.effect,
              action: frame.action,
              time: frame.time,
              dark: dark,
              line: colors.onSurface.withValues(alpha: 0.10),
            ),
          ),
        ),
        const SizedBox(height: GlassMetrics.space8),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: const Key('click-demo-play'),
              tooltip: _playing ? '暂停' : '播放',
              onPressed: _togglePlaying,
              constraints: const BoxConstraints.tightFor(
                width: GlassMetrics.buttonHeight,
                height: GlassMetrics.buttonHeight,
              ),
              padding: EdgeInsets.zero,
              icon: LineIcon(
                _playing ? LucideIcons.pause : LucideIcons.play,
                size: 14,
              ),
            ),
            for (final action in ClickDemoAction.values) ...[
              const SizedBox(width: GlassMetrics.space4),
              TextButton(
                key: Key('click-demo-${action.name}'),
                onPressed: () => _playAction(action),
                style: buttonStyle(
                  background: action == frame.action
                      ? quietFill
                      : Colors.transparent,
                  foreground: action == frame.action
                      ? colors.onSurface
                      : colors.onSurfaceVariant,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: switch (action) {
                          ClickDemoAction.left => ClickEffectDemo.leftColor,
                          ClickDemoAction.right => ClickEffectDemo.rightColor,
                          ClickDemoAction.drag =>
                            ClickEffectDemo.leftColor.withValues(alpha: 0.5),
                        },
                      ),
                      child: const SizedBox.square(dimension: 8),
                    ),
                    const SizedBox(width: GlassMetrics.iconGap),
                    Text(
                      action.label,
                      style: label.copyWith(
                        color: action == frame.action
                            ? colors.onSurface
                            : colors.onSurfaceVariant,
                        fontWeight: action == frame.action
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: GlassMetrics.space8),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: GlassMetrics.space4,
          runSpacing: GlassMetrics.space4,
          children: [
            for (final effect in RecordingClickEffect.values)
              TextButton(
                key: Key('click-effect-${effect.name}'),
                onPressed: () => _selectEffect(effect),
                style: buttonStyle(
                  background: effect == widget.effect ? accentFill : quietFill,
                  foreground: effect == widget.effect
                      ? onAccent
                      : colors.onSurface,
                ),
                child: Text(
                  effect.label,
                  style: label.copyWith(
                    color: effect == widget.effect
                        ? onAccent
                        : colors.onSurface,
                    fontWeight: effect == widget.effect
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _ClickEffectPainter extends CustomPainter {
  _ClickEffectPainter({
    required this.effect,
    required this.action,
    required this.time,
    required this.dark,
    required this.line,
  });

  final RecordingClickEffect effect;
  final ClickDemoAction action;
  final double time;
  final bool dark;
  final Color line;

  static double _ease(double t) => 1 - math.pow(1 - t, 3).toDouble();

  static double _spring(double t) => 1 - math.exp(-6 * t) * math.cos(10 * t);

  static Offset _lerp(Offset a, Offset b, double k) => Offset.lerp(a, b, k)!;

  void _ring(
    Canvas canvas,
    Offset center,
    double radius,
    Color color,
    double width,
    double alpha, {
    bool dashed = false,
  }) {
    if (alpha <= 0 || radius <= 0) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = color.withValues(alpha: color.a * alpha.clamp(0, 1));
    if (!dashed) {
      canvas.drawCircle(center, radius, paint);
      return;
    }
    final circumference = 2 * math.pi * radius;
    final dashes = math.max(4, (circumference / 3.5).floor());
    final sweep = 2 * math.pi / dashes;
    final rect = Rect.fromCircle(center: center, radius: radius);
    for (var i = 0; i < dashes; i++) {
      canvas.drawArc(rect, i * sweep, sweep * 4 / 7, false, paint);
    }
  }

  void _disc(
    Canvas canvas,
    Offset center,
    double radius,
    Color color,
    double alpha,
  ) {
    if (alpha <= 0 || radius <= 0) return;
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = color.withValues(alpha: color.a * alpha.clamp(0, 1)),
    );
  }

  void _click(Canvas canvas, Offset at, double t, bool right) {
    final color = right
        ? ClickEffectDemo.rightColor
        : ClickEffectDemo.leftColor;
    final duration = effect == RecordingClickEffect.minimal ? 0.42 : 0.56;
    if (t > duration + 0.15) return;
    final p = math.min(t / duration, 1.0);
    final shade = Colors.black.withValues(alpha: 0.55);
    switch (effect) {
      case RecordingClickEffect.optical:
        final r = 8 + 28 * _ease(p);
        _ring(canvas, at, r, shade, 2.6, 0.34 * (1 - p), dashed: right);
        _ring(
          canvas,
          at,
          r,
          color,
          1.75 - 0.75 * p,
          0.92 * (1 - p),
          dashed: right,
        );
        if (t > 0.11) {
          final q = math.min((t - 0.11) / duration, 1.0);
          _ring(
            canvas,
            at,
            6 + 38 * _ease(q),
            color,
            1.1 - 0.3 * q,
            0.48 * (1 - q),
          );
        }
      case RecordingClickEffect.liquid:
        final core = 11 * (0.6 + 0.4 * _spring(p));
        _disc(canvas, at, core, color.withValues(alpha: 0.22), 1 - p);
        _ring(canvas, at, core, color.withValues(alpha: 0.78), 1.3, 1 - p);
        _ring(
          canvas,
          at,
          10 + 32 * _ease(p),
          color,
          right ? 1.8 : 1.25,
          0.62 * (1 - p),
        );
      case RecordingClickEffect.spotlight:
        final r = 9 + 27 * _ease(p);
        _ring(canvas, at, r, shade, 2.4, 0.40 * (1 - p));
        _disc(canvas, at, r, color.withValues(alpha: 0.26), 1 - p);
        _ring(canvas, at, r, color.withValues(alpha: 0.68), 1.4, 1 - p);
      case RecordingClickEffect.prism:
        final halo = math.min(p / 0.65, 1.0);
        _ring(canvas, at, 8 + 20 * _ease(halo), color, 1.4, 0.65 * (1 - halo));
        final paint = Paint()
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round
          ..color = color.withValues(alpha: 1 - p);
        for (var i = 0; i < 8; i++) {
          final angle = i * math.pi / 4 + math.pi / 8;
          final length = i.isOdd ? 0.7 : 1.0;
          final direction = Offset(math.cos(angle), math.sin(angle));
          canvas.drawLine(
            at + direction * (7 + 10 * _ease(p)),
            at + direction * ((14 + 14 * _ease(p)) * length),
            paint,
          );
        }
      case RecordingClickEffect.minimal:
        final r = 11 + 19 * _ease(p);
        _ring(canvas, at, r, shade, 2.6, 0.62 * (1 - p), dashed: right);
        _ring(
          canvas,
          at,
          r,
          Colors.white.withValues(alpha: 0.92),
          2.2,
          0.95 * (1 - p),
          dashed: right,
        );
      case RecordingClickEffect.system:
        _disc(
          canvas,
          at,
          14,
          const Color(0x73FFD60A),
          t < 0.3 ? 1 : 1 - (t - 0.3) / 0.4,
        );
    }
  }

  void _cursor(Canvas canvas, Offset at) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(0, 17)
      ..lineTo(4.5, 13)
      ..lineTo(7.5, 19.5)
      ..lineTo(10, 18.5)
      ..lineTo(7, 12)
      ..lineTo(12.5, 12)
      ..close();
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.drawPath(path, Paint()..color = Colors.black);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white,
    );
    canvas.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          colors: dark
              ? const [Color(0xFF2A3140), Color(0xFF1E2430)]
              : const [Color(0xFFDDE3EC), Color(0xFFC9D2DF)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * .26, h * .18, w * .48, h * .64),
        const Radius.circular(8),
      ),
      Paint()
        ..color = (dark ? const Color(0xFF232326) : Colors.white).withValues(
          alpha: 0.9,
        ),
    );
    final linePaint = Paint()..color = line;
    for (var i = 0; i < 4; i++) {
      canvas.drawRect(
        Rect.fromLTWH(w * .30, h * (.30 + i * .12), w * (.36 - i * .05), 5),
        linePaint,
      );
    }
    final path = switch (action) {
      ClickDemoAction.left => (
        Offset(w * .18, h * .82),
        Offset(w * .36, h * .45),
      ),
      ClickDemoAction.right => (
        Offset(w * .36, h * .45),
        Offset(w * .58, h * .40),
      ),
      ClickDemoAction.drag => (
        Offset(w * .58, h * .40),
        Offset(w * .82, h * .66),
      ),
    };
    final (from, to) = path;
    late final Offset pointer;
    if (action == ClickDemoAction.drag) {
      final k =
          ((time - ClickEffectDemo.dragStart) / ClickEffectDemo.dragSeconds)
              .clamp(0.0, 1.0);
      pointer = _lerp(from, to, _ease(k));
      if (effect != RecordingClickEffect.system) {
        for (var i = 0; i <= 24; i++) {
          final at =
              ClickEffectDemo.dragStart + i * ClickEffectDemo.dragSeconds / 24;
          if (at > time) break;
          final age = time - at;
          if (age > 0.36) continue;
          _disc(
            canvas,
            _lerp(
              from,
              to,
              _ease(
                (at - ClickEffectDemo.dragStart) / ClickEffectDemo.dragSeconds,
              ),
            ),
            4 * (1 - 0.5 * age / 0.36),
            ClickEffectDemo.leftColor.withValues(alpha: 0.36),
            1 - age / 0.36,
          );
        }
        if (time > ClickEffectDemo.dragStart &&
            time < ClickEffectDemo.dragStart + ClickEffectDemo.dragSeconds) {
          _ring(canvas, pointer, 13, ClickEffectDemo.leftColor, 1.6, 0.8);
        }
      }
    } else {
      pointer = _lerp(
        from,
        to,
        _ease(math.min(time / ClickEffectDemo.moveSeconds, 1.0)),
      );
      if (time >= ClickEffectDemo.moveSeconds) {
        _click(
          canvas,
          to,
          time - ClickEffectDemo.moveSeconds,
          action == ClickDemoAction.right,
        );
      }
    }
    _cursor(canvas, pointer);
  }

  @override
  bool shouldRepaint(_ClickEffectPainter old) =>
      old.effect != effect ||
      old.action != action ||
      old.time != time ||
      old.dark != dark ||
      old.line != line;
}
