import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:motor/motor.dart';

import 'line_icon.dart';
import '../constants/glass_metrics.dart';
import '../constants/motion_metrics.dart';
import '../constants/translation_phase.dart';

abstract final class AppMotion {
  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  static Motion bouncy(BuildContext context) => reduced(context)
      ? const Motion.linear(Duration.zero)
      : const CupertinoMotion.bouncy(
          duration: MotionMetrics.bouncyDuration,
          extraBounce: MotionMetrics.bouncyExtraBounce,
          snapToEnd: true,
        );

  static Motion presence(BuildContext context) => reduced(context)
      ? const Motion.linear(Duration.zero)
      : const CupertinoMotion.snappy(
          duration: MotionMetrics.presenceDuration,
          extraBounce: MotionMetrics.presenceExtraBounce,
          snapToEnd: true,
        );

  static Widget iconSwitcher(BuildContext context, Widget child) =>
      AnimatedSwitcher(
        duration: reduced(context)
            ? Duration.zero
            : MotionMetrics.iconSwitchDuration,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween(
              begin: MotionMetrics.iconSwitchFromScale,
              end: 1.0,
            ).animate(animation),
            child: AnimatedBuilder(
              animation: animation,
              child: child,
              builder: (context, child) {
                final sigma =
                    (1 - animation.value) * MotionMetrics.iconSwitchBlur;
                return sigma < 0.01
                    ? child!
                    : ImageFiltered(
                        imageFilter: ui.ImageFilter.blur(
                          sigmaX: sigma,
                          sigmaY: sigma,
                        ),
                        child: child,
                      );
              },
            ),
          ),
        ),
        child: child,
      );
}

class BouncyPresence extends StatefulWidget {
  const BouncyPresence({
    super.key,
    required this.child,
    this.fromScale = 0.92,
    this.quick = false,
  });

  final Widget child;
  final double fromScale;
  final bool quick;

  @override
  State<BouncyPresence> createState() => _BouncyPresenceState();
}

class _BouncyPresenceState extends State<BouncyPresence> {
  bool _settled = false;

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return widget.child;
    return SingleMotionBuilder(
      from: widget.fromScale,
      value: 1.0,
      motion: widget.quick
          ? AppMotion.presence(context)
          : AppMotion.bouncy(context),
      onAnimationStatusChanged: (status) {
        if (status == AnimationStatus.completed && !_settled && mounted) {
          setState(() => _settled = true);
        } else if (status == AnimationStatus.forward && _settled && mounted) {
          setState(() => _settled = false);
        }
      },
      child: widget.child,
      builder: (context, value, target) {
        final effectiveScale = _settled ? 1.0 : value;
        final span = (1.0 - widget.fromScale).abs();
        final opacity = _settled || span < 0.001
            ? 1.0
            : ((value - widget.fromScale) / (1.0 - widget.fromScale)).clamp(
                0.0,
                1.0,
              );
        return Opacity(
          opacity: opacity,
          child: Transform.scale(scale: effectiveScale, child: target),
        );
      },
    );
  }
}

class _ControlledAnimate extends StatefulWidget {
  const _ControlledAnimate({
    required this.child,
    required this.effects,
    this.delay = Duration.zero,
    this.repeatCount = 1,
  });

  final Widget child;
  final List<Effect<dynamic>> effects;
  final Duration delay;
  final int repeatCount;

  @override
  State<_ControlledAnimate> createState() => _ControlledAnimateState();
}

class _ControlledAnimateState extends State<_ControlledAnimate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _computeTotalDuration(widget.effects),
    );
    if (widget.delay <= Duration.zero) {
      _start();
    } else {
      _delayTimer = Timer(widget.delay, _start);
    }
  }

  static Duration _computeTotalDuration(List<Effect<dynamic>> effects) {
    var maxEnd = const Duration(milliseconds: 1);
    for (final effect in effects) {
      final end =
          (effect.delay ?? Duration.zero) +
          (effect.duration ?? Animate.defaultDuration);
      if (end > maxEnd) maxEnd = end;
    }
    return maxEnd;
  }

  void _start() {
    if (!mounted) return;
    if (widget.repeatCount > 1) {
      _controller.repeat(count: widget.repeatCount);
      return;
    }
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _controller.duration ?? const Duration(milliseconds: 1);
    final owner = Animate(child: widget.child);
    var current = widget.child;
    for (final effect in widget.effects) {
      final entry = EffectEntry(
        effect: effect,
        delay: effect.delay ?? Duration.zero,
        duration: effect.duration ?? total,
        curve: effect.curve ?? Curves.linear,
        owner: owner,
      );
      current = effect.build(context, current, _controller, entry);
    }
    return current;
  }
}

class GentleReveal extends StatelessWidget {
  const GentleReveal({
    super.key,
    required this.child,
    this.staggerIndex = 0,
    this.blur = true,
    this.shakeOnError = false,
  });

  final Widget child;
  final int staggerIndex;
  final bool blur;
  final bool shakeOnError;

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return child;
    final delay = MotionMetrics.staggerStep * staggerIndex;
    if (shakeOnError) {
      return _ControlledAnimate(
        delay: delay,
        effects: const [
          FadeEffect(
            duration: MotionMetrics.gentleDuration,
            curve: Curves.easeOutCubic,
            begin: 0,
            end: 1,
          ),
          ShakeEffect(
            duration: MotionMetrics.shakeDuration,
            offset: Offset(MotionMetrics.shakeOffset, 0),
            rotation: 0,
          ),
        ],
        child: child,
      );
    }
    final effects = <Effect<dynamic>>[
      const FadeEffect(
        duration: MotionMetrics.gentleDuration,
        curve: Curves.easeOutCubic,
        begin: 0,
        end: 1,
      ),
      const SlideEffect(
        duration: MotionMetrics.gentleDuration,
        curve: Curves.easeOutCubic,
        begin: Offset(0, MotionMetrics.gentleSlideOffset),
        end: Offset.zero,
      ),
      if (blur)
        const BlurEffect(
          duration: MotionMetrics.gentleDuration,
          curve: Curves.easeOutCubic,
          begin: Offset(MotionMetrics.blurSigma, MotionMetrics.blurSigma),
          end: Offset.zero,
        ),
    ];
    return _ControlledAnimate(delay: delay, effects: effects, child: child);
  }
}

