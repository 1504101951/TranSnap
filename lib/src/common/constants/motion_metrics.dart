import 'dart:ui';

/// 界面动效规格数值（#67、#142）；全应用统一弹簧、舒缓入场与光学棱镜高光参数。
abstract final class MotionMetrics {
  /// 物理弹簧周期与阻尼比（#67：420ms、0.62，对应 extraBounce = 0.08）。
  static const bouncyDuration = Duration(milliseconds: 420);
  static const bouncyDampingRatio = 0.62;
  static const bouncyExtraBounce = 0.08;

  /// 舒缓链式内容入场时长、错峰步进与初始模糊半径（#67：440ms、80ms、4pt）。
  static const gentleDuration = Duration(milliseconds: 440);
  static const staggerStep = Duration(milliseconds: 80);
  static const blurSigma = 4.0;
  static const gentleSlideOffset = 0.08;

  /// 失败轻抖反馈时长与横向偏移。
  static const shakeDuration = Duration(milliseconds: 440);
  static const shakeOffset = 6.0;

  /// 骨架 Shimmer 扫光周期。
  static const shimmerDuration = Duration(milliseconds: 1100);

  /// 光学棱镜倒角高光：1.25pt 描边、浅/暗峰值与冷暖色散（#67）。
  static const prismShaderAsset = 'shaders/optical_prism.frag';
  static const prismStrokeWidth = 1.25;
  static const prismLightPeakOpacity = 0.75;
  static const prismDarkPeakOpacity = 0.55;
  static const prismDispersionOpacity = 0.16;
  static const prismSweepDuration = Duration(milliseconds: 1100);
  static const prismCoolTint = Color(0xFF64B5F6);
  static const prismWarmTint = Color(0xFFFFCA80);

  /// 纯 Dart 矢量状态机微交互时序。
  static const copyConfirmDuration = Duration(milliseconds: 1300);
  static const statusDrawDuration = Duration(milliseconds: 340);
  static const statusSpinDuration = Duration(milliseconds: 1200);
  static const vocabBurstDuration = Duration(milliseconds: 550);
  static const speechWavePeriod = Duration(milliseconds: 900);
  static const recordingPulseDuration = Duration(milliseconds: 900);

  /// 等待进度环（#67 第 7 条）：弧长占周长比例、流动周期、完成闭合放大淡出时长与比例、
  /// 描边宽度、相对按钮外扩与圆角。
  static const busyRingArc = 0.28;
  static const busyRingPeriod = Duration(milliseconds: 1000);
  static const busyRingFinish = Duration(milliseconds: 500);
  static const busyRingFinishScale = 1.06;
  static const busyRingStroke = 1.5;
  static const busyRingOutset = 2.0;
  static const busyRingRadius = 10.0;

  /// 译文逐字显影（#67 第 8 条）：单字时长、错峰步进、同段错峰总长上限、起始模糊半径。
  static const charRevealDuration = Duration(milliseconds: 260);
  static const charRevealStagger = Duration(milliseconds: 18);
  static const charRevealMaxSpread = Duration(milliseconds: 600);
  static const charRevealBlur = 3.0;

  /// 截图选区流光边框（#67 第 9 条）：光段占周长比例、常态与拖动时的流动周期、线宽、外发光半径，
  /// 选区定下后继续流动的圈数与最后的淡出时长。
  static const selectionFlowLaps = 2;
  static const selectionFlowFadeOut = Duration(milliseconds: 600);
  static const selectionFlowArc = 0.22;
  static const selectionFlowPeriod = Duration(milliseconds: 2400);
  static const selectionFlowFastPeriod = Duration(milliseconds: 800);
  static const selectionFlowStroke = 2.0;
  static const selectionFlowGlow = 8.0;

  /// 工具栏液态展开（#67 第 10 条）：各按钮错峰、粘连模糊半径、液滴不透明度。
  static const liquidStagger = Duration(milliseconds: 40);
  static const liquidBlur = 5.0;
  static const liquidOpacity = 0.25;
}
