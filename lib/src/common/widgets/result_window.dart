import 'package:flutter/material.dart';

import '../constants/glass_metrics.dart';
import '../constants/motion_metrics.dart';
import 'app_motion.dart';
import 'native_glass.dart';

/// 统一结果窗口的颜色规范（#67「采集工具与媒体结果」第 4、7 条）。
abstract final class ResultWindowColors {
  /// dark 为当前外观；返回媒体区中性衬底色。
  static Color canvas(bool dark) =>
      dark ? const Color(0xFF1C1C1E) : const Color(0xFFE9E9EB);

  /// dark 为当前外观；返回与截图工具栏分区块同色的底部实底操作栏底色。
  static Color bar(bool dark) =>
      dark ? const Color(0xFF2A2A2D) : const Color(0xFFFBFBFC);

  /// dark 为当前外观；返回与截图工具栏托盘同色的二级/属性托盘底色。
  static Color tray(bool dark) =>
      dark ? const Color(0xFF1D1D1F) : const Color(0xFFECECED);

  /// dark 为当前外观；返回 0.5pt 顶边线与分隔线颜色。
  static Color hairline(bool dark) =>
      (dark ? Colors.white : Colors.black).withValues(alpha: 0.12);

  /// 媒体外框 0.5pt 描边与阴影色（18% 黑）。
  static const mediaBorder = Color(0x2E000000);
}

/// 统一结果窗口中部媒体衬底：填充中性衬底色并在需要时挂载内部滚动视图（#67、#145）。
class ResultWindowCanvas extends StatelessWidget {
  /// child 为居中或可滚动的媒体容器；alignment 控制居中对齐；backgroundColor 可覆盖默认衬底色。
  const ResultWindowCanvas({
    super.key,
    required this.child,
    this.alignment = Alignment.center,
    this.backgroundColor,
  });

  final Widget child;
  final AlignmentGeometry alignment;
  final Color? backgroundColor;

  /// context 为主题上下文；返回中性衬底与居中容器，无返回值。
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ColoredBox(
      key: const Key('result-window-canvas'),
      color: backgroundColor ?? ResultWindowColors.canvas(dark),
      child: Align(alignment: alignment, child: child),
    );
  }
}

/// 媒体展示外框：附带 0.5pt 描边（18% 黑）与 0 6 20 / 18% 黑投影（#67）。
class ResultMediaFrame extends StatelessWidget {
  /// child 为等比缩放后的视频、长图或可标注图片画布。
  const ResultMediaFrame({super.key, required this.child});

  final Widget child;

  /// context 为主题上下文；用 foregroundDecoration 描边避免挤压子视图尺寸。
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      boxShadow: [
        BoxShadow(
          color: ResultWindowColors.mediaBorder,
          blurRadius: 20,
          offset: Offset(0, 6),
        ),
      ],
    ),
    child: DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: Border.all(color: ResultWindowColors.mediaBorder, width: 0.5),
      ),
      child: child,
    ),
  );
}

/// 统一结果窗口底部操作栏：高 52pt、实底、顶部 0.5pt 细线，左右分组以 4pt 间距排布（#67、#145）。
class ResultWindowBar extends StatelessWidget {
  /// leading 为左侧媒体处理控件列表，trailing 为右侧去向操作列表。
  const ResultWindowBar({
    super.key,
    required this.leading,
    required this.trailing,
  });

  final List<Widget> leading;
  final List<Widget> trailing;

  /// context 为主题上下文；返回固定 52pt 高的底部操作栏。
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      key: const Key('result-window-bar'),
      height: GlassMetrics.resultBarHeight,
      decoration: BoxDecoration(
        color: ResultWindowColors.bar(dark),
        border: Border(
          top: BorderSide(color: ResultWindowColors.hairline(dark), width: 0.5),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          primary: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: GlassMetrics.space12,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(mainAxisSize: MainAxisSize.min, children: _withGap(leading)),
                  const SizedBox(width: GlassMetrics.space12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: _withGap(trailing),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// items 为同一侧控件；在相邻元素间插入 4pt 间距。
  List<Widget> _withGap(List<Widget> items) {
    if (items.isEmpty) return const [];
    return [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) const SizedBox(width: GlassMetrics.space4),
        items[i],
      ],
    ];
  }
}

/// 底部操作栏分组竖线：1×20pt，两侧各留 6pt 间距（#67）。
class ResultBarDivider extends StatelessWidget {
  /// 无参数；构造标准竖向分隔线。
  const ResultBarDivider({super.key});