class GentleShimmerSkeleton extends StatelessWidget {
  const GentleShimmerSkeleton({super.key, this.lines = 2});

  final int lines;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final base = colors.onSurface.withValues(alpha: 0.10);
    final highlight = colors.primary.withValues(alpha: 0.24);
    final bars = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 10,
      children: [
        for (var i = 0; i < lines; i++)
          FractionallySizedBox(
            widthFactor: i.isEven ? 0.88 : 0.62,
            child: Container(
              height: 14,
              decoration: BoxDecoration(
                color: base,
                borderRadius: BorderRadius.circular(
                  GlassMetrics.menuItemRadius,
                ),
              ),
            ),
          ),
      ],
    );
    if (AppMotion.reduced(context)) return bars;
    return _ControlledAnimate(
      repeatCount: 60,
      effects: [
        ShimmerEffect(
          duration: MotionMetrics.shimmerDuration,
          color: highlight,
        ),
      ],
      child: bars,
    );
  }
}

class OpticalPrismOverlay extends StatefulWidget {
  const OpticalPrismOverlay({
    super.key,
    required this.child,
    this.radius = GlassMetrics.panelRadius,
    this.sweepTrigger = 0,
  });

  final Widget child;
  final double radius;
  final int sweepTrigger;

  @override
  State<OpticalPrismOverlay> createState() => _OpticalPrismOverlayState();
}

