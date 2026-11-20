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
}
