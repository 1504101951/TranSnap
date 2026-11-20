import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:motor/motor.dart';

import '../constants/glass_metrics.dart';
import '../constants/motion_metrics.dart';
import '../constants/translation_phase.dart';

/// 界面动效公共工具：统一提供系统无障碍降级判断与 Bouncy 物理弹簧配置（#142）。
abstract final class AppMotion {
  /// context 提供媒体查询；返回是否应跳过非必要位移与光学动画。
  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  /// context 提供无障碍偏好；返回 Bouncy 物理弹簧（减少动态效果时退化为零时长线性过渡，常态精确落到终点）。
  static Motion bouncy(BuildContext context) => reduced(context)
      ? const Motion.linear(Duration.zero)
      : const CupertinoMotion.bouncy(
          duration: MotionMetrics.bouncyDuration,
          extraBounce: MotionMetrics.bouncyExtraBounce,
          snapToEnd: true,
        );
}

/// 首次挂载或键变更时的 Bouncy 物理弹性进场（#142）；收敛后剥离变换包装，避免静态阶段亚像素偏差。
class BouncyPresence extends StatefulWidget {
  /// child 为受控组件，fromScale 为起始缩放比；减少动态效果时直接输出 child。
  const BouncyPresence({
    super.key,
    required this.child,
    this.fromScale = 0.92,
  });

  final Widget child;
  final double fromScale;

  /// 无参数；创建弹性进场收敛跟踪状态。
  @override
  State<BouncyPresence> createState() => _BouncyPresenceState();
}

class _BouncyPresenceState extends State<BouncyPresence> {
  bool _settled = false;

  /// context 提供主题与无障碍设置；返回物理弹性进场包装后的组件。
  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) return widget.child;
    return SingleMotionBuilder(
      from: widget.fromScale,
      value: 1.0,
      motion: AppMotion.bouncy(context),
      onAnimationStatusChanged: (status) {
        if (status == AnimationStatus.completed && !_settled && mounted) {
          setState(() => _settled = true);
        } else if (status == AnimationStatus.forward && _settled && mounted) {
          setState(() => _settled = false);
        }
      },
      child: widget.child,
      builder: (context, value, target) {
        // 弹簧稳定后锁定精确 1.0，但保留同构层级以免拆装底层 MenuAnchor 等有状态子控件。
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

/// 可取消延迟的 flutter_animate 效果宿主（#142）；避免内置 Future.delayed 在单帧卸载测试中残留未回收计时器。
class _ControlledAnimate extends StatefulWidget {
  /// child 为目标组件，effects 为顺序叠加的 flutter_animate 效果集合，delay 控制错峰起步，repeatCount 控制有限重复次数。
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

  /// 无参数；创建绑定生命周期的动画控制器状态。
  @override
  State<_ControlledAnimate> createState() => _ControlledAnimateState();
}

class _ControlledAnimateState extends State<_ControlledAnimate>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  Timer? _delayTimer;

  /// 无参数；计算效果链总时长并按 delay 同步或可取消地起步。
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
      // 仅在存在错峰延迟时建一个可取消 Timer，dispose 时立即撤回。
      _delayTimer = Timer(widget.delay, _start);
    }
  }

  /// effects 为动画效果列表；返回所有效果结束时刻的最大值（至少 1ms，避免 Interval 分母为零）。
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

  /// 无参数；按单次或有限重复模式启动控制器。
  void _start() {
    if (!mounted) return;
    if (widget.repeatCount > 1) {
      _controller.repeat(count: widget.repeatCount);
      return;
    }
    _controller.forward(from: 0);
  }

  /// 无参数；卸载前取消待触发错峰定时器并销毁控制器。
  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// context 提供树上下文；按 flutter_animate EffectEntry 依次包装效果并保持元素树同构。
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

/// 舒缓链式内容入场与错峰编排（#142）：淡入、微位移与可选高斯模糊消散，失败态支持轻抖。
class GentleReveal extends StatelessWidget {
  /// staggerIndex 控制错峰步进，blur 控制是否叠加高斯模糊消散（原生平台视图气泡关闭模糊），shakeOnError 触发失败轻抖。
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