class _OpticalPrismOverlayState extends State<OpticalPrismOverlay>
    with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram?>? _programLoader;
  ui.FragmentProgram? _program;
  late final AnimationController _sweepController;
  double _targetAngle = -math.pi * 0.28;

  @override
  void initState() {
    super.initState();
    _sweepController = AnimationController(
      vsync: this,
      duration: MotionMetrics.prismSweepDuration,
    );
    unawaited(_ensureProgram());
  }

  @override
  void didUpdateWidget(OpticalPrismOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sweepTrigger > oldWidget.sweepTrigger &&
        !AppMotion.reduced(context)) {
      _sweepController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _sweepController.dispose();
    super.dispose();
  }

  Future<void> _ensureProgram() async {
    _programLoader ??= ui.FragmentProgram.fromAsset(
      MotionMetrics.prismShaderAsset,
    ).then<ui.FragmentProgram?>((value) => value).catchError((_) => null);
    final loaded = await _programLoader;
    if (mounted && loaded != null) {
      setState(() => _program = loaded);
    }
  }

  void _updateHoverAngle(PointerEvent event, Size size) {
    if (AppMotion.reduced(context) || size.isEmpty) return;
    final dx = event.localPosition.dx - size.width * 0.5;
    final dy = event.localPosition.dy - size.height * 0.5;
    if (dx.abs() < 1 && dy.abs() < 1) return;
    final nextAngle = math.atan2(dy, dx);
    if ((nextAngle - _targetAngle).abs() > 0.02) {
      setState(() => _targetAngle = nextAngle);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) => MouseRegion(
        hitTestBehavior: HitTestBehavior.opaque,
        onHover: reduced
            ? null
            : (event) => _updateHoverAngle(event, constraints.biggest),
        onExit: reduced
            ? null
            : (_) {
                if (_targetAngle != -math.pi * 0.28) {
                  setState(() => _targetAngle = -math.pi * 0.28);
                }
              },
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            widget.child,
            Positioned.fill(
              child: IgnorePointer(
                child: reduced
                    ? CustomPaint(
                        painter: _OpticalPrismFallbackPainter(
                          radius: widget.radius,
                          isDark: isDark,
                        ),
                      )
                    : SingleMotionBuilder(
                        value: _targetAngle,
                        motion: AppMotion.bouncy(context),
                        builder: (context, angle, _) => AnimatedBuilder(
                          animation: _sweepController,
                          builder: (context, _) {
                            final program = _program;
                            if (program == null) {
                              return CustomPaint(
                                painter: _OpticalPrismFallbackPainter(
                                  radius: widget.radius,
                                  isDark: isDark,
                                ),
                              );
                            }
                            return CustomPaint(
                              painter: _OpticalPrismShaderPainter(
                                program: program,
                                angle: angle,
                                sweep: _sweepController.value,
                                radius: widget.radius,
                                isDark: isDark,
                              ),
                            );
                          },
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OpticalPrismShaderPainter extends CustomPainter {
  const _OpticalPrismShaderPainter({
    required this.program,
    required this.angle,
    required this.sweep,
    required this.radius,
    required this.isDark,
  });

  final ui.FragmentProgram program;
  final double angle;
  final double sweep;
  final double radius;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final shader = program.fragmentShader();
    final cool = MotionMetrics.prismCoolTint;
    final warm = MotionMetrics.prismWarmTint;
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, angle)
      ..setFloat(3, sweep)
      ..setFloat(4, radius)
      ..setFloat(5, MotionMetrics.prismStrokeWidth)
      ..setFloat(6, isDark ? 1.0 : 0.0)
      ..setFloat(7, cool.r)
      ..setFloat(8, cool.g)
      ..setFloat(9, cool.b)
      ..setFloat(10, warm.r)
      ..setFloat(11, warm.g)
      ..setFloat(12, warm.b)
      ..setFloat(
        13,
        isDark
            ? MotionMetrics.prismDarkPeakOpacity
            : MotionMetrics.prismLightPeakOpacity,
      )
      ..setFloat(14, MotionMetrics.prismDispersionOpacity);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_OpticalPrismShaderPainter old) =>
      old.angle != angle ||
      old.sweep != sweep ||
      old.radius != radius ||
      old.isDark != isDark ||
      old.program != program;
}

class _OpticalPrismFallbackPainter extends CustomPainter {
  const _OpticalPrismFallbackPainter({
    required this.radius,
    required this.isDark,
  });

  final double radius;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final inset = MotionMetrics.prismStrokeWidth * 0.5;
    final rect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(inset),
      Radius.circular(radius),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = MotionMetrics.prismStrokeWidth
      ..color = Colors.white.withValues(alpha: isDark ? 0.16 : 0.36);
    canvas.drawRRect(rect, paint);
  }

  @override
  bool shouldRepaint(_OpticalPrismFallbackPainter old) =>
      old.radius != radius || old.isDark != isDark;
}

class TranslationStatusIcon extends StatefulWidget {
  const TranslationStatusIcon({super.key, required this.phase, this.size = 14});

  final TranslationPhase phase;
  final double size;

  @override
  State<TranslationStatusIcon> createState() => _TranslationStatusIconState();
}

class _TranslationStatusIconState extends State<TranslationStatusIcon>
    with TickerProviderStateMixin {
  late final AnimationController _spinController;
  late final AnimationController _stateController;

  @override
  void initState() {
    super.initState();
    _spinController = AnimationController(
      vsync: this,
      duration: MotionMetrics.statusSpinDuration,
    );
    _stateController = AnimationController(
      vsync: this,
      duration: MotionMetrics.statusDrawDuration,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncControllers(initial: true);
  }

  @override
  void didUpdateWidget(TranslationStatusIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase) {
      _syncControllers(initial: false);
    }
  }

  void _syncControllers({required bool initial}) {
    final reduced = AppMotion.reduced(context);
    if (widget.phase == TranslationPhase.translating && !reduced) {
      if (!_spinController.isAnimating) _spinController.repeat();
    } else {
      _spinController.stop();
    }
    if (reduced || widget.phase == TranslationPhase.translating) {
      _stateController.value = 1;
    } else if (!initial ||
        widget.phase == TranslationPhase.completed ||
        widget.phase == TranslationPhase.failed ||
        widget.phase == TranslationPhase.sizeLimited) {
      _stateController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _spinController.dispose();
    _stateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final reduced = AppMotion.reduced(context);
    final isError =
        widget.phase == TranslationPhase.failed ||
        widget.phase == TranslationPhase.sizeLimited;
    final popTarget = widget.phase == TranslationPhase.completed || isError
        ? 1.0
        : 0.96;

    Widget icon = SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: Listenable.merge([_spinController, _stateController]),
        builder: (context, _) => CustomPaint(
          painter: _TranslationStatusPainter(
            phase: widget.phase,
            spin: reduced ? 0.2 : _spinController.value,
            progress: reduced ? 1.0 : _stateController.value,
            primary: colors.primary,
            success: const Color(0xFF34C759),
            error: colors.error,
            muted: colors.onSurfaceVariant,
          ),
        ),
      ),
    );
    if (reduced || widget.phase == TranslationPhase.translating) return icon;
    return SingleMotionBuilder(
      key: ValueKey(widget.phase),
      from: 0.72,
      value: popTarget,
      motion: AppMotion.bouncy(context),
      child: icon,
      builder: (context, scale, child) {
        final t = _stateController.value;
        final shakeX = isError && t < 1.0
            ? math.sin(t * math.pi * 5) * (1 - t) * 2.5
            : 0.0;
        return Transform.translate(
          offset: Offset(shakeX, 0),
          child: Transform.scale(scale: scale, child: child),
        );
      },
    );
  }
}

class _TranslationStatusPainter extends CustomPainter {
  const _TranslationStatusPainter({
    required this.phase,
    required this.spin,
    required this.progress,
    required this.primary,
    required this.success,
    required this.error,
    required this.muted,
  });

  final TranslationPhase phase;
  final double spin;
  final double progress;
  final Color primary;
  final Color success;
  final Color error;
  final Color muted;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.5, size.height * 0.5);
    final radius = size.shortestSide * 0.44;
    if (phase == TranslationPhase.translating) {
      final start = spin * math.pi * 2;
      final outerPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..color = primary;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        math.pi * 1.15,
        false,
        outerPaint,
      );
      final innerPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..strokeCap = StrokeCap.round
        ..color = primary.withValues(alpha: 0.42);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius * 0.58),
        -start * 1.4,
        math.pi * 0.9,
        false,
        innerPaint,
      );
      return;
    }
    if (phase == TranslationPhase.completed) {
      canvas.drawCircle(
        center,
        radius,
        Paint()..color = success.withValues(alpha: 0.16),
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.25
          ..color = success,
      );
      final check = Path()
        ..moveTo(center.dx - radius * 0.48, center.dy + radius * 0.04)
        ..lineTo(center.dx - radius * 0.12, center.dy + radius * 0.42)
        ..lineTo(center.dx + radius * 0.52, center.dy - radius * 0.34);
      final drawPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.7
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = success;
      for (final metric in check.computeMetrics()) {
        canvas.drawPath(
          metric.extractPath(0, metric.length * progress),
          drawPaint,
        );
      }
      return;
    }
    if (phase == TranslationPhase.failed ||
        phase == TranslationPhase.sizeLimited) {
      canvas.drawCircle(
        center,
        radius,
        Paint()..color = error.withValues(alpha: 0.15),
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.25
          ..color = error,
      );
      final d = radius * 0.38 * progress;
      final crossPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..color = error;
      canvas.drawLine(
        center + Offset(-d, -d),
        center + Offset(d, d),
        crossPaint,
      );
      canvas.drawLine(
        center + Offset(d, -d),
        center + Offset(-d, d),
        crossPaint,
      );
      return;
    }
    canvas.drawCircle(
      center,
      radius * 0.55,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = muted.withValues(alpha: 0.65),
    );
  }

  @override
  bool shouldRepaint(_TranslationStatusPainter old) =>
      old.phase != phase ||
      old.spin != spin ||
      old.progress != progress ||
      old.primary != primary ||
      old.success != success ||
      old.error != error ||
      old.muted != muted;
}

