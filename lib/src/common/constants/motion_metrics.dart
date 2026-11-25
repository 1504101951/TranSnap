import 'dart:ui';

abstract final class MotionMetrics {
  static const bouncyDuration = Duration(milliseconds: 420);
  static const bouncyDampingRatio = 0.62;
  static const bouncyExtraBounce = 0.08;

  static const presenceDuration = Duration(milliseconds: 300);
  static const presenceExtraBounce = 0.07;

  static const iconSwitchDuration = Duration(milliseconds: 160);
  static const iconSwitchFromScale = 0.6;
  static const iconSwitchBlur = 2.0;

  static const skeletonFadeDuration = Duration(milliseconds: 120);

  static const gentleDuration = Duration(milliseconds: 440);
  static const staggerStep = Duration(milliseconds: 80);
  static const blurSigma = 4.0;
  static const gentleSlideOffset = 0.08;

  static const shakeDuration = Duration(milliseconds: 440);
  static const shakeOffset = 6.0;

  static const shimmerDuration = Duration(milliseconds: 1100);

  static const prismShaderAsset = 'shaders/optical_prism.frag';
  static const prismStrokeWidth = 1.25;
  static const prismLightPeakOpacity = 0.45;
  static const prismDarkPeakOpacity = 0.30;
  static const prismDispersionOpacity = 0.16;
  static const prismSweepDuration = Duration(milliseconds: 600);
  static const prismCoolTint = Color(0xFF64B5F6);
  static const prismWarmTint = Color(0xFFFFCA80);

  static const copyConfirmDuration = Duration(milliseconds: 1000);
  static const copyDrawFraction = 0.45;
  static const copyPeakScale = 1.12;
  static const statusDrawDuration = Duration(milliseconds: 340);
  static const statusSpinDuration = Duration(milliseconds: 1200);

  static const vocabBurstDuration = Duration(milliseconds: 420);
  static const vocabBurstSpread = 0.23;
  static const speechWavePeriod = Duration(milliseconds: 900);
  static const recordingPulseDuration = Duration(milliseconds: 900);

  static const busyRingArc = 0.28;
  static const busyRingPeriod = Duration(milliseconds: 1000);
  static const busyRingFinish = Duration(milliseconds: 500);
  static const busyRingFinishScale = 1.06;
  static const busyRingStroke = 1.5;
  static const busyRingOutset = 2.0;
  static const busyRingRadius = 10.0;

  static const charRevealDuration = Duration(milliseconds: 180);
  static const charRevealStagger = Duration(milliseconds: 12);
  static const charRevealMaxSpread = Duration(milliseconds: 600);
  static const charRevealBlur = 3.0;

  static const liquidExpandDuration = Duration(milliseconds: 240);
  static const liquidExpandDampingRatio = 0.78;
  static const liquidStagger = Duration(milliseconds: 20);
  static const liquidBlur = 5.0;
  static const liquidOpacity = 0.25;
  static const liquidCollapseDuration = Duration(milliseconds: 120);
  static const liquidCollapseStagger = Duration(milliseconds: 10);
}