  /// context 为主题上下文；返回居中显示的 1×20 竖线。
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: GlassMetrics.resultDividerGap,
      ),
      child: SizedBox(
        width: GlassMetrics.resultDividerWidth,
        height: GlassMetrics.resultDividerHeight,
        child: ColoredBox(color: ResultWindowColors.hairline(dark)),
      ),
    );
  }
}

/// 底部操作栏文字按钮：高 28pt、r8、水平内边距 12、13pt 文字与可选 14pt 图标，支持主动作「保存」与弱化「放弃」（#67）。
class ResultTextButton extends StatelessWidget {
  /// label 为按钮文字，onPressed 为点击回调，icon 为可选前置 14pt 图标，
  /// trailing 为可选尾部指示（如展开箭头），primary 启用强调色实底，weak 使用次级文字色，
  /// busy 为真时在外圈显示等待进度环，tooltip 为可选悬停说明，buttonKey 为测试或语义锚定键。
  const ResultTextButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.trailing,
    this.primary = false,
    this.weak = false,
    this.busy = false,
    this.tooltip,
    this.buttonKey,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final IconData? trailing;
  final bool primary;
  final bool weak;
  final bool busy;
  final String? tooltip;
  final Key? buttonKey;

  /// context 为主题上下文；返回符合 28pt/r8 规格的扁平或主操作文字按钮。
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final accentFill = NativeGlassTheme.accentFillOf(context);
    final onAccent = NativeGlassTheme.onAccentOf(context);
    final fg = primary
        ? onAccent
        : weak
        ? colors.onSurfaceVariant
        : colors.onSurface;
    final effectiveFg = enabled ? fg : fg.withValues(alpha: 0.42);
    final bg = primary
        ? (enabled ? accentFill : accentFill.withValues(alpha: 0.42))
        : Colors.transparent;

    Widget button = DecoratedBox(
      decoration: ShapeDecoration(
        color: bg,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
        ),
      ),
      child: NativeGlassButtonFeedback(
        radius: GlassMetrics.controlRadius,
        enabled: enabled,
        bezel: false,
        child: SizedBox(
          height: GlassMetrics.buttonHeight,
          child: TextButton(
            key: buttonKey,
            onPressed: onPressed,
            style: ButtonStyle(
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: GlassMetrics.space12),
              ),
              minimumSize: const WidgetStatePropertyAll(
                Size(0, GlassMetrics.buttonHeight),
              ),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
              overlayColor: WidgetStatePropertyAll(
                primary
                    ? onAccent.withValues(alpha: 0.10)
                    : colors.onSurface.withValues(alpha: GlassMetrics.hoverOpacity),
              ),
              foregroundColor: WidgetStatePropertyAll(effectiveFg),
              shape: WidgetStatePropertyAll(
                RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(
                    GlassMetrics.controlRadius,
                  ),
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: effectiveFg),
                  const SizedBox(width: GlassMetrics.iconGap),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: GlassMetrics.bodyFont,
                    height: GlassMetrics.bodyLine / GlassMetrics.bodyFont,
                    fontWeight: primary ? FontWeight.w500 : FontWeight.w400,
                    color: effectiveFg,
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 2),
                  Icon(trailing, size: 14, color: effectiveFg),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (tooltip != null) {
      button = Tooltip(message: tooltip!, child: button);
    }
    return BusyRing(
      active: busy,
      color: NativeGlassTheme.accentOf(context),
      radius: GlassMetrics.controlRadius + MotionMetrics.busyRingOutset,
      child: button,
    );
  }
}