class SpeechWaveIcon extends StatefulWidget {
  const SpeechWaveIcon({super.key, required this.speaking, this.size = 14});

  final bool speaking;
  final double size;

  @override
  State<SpeechWaveIcon> createState() => _SpeechWaveIconState();
}

class _SpeechWaveIconState extends State<SpeechWaveIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _waveController;

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: MotionMetrics.speechWavePeriod,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncWave();
  }

  @override
  void didUpdateWidget(SpeechWaveIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.speaking != widget.speaking) _syncWave();
  }

  void _syncWave() {
    final reduced = AppMotion.reduced(context);
    if (widget.speaking && !reduced) {
      if (!_waveController.isAnimating) _waveController.repeat();
    } else {
      _waveController.stop();
    }
  }

  @override
  void dispose() {
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.speaking) {
      return AppMotion.iconSwitcher(
        context,
        LineIcon(
          LucideIcons.volume2,
          key: const ValueKey('speech-idle'),
          size: widget.size,
        ),
      );
    }
    final primary = Theme.of(context).colorScheme.primary;
    final reduced = AppMotion.reduced(context);
    return AppMotion.iconSwitcher(
      context,
      SizedBox.square(
        key: const ValueKey('speech-wave'),
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _waveController,
          builder: (context, _) => CustomPaint(
            painter: _SpeechWavePainter(
              phase: reduced ? 0.25 : _waveController.value,
              color: primary,
            ),
          ),
        ),
      ),
    );
  }
}

class _SpeechWavePainter extends CustomPainter {
  const _SpeechWavePainter({required this.phase, required this.color});

  final double phase;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final barWidth = math.max(1.5, size.width * 0.12);
    final step = size.width / 5.5;
    final startX = (size.width - step * 4) * 0.5;
    for (var i = 0; i < 5; i++) {
      final amp =
          0.35 + 0.65 * (0.5 + 0.5 * math.sin(phase * math.pi * 2 + i * 0.95));
      final barHeight = size.height * (0.28 + 0.58 * amp);
      final x = startX + i * step;
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(x, size.height * 0.5),
          width: barWidth,
          height: barHeight,
        ),
        Radius.circular(barWidth * 0.5),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_SpeechWavePainter old) =>
      old.phase != phase || old.color != color;
}

class VocabularyBookmarkIcon extends StatefulWidget {
  const VocabularyBookmarkIcon({
    super.key,
    required this.saved,
    this.size = 14,
  });

  final bool saved;
  final double size;

  @override
  State<VocabularyBookmarkIcon> createState() => _VocabularyBookmarkIconState();
}

class _VocabularyBookmarkIconState extends State<VocabularyBookmarkIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _burstController;

  @override
  void initState() {
    super.initState();
    _burstController = AnimationController(
      vsync: this,
      duration: MotionMetrics.vocabBurstDuration,
      value: 1.0,
    );
  }

  @override
  void didUpdateWidget(VocabularyBookmarkIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.saved && widget.saved && !AppMotion.reduced(context)) {
      _burstController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _burstController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final icon = LineIcon(
      widget.saved ? LucideIcons.bookmarkCheck : LucideIcons.bookmarkPlus,
      size: widget.size,
      color: widget.saved ? Theme.of(context).colorScheme.primary : null,
    );
    if (reduced) return icon;
    return SizedBox.square(
      dimension: widget.size,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _burstController,
              builder: (context, _) {
                if (!widget.saved || _burstController.value >= 1.0) {
                  return const SizedBox.shrink();
                }
                return CustomPaint(
                  painter: _SparkBurstPainter(
                    progress: _burstController.value,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                );
              },
            ),
          ),
          AppMotion.iconSwitcher(
            context,
            KeyedSubtree(key: ValueKey(widget.saved), child: icon),
          ),
        ],
      ),
    );
  }
}

class _SparkBurstPainter extends CustomPainter {
  const _SparkBurstPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.5, size.height * 0.5);
    final opacity = (1.0 - progress).clamp(0.0, 1.0);
    final paint = Paint()..color = color.withValues(alpha: opacity * 0.85);
    final baseR = size.shortestSide * 0.42;
    for (var i = 0; i < 8; i++) {
      final angle = (i * math.pi) / 4;
      final dist =
          baseR +
          progress * (size.shortestSide * MotionMetrics.vocabBurstSpread);
      final pos =
          center + Offset(math.cos(angle) * dist, math.sin(angle) * dist);
      canvas.drawCircle(pos, 1.2 * (1.0 - progress * 0.4), paint);
    }
  }

  @override
  bool shouldRepaint(_SparkBurstPainter old) =>
      old.progress != progress || old.color != color;
}

class CopyConfirmIcon extends StatefulWidget {
  const CopyConfirmIcon({
    super.key,
    this.copied = false,
    this.trigger = 0,
    this.size = 14,
  });

  final bool copied;
  final int trigger;
  final double size;

