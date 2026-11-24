import 'package:flutter/material.dart';

import '../common/constants/glass_metrics.dart';
import '../common/widgets/app_motion.dart';

/// 同一分组记录共用的纯色圆角卡片（#67「历史列表」「生词本」）：
/// r12 圆角、0.5pt 外轮廓、左右内边距 16，组内条目之间以 0.5pt 细线分隔，不逐行创建玻璃材料。
class HistoryGroupCard extends StatelessWidget {
  /// children 为同组内按顺序排列的记录行；返回共用一张圆角卡片的列表容器。
  const HistoryGroupCard({super.key, required this.children});

  final List<Widget> children;

  /// context 提供明暗外观；返回含组内 0.5pt 分隔线的 r12 卡片。
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final line = (dark ? Colors.white : Colors.black).withValues(alpha: 0.10);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: dark ? const Color(0xFF232326) : Colors.white,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.groupRadius),
          side: BorderSide(color: line, width: GlassMetrics.groupBorderWidth),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: GlassMetrics.panelPadding,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: GlassMetrics.groupDividerThickness,
                    thickness: GlassMetrics.groupDividerThickness,
                    color: line,
                  ),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 历史与生词条目右下角的普通图标按钮（#67「历史列表」）：
/// 可见 24×24、r6 圆角、命中 32×32，不使用原生玻璃材料。
class HistoryHoverIconButton extends StatefulWidget {
  /// tooltip 为悬停提示，icon 为 16pt 图标，onPressed 为点击回调（为空表示禁用），
  /// semanticsLabel 为读屏标签，busy 为真时显示禁用或进度状态。
  const HistoryHoverIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.semanticsLabel,
    this.busy = false,
  });

  final String tooltip;
  final Widget icon;
  final VoidCallback? onPressed;
  final String? semanticsLabel;
  final bool busy;

  /// 无参数；返回维护悬停与按压视觉底块的状态。
  @override
  State<HistoryHoverIconButton> createState() => _HistoryHoverIconButtonState();
}

class _HistoryHoverIconButtonState extends State<HistoryHoverIconButton> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  /// context 提供主题色；返回 32×32 命中区与居中 24×24/r6 普通图标按钮。
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = widget.onPressed != null && !widget.busy;
    final fillAlpha = !enabled
        ? 0.0
        : _pressed
        ? GlassMetrics.pressedOpacity
        : (_hovered || _focused)
        ? GlassMetrics.hoverOpacity
        : 0.0;

    return Semantics(
      label: widget.semanticsLabel,
      button: true,
      enabled: enabled,
      child: Tooltip(
        message: widget.tooltip,
        child: SizedBox.square(
          dimension: GlassMetrics.hitSize,
          child: Center(
            child: InkWell(
              onTap: enabled ? widget.onPressed : null,
              onHover: (value) => setState(() => _hovered = value),
              onHighlightChanged: (value) => setState(() => _pressed = value),
              onFocusChange: (value) => setState(() => _focused = value),
              borderRadius: BorderRadius.circular(GlassMetrics.menuItemRadius),
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              splashColor: Colors.transparent,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: fillAlpha > 0
                      ? colors.onSurface.withValues(alpha: fillAlpha)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(
                    GlassMetrics.menuItemRadius,
                  ),
                  border: _focused
                      ? Border.all(
                          color: colors.primary,
                          width: GlassMetrics.focusRingWidth,
                        )
                      : null,
                ),
                child: SizedBox.square(
                  dimension: 24,
                  child: Center(
                    child: IconTheme(
                      data: IconThemeData(
                        size: GlassMetrics.icon,
                        color: enabled
                            ? colors.onSurfaceVariant
                            : colors.onSurfaceVariant.withValues(alpha: 0.38),
                      ),
                      child: widget.icon,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 历史与生词条目的悬停感知容器；静息隐藏操作按钮，鼠标悬停或键盘聚焦条目时在右下角显示。
class HistoryHoverRow extends StatefulWidget {
  /// builder 接收当前是否应展示悬停操作区；forceActionsVisible 为真时持续展示操作区。
  const HistoryHoverRow({
    super.key,
    required this.builder,
    this.forceActionsVisible = false,
  });

  final Widget Function(BuildContext context, bool showActions) builder;
  final bool forceActionsVisible;

  /// 无参数；返回维护悬停与焦点可见性的状态。
  @override
  State<HistoryHoverRow> createState() => _HistoryHoverRowState();
}

class _HistoryHoverRowState extends State<HistoryHoverRow> {
  bool _hovered = false;
  bool _focused = false;

  /// context 提供上下文与减少动态效果设置；构建上下 10pt 内边距的条目容器。
  @override
  Widget build(BuildContext context) {
    final visible = _hovered || _focused || widget.forceActionsVisible;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        skipTraversal: true,
        onFocusChange: (hasFocus) {
          if (_focused != hasFocus) setState(() => _focused = hasFocus);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: widget.builder(context, visible),
        ),
      ),
    );
  }
}

/// 包裹悬停才出现的操作区；结合透明过渡与点击屏蔽，并遵循减少动态效果偏好。
class HistoryHoverActions extends StatelessWidget {
  /// visible 控制显隐，child 为并排的普通图标按钮。
  const HistoryHoverActions({
    super.key,
    required this.visible,
    required this.child,
  });

  final bool visible;
  final Widget child;

  /// context 提供无障碍动效偏好；返回显隐动画包裹的操作区。
  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.reduced(context)
        ? Duration.zero
        : GlassMetrics.transition;
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: duration,
      child: IgnorePointer(ignoring: !visible, child: child),
    );
  }
}