/// 底部操作栏图标按钮：32×32pt、r8、16pt 图标，选中时使用 accentFill 实底配 onAccent 前景（#67）。
class ResultIconButton extends StatelessWidget {
  /// icon 为图标，tooltip 为提示与可访问名称，onPressed 为点击回调，selected 控制强调色选中态，
  /// compact 为托盘内 28pt/14pt 紧凑尺寸，buttonKey 为测试或锚定键。
  const ResultIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.compact = false,
    this.busy = false,
    this.buttonKey,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final bool compact;
  final bool busy;
  final Key? buttonKey;

  /// context 为主题上下文；返回带悬停叠加层与强调色选中态的图标按钮。
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final accentFill = NativeGlassTheme.accentFillOf(context);
    final onAccent = NativeGlassTheme.onAccentOf(context);
    final size = compact ? 28.0 : GlassMetrics.hitSize;
    final radius = compact ? 7.0 : GlassMetrics.controlRadius;
    final iconSize = compact ? 14.0 : GlassMetrics.icon;
    final fg = selected ? onAccent : colors.onSurface;
    final effectiveFg = enabled ? fg : fg.withValues(alpha: 0.42);
    final bg = selected
        ? (enabled ? accentFill : accentFill.withValues(alpha: 0.42))
        : Colors.transparent;

    return BusyRing(
      active: busy,
      color: NativeGlassTheme.accentOf(context),
      radius: radius + MotionMetrics.busyRingOutset,
      child: Semantics(
        selected: selected,
        label: tooltip,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: bg,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(radius),
            ),
          ),
          child: NativeGlassButtonFeedback(
            radius: radius,
            enabled: enabled,
            bezel: false,
            child: SizedBox.square(
              dimension: size,
              child: IconButton(
                key: buttonKey,
                tooltip: tooltip,
                onPressed: onPressed,
                style: ButtonStyle(
                  padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                  backgroundColor: const WidgetStatePropertyAll(
                    Colors.transparent,
                  ),
                  overlayColor: WidgetStatePropertyAll(
                    selected
                        ? onAccent.withValues(alpha: 0.10)
                        : colors.onSurface.withValues(
                            alpha: GlassMetrics.hoverOpacity,
                          ),
                  ),
                  foregroundColor: WidgetStatePropertyAll(effectiveFg),
                  shape: WidgetStatePropertyAll(
                    RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(radius),
                    ),
                  ),
                ),
                icon: Icon(icon, size: iconSize, color: effectiveFg),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 打开图片结果页工具行向上展开的属性托盘：底色与截图托盘一致，底部三角朝下指向锚点按钮（#67、#145）。
class ResultUpwardTray extends StatelessWidget {
  /// children 为托盘内紧凑按钮与分组竖线，anchorCenterX 为锚点按钮中心相对托盘容器的水平坐标。
  const ResultUpwardTray({
    super.key,
    required this.children,
    required this.anchorCenterX,
  });

  final List<Widget> children;
  final double anchorCenterX;

  /// context 为主题上下文；返回带 0.5pt 描边、阴影与底部向下小三角的悬浮托盘。
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final trayColor = ResultWindowColors.tray(dark);
    final hairline = ResultWindowColors.hairline(dark);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        DecoratedBox(
          decoration: ShapeDecoration(
            color: trayColor,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(9),
              side: BorderSide(color: hairline, width: 0.5),
            ),
            shadows: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Row(mainAxisSize: MainAxisSize.min, children: children),
          ),
        ),
        Positioned(
          left: (anchorCenterX - 6).clamp(8.0, 400.0).toDouble(),
          bottom: -4,
          child: CustomPaint(
            size: const Size(12, 4),
            painter: _DownCaretPainter(trayColor),
          ),
        ),
      ],
    );
  }
}

/// 向下指的托盘指示三角，用于从底部结果工具栏向上展开的属性托盘（#67）。
class _DownCaretPainter extends CustomPainter {
  const _DownCaretPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_DownCaretPainter old) => old.color != color;
}