  @override
  State<CopyConfirmIcon> createState() => _CopyConfirmIconState();
}

class _CopyConfirmIconState extends State<CopyConfirmIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _confirmController;
  bool _transientActive = false;
  Timer? _reducedTimer;

  @override
  void initState() {
    super.initState();
    _confirmController =
        AnimationController(
          vsync: this,
          duration: MotionMetrics.copyConfirmDuration,
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed &&
              _transientActive &&
              mounted) {
            setState(() => _transientActive = false);
          }
        });
  }

  @override
  void didUpdateWidget(CopyConfirmIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.trigger > oldWidget.trigger) {
      _reducedTimer?.cancel();
      if (AppMotion.reduced(context)) {
        _confirmController.value = 1.0;
        setState(() => _transientActive = true);
        _reducedTimer = Timer(MotionMetrics.copyConfirmDuration, () {
          if (!mounted) return;
          setState(() => _transientActive = false);
        });
      } else {
        setState(() => _transientActive = true);
        _confirmController.forward(from: 0);
      }
      return;
    }
    if (!oldWidget.copied && widget.copied) {
      _reducedTimer?.cancel();
      _transientActive = false;
      if (AppMotion.reduced(context)) {
        _confirmController.value = 1.0;
      } else {
        _confirmController.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _reducedTimer?.cancel();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.copied || _transientActive;
    if (!active) {
      return AppMotion.iconSwitcher(
        context,
        LineIcon(
          LucideIcons.copy,
          key: const ValueKey('copy-idle'),
          size: widget.size,
        ),
      );
    }
    final reduced = AppMotion.reduced(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final success = dark ? const Color(0xFF32D74B) : const Color(0xFF126326);
    final check = Semantics(
      liveRegion: true,
      label: '已复制',
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _confirmController,
          builder: (context, _) {
            final phase = reduced
                ? 1.0
                : (_confirmController.value / MotionMetrics.copyDrawFraction)
                      .clamp(0.0, 1.0);
            final scale = phase < 0.55
                ? ui.lerpDouble(
                    MotionMetrics.iconSwitchFromScale,
                    MotionMetrics.copyPeakScale,
                    Curves.easeOut.transform(phase / 0.55),
                  )!
                : ui.lerpDouble(
                    MotionMetrics.copyPeakScale,
                    1.0,
                    Curves.easeInOut.transform((phase - 0.55) / 0.45),
                  )!;
            return Transform.scale(
              scale: scale,
              child: CustomPaint(
                painter: _CopyConfirmPainter(progress: phase, color: success),
              ),
            );
          },
        ),
      ),
    );
    return AppMotion.iconSwitcher(
      context,
      KeyedSubtree(key: const ValueKey('copy-done'), child: check),
    );
  }
}

class _CopyConfirmPainter extends CustomPainter {
  const _CopyConfirmPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.5, size.height * 0.5);
    final ringR = size.shortestSide * (0.42 + progress * 0.24);
    final ringAlpha = (1.0 - progress).clamp(0.0, 1.0) * 0.55;
    if (ringAlpha > 0.01) {
      canvas.drawCircle(
        center,
        ringR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = color.withValues(alpha: ringAlpha),
      );
    }
    final check = Path()
      ..moveTo(size.width * 0.20, size.height * 0.53)
      ..lineTo(size.width * 0.42, size.height * 0.74)
      ..lineTo(size.width * 0.80, size.height * 0.28);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;
    for (final metric in check.computeMetrics()) {
      canvas.drawPath(metric.extractPath(0, metric.length * progress), paint);
    }
  }

  @override
  bool shouldRepaint(_CopyConfirmPainter old) =>
      old.progress != progress || old.color != color;
}

class RecordingPulseIcon extends StatefulWidget {
  const RecordingPulseIcon({
    super.key,
    this.countdown,
    this.active = false,
    this.paused = false,
    this.pulseKey,
    this.size = 14,
  });

  final int? countdown;
  final bool active;
  final bool paused;
  final Object? pulseKey;
  final double size;

  @override
  State<RecordingPulseIcon> createState() => _RecordingPulseIconState();
}

class _RecordingPulseIconState extends State<RecordingPulseIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: MotionMetrics.recordingPulseDuration,
      value: 1.0,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.active && !widget.paused && !AppMotion.reduced(context)) {
      _pulseController.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(RecordingPulseIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (AppMotion.reduced(context)) {
      _pulseController.value = 1.0;
      return;
    }
    if (widget.active &&
        !widget.paused &&
        (oldWidget.pulseKey != widget.pulseKey ||
            !oldWidget.active ||
            oldWidget.paused)) {
      _pulseController.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final reduced = AppMotion.reduced(context);
    if (widget.countdown case final int seconds) {
      final badge = SizedBox.square(
        dimension: widget.size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: colors.primary.withValues(alpha: 0.14),
            border: Border.all(
              color: colors.primary.withValues(alpha: 0.55),
              width: 1.2,
            ),
          ),
          child: Center(
            child: Text(
              '$seconds',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                height: 1,
                color: colors.primary,
              ),
            ),
          ),
        ),
      );
      if (reduced) return badge;
      return SingleMotionBuilder(
        key: ValueKey('countdown-$seconds'),
        from: 0.58,
        value: 1.0,
        motion: AppMotion.bouncy(context),
        child: badge,
        builder: (context, scale, child) =>
            Transform.scale(scale: scale, child: child),
      );
    }

    final dotColor = widget.paused
        ? colors.onSurfaceVariant
        : widget.active
        ? const Color(0xFFFF3B30)
        : colors.primary;
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, _) => CustomPaint(
          painter: _RecordingDotPainter(
            progress: reduced ? 1.0 : _pulseController.value,
            pulsing: widget.active && !widget.paused && !reduced,
            color: dotColor,
          ),
        ),
      ),
    );
  }
}