  /// context 提供无障碍设置；返回舒缓链式入场后的组件。
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

/// 翻译等待首字时的玻璃骨架屏 Shimmer 扫光占位（#142）；有限周期避免在测试中永久阻塞。
class GentleShimmerSkeleton extends StatelessWidget {
  /// lines 控制展示骨架条行数；减少动态效果时仅展示静态半透明骨架条。
  const GentleShimmerSkeleton({super.key, this.lines = 2});

  final int lines;

  /// context 提供主题与无障碍设置；返回玻璃骨架条列。
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
                borderRadius: BorderRadius.circular(GlassMetrics.menuItemRadius),
              ),
            ),
          ),
      ],
    );
    if (AppMotion.reduced(context)) return bars;
    return _ControlledAnimate(
      repeatCount: 15,
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

/// 光学棱镜玻璃倒角前景层（#142）：通过 Impeller .frag 渲染 1.25pt 银白倒角与微弱色散，绝不触及底层 AppKitView。
class OpticalPrismOverlay extends StatefulWidget {
  /// child 为玻璃卡片内容，radius 为圆角，sweepTrigger 递增时触发一次斜向镜面扫光。
  const OpticalPrismOverlay({
    super.key,
    required this.child,
    this.radius = GlassMetrics.panelRadius,
    this.sweepTrigger = 0,
  });

  final Widget child;
  final double radius;
  final int sweepTrigger;

  /// 无参数；创建指针倾转与扫光驱动状态。
  @override
  State<OpticalPrismOverlay> createState() => _OpticalPrismOverlayState();
}

class _OpticalPrismOverlayState extends State<OpticalPrismOverlay>
    with SingleTickerProviderStateMixin {
  static Future<ui.FragmentProgram?>? _programLoader;
  ui.FragmentProgram? _program;
  late final AnimationController _sweepController;
  double _targetAngle = -math.pi * 0.28;

  /// 无参数；初始化有限时长扫光控制器并异步预热片段着色器。
  @override
  void initState() {
    super.initState();
    _sweepController = AnimationController(
      vsync: this,
      duration: MotionMetrics.prismSweepDuration,
    );
    unawaited(_ensureProgram());
  }

  /// oldWidget 为旧参数；sweepTrigger 递增且未开启减少动态效果时播放一次斜向表面扫光。
  @override
  void didUpdateWidget(OpticalPrismOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.sweepTrigger > oldWidget.sweepTrigger &&
        !AppMotion.reduced(context)) {
      _sweepController.forward(from: 0);
    }
  }

  /// 无参数；释放扫光控制器。
  @override
  void dispose() {
    _sweepController.dispose();
    super.dispose();
  }

  /// 无参数；加载并缓存 Impeller 片段着色器，无头测试环境加载失败时静默回退到静态细框绘制。
  Future<void> _ensureProgram() async {
    _programLoader ??= ui.FragmentProgram.fromAsset(
      MotionMetrics.prismShaderAsset,
    ).then<ui.FragmentProgram?>((value) => value).catchError((_) => null);
    final loaded = await _programLoader;
    if (mounted && loaded != null) {
      setState(() => _program = loaded);
    }
  }

  /// event 为悬停指针事件，box 为当前面板渲染盒；计算相对面板中心的受光角度。
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

  /// context 提供主题与无障碍偏好；返回包覆前景光学高光层的组件。
  @override
  Widget build(BuildContext context) {
    final reduced = AppMotion.reduced(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) => MouseRegion(
        opaque: false,
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

  /// canvas 与 size 为前景绘制矩形；写入着色器 uniform 并绘制光学棱镜倒角。
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

  /// canvas 与 size 为前景绘制矩形；在着色器就绪前或无头环境中绘制克制 1.25pt 静态细倒角线。
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

/// 1. 译文卡片标题区状态机微交互图标（#142）：忙碌旋转、完成描边打勾、失败轻抖红叉、待机微环。
class TranslationStatusIcon extends StatefulWidget {
  /// phase 为当前翻译会话阶段，size 为图标逻辑点尺寸。
  const TranslationStatusIcon({
    super.key,
    required this.phase,
    this.size = 14,
  });

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
    final popTarget =
        widget.phase == TranslationPhase.completed || isError ? 1.0 : 0.96;

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
      canvas.drawLine(center + Offset(-d, -d), center + Offset(d, d), crossPaint);
      canvas.drawLine(center + Offset(d, -d), center + Offset(-d, d), crossPaint);
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
      old.primary != primary;
}

/// 2. 朗读声波矢量微交互图标（#142）：未朗读保留 Icons.volume_up_rounded，朗读中切换为 5 柱光学声波。
class SpeechWaveIcon extends StatefulWidget {
  /// speaking 为当前是否在朗读，size 为图标逻辑点尺寸。
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
      return Icon(Icons.volume_up_rounded, size: widget.size);
    }
    final primary = Theme.of(context).colorScheme.primary;
    final reduced = AppMotion.reduced(context);
    final wave = SizedBox.square(
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
    );
    if (reduced) return wave;
    return SingleMotionBuilder(
      from: 0.72,
      value: 1.0,
      motion: AppMotion.bouncy(context),
      child: wave,
      builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
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
      final amp = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(phase * math.pi * 2 + i * 0.95));
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

/// 3. 加入生词本矢量微交互图标（#142）：Bouncy 弹性跃起并伴随 8 颗光学微粒子迸发。
class VocabularyBookmarkIcon extends StatefulWidget {
  /// saved 为是否已加入生词本，size 为图标逻辑点尺寸。
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
    final icon = Icon(
      widget.saved ? Icons.bookmark_added : Icons.bookmark_add_outlined,
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
          SingleMotionBuilder(
            key: ValueKey(widget.saved),
            from: widget.saved ? 0.68 : 1.08,
            value: 1.0,
            motion: AppMotion.bouncy(context),
            child: icon,
            builder: (context, scale, child) =>
                Transform.scale(scale: scale, child: child),
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
      final dist = baseR + progress * (size.shortestSide * 0.55);
      final pos = center + Offset(math.cos(angle) * dist, math.sin(angle) * dist);
      canvas.drawCircle(pos, 1.2 * (1.0 - progress * 0.4), paint);
    }
  }

  @override
  bool shouldRepaint(_SparkBurstPainter old) =>
      old.progress != progress || old.color != color;
}

/// 4. 复制确认矢量微交互图标（#142）：未复制保留 Icons.copy_rounded，触发或确认态描边打勾并在 1.3s 后自动回弹。
class CopyConfirmIcon extends StatefulWidget {
  /// copied 为外部显式确认态，trigger 递增时自驱动一次 1.3s 确认动效并自动回弹，size 为图标逻辑点尺寸。
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

  @override
  void initState() {
    super.initState();
    _confirmController = AnimationController(
      vsync: this,
      duration: MotionMetrics.copyConfirmDuration,
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed && _transientActive && mounted) {
          setState(() => _transientActive = false);
        }
      });
  }

  @override
  void didUpdateWidget(CopyConfirmIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.trigger > oldWidget.trigger) {
      if (AppMotion.reduced(context)) {
        setState(() => _transientActive = false);
      } else {
        setState(() => _transientActive = true);
        _confirmController.forward(from: 0);
      }
      return;
    }
    if (!oldWidget.copied && widget.copied) {
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
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.copied || _transientActive;
    if (!active) {
      return Icon(Icons.copy_rounded, size: widget.size);
    }
    final reduced = AppMotion.reduced(context);
    const success = Color(0xFF34C759);
    final check = SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _confirmController,
        builder: (context, _) {
          // 前 26% 时长完成描边打勾与扩散微环，其余时间保持清晰对勾直至回弹。
          final drawProgress = reduced
              ? 1.0
              : (_confirmController.value / 0.26).clamp(0.0, 1.0);
          return CustomPaint(
            painter: _CopyConfirmPainter(
              progress: drawProgress,
              color: success,
            ),
          );
        },
      ),
    );
    if (reduced) return check;
    return SingleMotionBuilder(
      from: 0.72,
      value: 1.0,
      motion: AppMotion.bouncy(context),
      child: check,
      builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
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

/// 5. 录制倒计时与 REC 脉冲微交互图标（#142）：倒计时数字弹跳与每秒有限脉动涟漪。
class RecordingPulseIcon extends StatefulWidget {
  /// countdown 为倒计时剩余秒数，active 为正在采集，paused 为已暂停，pulseKey 变更时触发一次有限脉冲。
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
    canvas.drawCircle(
      center,
      size.shortestSide * 0.26,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_RecordingDotPainter old) =>
      old.progress != progress || old.pulsing != pulsing || old.color != color;
}
