import 'dart:ui';

/// 界面动效规格数值（#67、#142）；全应用统一弹簧、舒缓入场与光学棱镜高光参数。
abstract final class MotionMetrics {
  /// 物理弹簧周期与阻尼比（#67：420ms、0.62，对应 extraBounce = 0.08）。
  static const bouncyDuration = Duration(milliseconds: 420);
  static const bouncyDampingRatio = 0.62;
  static const bouncyExtraBounce = 0.08;

  /// 选区触发按钮与译文卡片入场弹簧（#142 第 1 条）：周期 300ms、阻尼比 0.78（snappy 基础回弹 0.15 加 0.07），过冲很小。
  static const presenceDuration = Duration(milliseconds: 300);
  static const presenceExtraBounce = 0.07;

  /// 图标 A 换成图标 B 的统一交叉过渡（#142 第 4 条）：160ms，旧图标缩到 0.6、模糊 2pt、淡出，新图标反向进入。
  static const iconSwitchDuration = Duration(milliseconds: 160);
  static const iconSwitchFromScale = 0.6;
  static const iconSwitchBlur = 2.0;

  /// 首字到达时加载骨架淡出时长（#142 第 2 条）。
  static const skeletonFadeDuration = Duration(milliseconds: 120);

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
  static const prismLightPeakOpacity = 0.45;
  static const prismDarkPeakOpacity = 0.30;
  static const prismDispersionOpacity = 0.16;
  static const prismSweepDuration = Duration(milliseconds: 600);
  static const prismCoolTint = Color(0xFF64B5F6);
  static const prismWarmTint = Color(0xFFFFCA80);

  /// 纯 Dart 矢量状态机微交互时序。复制确认共停留 1000ms：前 45%（450ms）完成描边打勾与 0.6→1.12→1 回弹（#142 第 4 条）。
  static const copyConfirmDuration = Duration(milliseconds: 1000);
  static const copyDrawFraction = 0.45;
  static const copyPeakScale = 1.12;
  static const statusDrawDuration = Duration(milliseconds: 340);
  static const statusSpinDuration = Duration(milliseconds: 1200);

  /// 生词本 8 粒子迸发 420ms，粒子外扩距离占图标边长的比例（14pt 图标约 12pt 半径）（#142 第 4 条）。
  static const vocabBurstDuration = Duration(milliseconds: 420);
  static const vocabBurstSpread = 0.23;
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
  static const charRevealDuration = Duration(milliseconds: 180);
  static const charRevealStagger = Duration(milliseconds: 12);
  static const charRevealMaxSpread = Duration(milliseconds: 600);
  static const charRevealBlur = 3.0;

  /// 工具栏液态展开（#67 第 10 条）：展开/收起弹簧周期、阻尼、各按钮错峰、粘连模糊半径与液滴不透明度。
  static const liquidExpandDuration = Duration(milliseconds: 240);
  static const liquidExpandDampingRatio = 0.78;
  static const liquidStagger = Duration(milliseconds: 20);
  static const liquidBlur = 5.0;
  static const liquidOpacity = 0.25;
  static const liquidCollapseDuration = Duration(milliseconds: 120);
  static const liquidCollapseStagger = Duration(milliseconds: 10);
}