class _RecordingDotPainter extends CustomPainter {
  const _RecordingDotPainter({
    required this.progress,
    required this.pulsing,
    required this.color,
  });

  final double progress;
  final bool pulsing;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width * 0.5, size.height * 0.5);
    if (pulsing && progress < 1.0) {
      final waveR = size.shortestSide * (0.28 + progress * 0.28);
      final opacity = (1.0 - progress).clamp(0.0, 1.0) * 0.6;
      canvas.drawCircle(
        center,
        waveR,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = color.withValues(alpha: opacity),
      );
    }
    canvas.drawCircle(center, size.shortestSide * 0.26, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_RecordingDotPainter old) =>
      old.progress != progress || old.pulsing != pulsing || old.color != color;
}

class BusyRing extends StatefulWidget {
  const BusyRing({
    super.key,
    required this.child,
    required this.active,
    required this.color,
    this.radius = MotionMetrics.busyRingRadius,
  });

  final Widget child;
  final bool active;
  final Color color;
  final double radius;

  @override
  State<BusyRing> createState() => _BusyRingState();
}

class _BusyRingState extends State<BusyRing> with TickerProviderStateMixin {
  late final _flow = AnimationController(
    vsync: this,
    duration: MotionMetrics.busyRingPeriod,
  );
  late final _finish = AnimationController(
    vsync: this,
    duration: MotionMetrics.busyRingFinish,
  );

  @override
  void initState() {
    super.initState();
    _finish.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = AppMotion.reduced(context);
    if (widget.active && !reduced) {
      if (!_flow.isAnimating) _flow.repeat();
    } else {
      _flow.stop();
      if (reduced) _finish.stop();
    }
  }

  @override
  void didUpdateWidget(covariant BusyRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    final reduced = AppMotion.reduced(context);
    if (widget.active && !oldWidget.active) {
      _finish.reset();
      if (!reduced) _flow.repeat();
    } else if (!widget.active && oldWidget.active) {
      _flow.stop();
      if (!reduced) _finish.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _flow.dispose();
    _finish.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final visible = widget.active || (!reduced && _finish.isAnimating);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        if (visible)
          Positioned(
            left: -MotionMetrics.busyRingOutset,
            top: -MotionMetrics.busyRingOutset,
            right: -MotionMetrics.busyRingOutset,
            bottom: -MotionMetrics.busyRingOutset,
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: Listenable.merge([_flow, _finish]),
                builder: (context, _) => CustomPaint(
                  painter: _BusyRingPainter(
                    color: widget.color,
                    radius: widget.radius,
                    phase: _flow.value,
                    arc: widget.active && !reduced
                        ? MotionMetrics.busyRingArc
                        : 1,
                    finish: widget.active ? 0 : _finish.value,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _BusyRingPainter extends CustomPainter {
  _BusyRingPainter({
    required this.color,
    required this.radius,
    required this.phase,
    required this.arc,
    required this.finish,
  });

  final Color color;
  final double radius;
  final double phase;
  final double arc;
  final double finish;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = 1 + (MotionMetrics.busyRingFinishScale - 1) * finish;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    canvas.translate(-size.width / 2, -size.height / 2);
    const inset = MotionMetrics.busyRingStroke / 2;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(inset),
          Radius.circular(radius),
        ),
      );
    final paint = Paint()
      ..color = color.withValues(alpha: color.a * (1 - finish))
      ..style = PaintingStyle.stroke
      ..strokeWidth = MotionMetrics.busyRingStroke
      ..strokeCap = StrokeCap.round;
    if (arc >= 1) {
      canvas.drawPath(path, paint);
    } else {
      for (final metric in path.computeMetrics()) {
        final start = metric.length * phase;
        final end = start + metric.length * arc;
        canvas.drawPath(
          metric.extractPath(start, math.min(end, metric.length)),
          paint,
        );
        if (end > metric.length) {
          canvas.drawPath(metric.extractPath(0, end - metric.length), paint);
        }
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BusyRingPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.phase != phase ||
      oldDelegate.arc != arc ||
      oldDelegate.finish != finish;
}

class CharReveal extends StatefulWidget {
  const CharReveal({
    super.key,
    required this.text,
    required this.style,
    required this.builder,
  });

  final String text;
  final TextStyle style;
  final Widget Function(BuildContext context, TextSpan span) builder;

  @override
  State<CharReveal> createState() => _CharRevealState();
}

class _CharRevealState extends State<CharReveal>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this)
    ..addListener(() => setState(() {}));

  int _base = 0;

  double _stagger = 0;

  @override
  void initState() {
    super.initState();
    _start(0);
  }

  @override
  void didUpdateWidget(covariant CharReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text == oldWidget.text) return;
    final appended = widget.text.startsWith(oldWidget.text);
    _start(appended ? oldWidget.text.characters.length : 0);
  }

  void _start(int base) {
    final chars = widget.text.characters;
    final total = chars.length;
    _base = base.clamp(0, total);
    final count = total - _base;
    if (count <= 0) return;
    final spread = MotionMetrics.charRevealMaxSpread.inMilliseconds;
    _stagger = math.min(
      MotionMetrics.charRevealStagger.inMilliseconds.toDouble(),
      spread / count,
    );
    _controller.duration = Duration(
      milliseconds:
          (MotionMetrics.charRevealDuration.inMilliseconds +
                  _stagger * (count - 1))
              .ceil(),
    );
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    final chars = text.characters.toList();
    final animating = _controller.isAnimating && _base < chars.length;
    if (AppMotion.reduced(context) || !animating) {
      return widget.builder(context, TextSpan(text: text, style: widget.style));
    }
    final color = widget.style.color!;
    final elapsed =
        _controller.value * _controller.duration!.inMilliseconds.toDouble();
    final duration = MotionMetrics.charRevealDuration.inMilliseconds;
    final prefix = chars.take(_base).join();
    return widget.builder(
      context,
      TextSpan(
        style: widget.style,
        children: [
          TextSpan(text: prefix),
          for (final (index, char) in chars.skip(_base).indexed)
            (() {
              final t = ((elapsed - index * _stagger) / duration).clamp(
                0.0,
                1.0,
              );
              final sigma = MotionMetrics.charRevealBlur * (1 - t);
              return TextSpan(
                text: char,
                style: TextStyle(
                  foreground: Paint()
                    ..color = color.withValues(alpha: color.a * t)
                    ..maskFilter = sigma > 0.01
                        ? MaskFilter.blur(BlurStyle.normal, sigma)
                        : null,
                ),
              );
            })(),
        ],
      ),
    );
  }
}

class LiquidSplit extends StatefulWidget {
  const LiquidSplit({
    super.key,
    required this.flexKey,
    required this.axis,
    this.lead,
    this.spacing = 4,
    this.scrollable = false,
    required this.items,
    required this.anchor,
    required this.color,
    this.collapsing = false,
    this.onCollapsed,
  });

  final Key flexKey;
  final Axis axis;
  final Widget? lead;
  final double spacing;
  final bool scrollable;
  final List<Widget> items;
  final GlobalKey anchor;
  final Color color;
  final bool collapsing;
  final VoidCallback? onCollapsed;

  @override
  State<LiquidSplit> createState() => _LiquidSplitState();
}

class _LiquidSplitState extends State<LiquidSplit>
    with SingleTickerProviderStateMixin {
  late final _ticker = createTicker(_tick);
  final _stackKey = GlobalKey();
  late List<GlobalKey> _itemKeys = _keys(widget.items.length);

  List<Offset>? _deltas;

  Rect? _anchorRect;

  List<double> _from = const [];

  List<double> _progress = const [];

  static final _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: math
        .pow(
          2 *
              math.pi /
              (MotionMetrics.liquidExpandDuration.inMicroseconds / 1e6),
          2,
        )
        .toDouble(),
    ratio: MotionMetrics.liquidExpandDampingRatio,
  );

  static final _collapseSpring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: math
        .pow(
          2 *
              math.pi /
              (MotionMetrics.liquidCollapseDuration.inMicroseconds / 1e6),
          2,
        )
        .toDouble(),
    ratio: 1.0,
  );

  static const _tolerance = Tolerance(distance: 0.01, velocity: 0.05);

  static List<GlobalKey> _keys(int count) =>
      List.generate(count, (_) => GlobalKey());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  void _notifyCollapsedAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.collapsing) widget.onCollapsed?.call();
    });
  }

  @override
  void didUpdateWidget(covariant LiquidSplit oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.axis != oldWidget.axis) {
      _ticker.stop();
      _anchorRect = null;
      _deltas = const [];
      _from = const [];
      _progress = const [];
      if (widget.collapsing) _notifyCollapsedAfterFrame();
      return;
    }
    if (widget.items.length != oldWidget.items.length) {
      _ticker.stop();
      _itemKeys = _keys(widget.items.length);
      _anchorRect = null;
      if (widget.collapsing) {
        _deltas = const [];
        _from = const [];
        _progress = const [];
        _notifyCollapsedAfterFrame();
        return;
      }
      if (_deltas != null) {
        _deltas = const [];
        _from = const [];
        _progress = const [];
      }
      return;
    }
    if (widget.anchor != oldWidget.anchor) {
      _ticker.stop();
      _anchorRect = null;
      if (widget.collapsing) {
        _deltas = const [];
        _from = const [];
        _progress = const [];
        _notifyCollapsedAfterFrame();
        return;
      }
      _deltas = null;
      _from = const [];
      _progress = const [];
      WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
      return;
    }
    if (widget.collapsing != oldWidget.collapsing) {
      final count = _itemKeys.length;
      if (AppMotion.reduced(context) || _deltas == null || _deltas!.isEmpty) {
        _ticker.stop();
        if (widget.collapsing) {
          _notifyCollapsedAfterFrame();
        } else if (_deltas != null) {
          _from = List.filled(count, 1.0);
          _progress = List.filled(count, 1.0);
        }
        return;
      }
      if (widget.collapsing) {
        final current = _progress.length == count
            ? List<double>.of(_progress)
            : List<double>.filled(count, 1.0);
        if (current.every((value) => value <= 0.001)) {
          _ticker.stop();
          _from = List.filled(count, 0.0);
          _progress = List.filled(count, 0.0);
          _notifyCollapsedAfterFrame();
          return;
        }
        _from = current;
        _ticker
          ..stop()
          ..start();
      } else {
        final current = _progress.length == count
            ? List<double>.of(_progress)
            : List<double>.filled(count, 0.0);
        _from = current;
        if (current.every((value) => value >= 0.999)) {
          _ticker.stop();
          _progress = List.filled(count, 1.0);
          return;
        }
        _ticker
          ..stop()
          ..start();
      }
    }
  }

  void _begin() {
    if (!mounted) return;
    final stack = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final anchor =
        widget.anchor.currentContext?.findRenderObject() as RenderBox?;
    final boxes = <RenderBox>[
      for (final key in _itemKeys)
        if (key.currentContext?.findRenderObject() case final RenderBox box)
          if (box.hasSize) box,
    ];
    if (AppMotion.reduced(context) ||
        stack == null ||
        !stack.hasSize ||
        anchor == null ||
        !anchor.hasSize ||
        boxes.length != _itemKeys.length ||
        boxes.isEmpty) {
      setState(() {
        _anchorRect = null;
        _deltas = const [];
        _from = const [];
        _progress = const [];
      });
      if (widget.collapsing) _notifyCollapsedAfterFrame();
      return;
    }
    final anchorTopLeft = stack.globalToLocal(
      anchor.localToGlobal(Offset.zero),
    );
    final anchorRect = anchorTopLeft & anchor.size;
    final deltas = <Offset>[];
    for (final box in boxes) {
      final center = stack.globalToLocal(
        box.localToGlobal(box.size.center(Offset.zero)),
      );
      deltas.add(anchorRect.center - center);
    }
    final initial = widget.collapsing ? 1.0 : 0.0;
    setState(() {
      _anchorRect = anchorRect;
      _deltas = deltas;
      _from = List.filled(deltas.length, initial);
      _progress = List.filled(deltas.length, initial);
    });
    _ticker
      ..stop()
      ..start();
  }

  void _tick(Duration elapsed) {
    final count = _itemKeys.length;
    if (_deltas == null || _deltas!.length != count || count == 0) {
      _ticker.stop();
      if (widget.collapsing) widget.onCollapsed?.call();
      return;
    }
    final seconds = elapsed.inMicroseconds / 1e6;
    final collapsing = widget.collapsing;
    final stagger =
        (collapsing
                ? MotionMetrics.liquidCollapseStagger
                : MotionMetrics.liquidStagger)
            .inMicroseconds /
        1e6;
    final spring = collapsing ? _collapseSpring : _spring;
    final to = collapsing ? 0.0 : 1.0;
    final starts = _from.length == count
        ? _from
        : List<double>.filled(count, collapsing ? 1.0 : 0.0);
    var done = true;
    final progress = <double>[];
    for (var index = 0; index < count; index++) {
      final start = starts[index];
      if ((start - to).abs() < 0.001) {
        progress.add(to);
        continue;
      }
      final order = collapsing ? count - 1 - index : index;
      final time = math.max(0.0, seconds - order * stagger);
      final simulation = SpringSimulation(
        spring,
        start,
        to,
        0,
        tolerance: _tolerance,
      );
      progress.add(simulation.x(time));
      if (!simulation.isDone(time)) done = false;
    }
    setState(() => _progress = progress);
    if (!done) return;
    _ticker.stop();
    setState(() {
      _from = List<double>.filled(count, to);
      _progress = List<double>.filled(count, to);
    });
    if (collapsing) widget.onCollapsed?.call();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deltas = _deltas;
    final count = _itemKeys.length;
    final validDeltas =
        deltas != null && deltas.length == count && _progress.length == count;
    final transformable = validDeltas && count > 0 && deltas.isNotEmpty;
    final moving = _ticker.isActive && transformable;
    final keepOffset = moving || (widget.collapsing && transformable);
    var blobFactor = 0.0;
    if (moving) {
      final peak = _progress.fold<double>(0.0, (best, value) {
        final remaining = widget.collapsing
            ? value.clamp(0.0, 1.0)
            : (1.0 - value).clamp(0.0, 1.0);
        return math.max(best, remaining);
      });
      blobFactor = widget.collapsing
          ? ((peak - 0.05) / 0.55).clamp(0.0, 1.0)
          : ((peak - 0.12) / 0.55).clamp(0.0, 1.0);
    }
    final stackBox = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    final flex = Flex(
      key: widget.scrollable ? null : widget.flexKey,
      direction: widget.axis,
      mainAxisSize: MainAxisSize.min,
      spacing: widget.spacing,
      children: [
        ?widget.lead,
        for (final (index, item) in widget.items.indexed)
          KeyedSubtree(
            key: _itemKeys[index],
            child: deltas == null
                ? Opacity(opacity: 0, child: item)
                : !keepOffset
                ? item
                : Transform.translate(
                    offset: deltas[index] * (1 - _progress[index]),
                    child: item,
                  ),
          ),
      ],
    );
    final layout = widget.scrollable
        ? SingleChildScrollView(
            key: widget.flexKey,
            scrollDirection: widget.axis,
            clipBehavior: moving ? Clip.none : Clip.hardEdge,
            child: flex,
          )
        : flex;
    return Stack(
      key: _stackKey,
      clipBehavior: Clip.none,
      children: [
        if (moving &&
            blobFactor > 0.001 &&
            stackBox != null &&
            stackBox.hasSize)
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: MotionMetrics.liquidOpacity * blobFactor,
                child: ColorFiltered(
                  colorFilter: const ColorFilter.matrix([
                    1, 0, 0, 0, 0,
                    0, 1, 0, 0, 0,
                    0, 0, 1, 0, 0,
                    0, 0, 0, 22, -9 * 255,
                  ]),
                  child: ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(
                      sigmaX: MotionMetrics.liquidBlur,
                      sigmaY: MotionMetrics.liquidBlur,
                    ),
                    child: CustomPaint(
                      painter: _LiquidPainter(
                        color: widget.color,
                        anchor: _anchorRect,
                        items: [
                          for (final (index, key) in _itemKeys.indexed)
                            if (key.currentContext?.findRenderObject()
                                case final RenderBox box)
                              if (box.hasSize)
                                stackBox.globalToLocal(
                                          box.localToGlobal(Offset.zero),
                                        ) +
                                        deltas[index] * (1 - _progress[index]) &
                                    box.size,
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        IgnorePointer(ignoring: widget.collapsing, child: layout),
      ],
    );
  }
}

class _LiquidPainter extends CustomPainter {
  _LiquidPainter({
    required this.color,
    required this.anchor,
    required this.items,
  });

  final Color color;
  final Rect? anchor;
  final List<Rect> items;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (final rect in [?anchor, ...items]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(8)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LiquidPainter oldDelegate) => true;
}
