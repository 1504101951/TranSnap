import '../constants/method_names.dart';
import '../constants/channel_names.dart';
import '../constants/preference_keys.dart';
import '../constants/platform_view_types.dart';
import '../constants/glass_metrics.dart';
import '../constants/motion_metrics.dart';
import '../constants/appearance_modes.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:motor/motor.dart';

import 'app_motion.dart';

/// 普通窗口的连续阅读底色；四角由AppKit统一裁剪，Flutter只绘制内容，不另画面板。
class NativeGlassWindowPage extends StatelessWidget {
  /// child为窗口内容；与原生标题区使用同一不透明语义色。
  const NativeGlassWindowPage({super.key, required this.child});
  final Widget child;

  /// context提供当前外观；返回无内部圆角或顶部接缝的页面背景。
  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: Theme.of(context).colorScheme.surface, child: child);
}

/// macOS 原生玻璃材料；AppKit 处理折射及系统可访问性，Flutter 保留业务和交互。
class NativeGlassSurface extends StatelessWidget {
  /// child 为前景控件，radius 为逻辑点圆角，busy 为按钮等待进度环开关；创建单个材料层，不对子内容做图像滤镜。
  const NativeGlassSurface({
    super.key,
    required this.child,
    this.radius,
    this.material = false,
    this.busy = false,
  });

  final Widget child;
  final double? radius;

  /// 页面只绘制阅读背景，独立交互控件才启用原生折射，避免嵌套。
  final bool material;

  /// 为 true 时在材料外扩 2pt 绘制强调色进度环；内部结构恒定，不重建原生材料（#142）。
  final bool busy;

  /// child 为传入前景；穿透透明包装层递归识别底层按钮与启用回调，返回按钮标记、实底标记及回调。
  static ({bool isButton, bool isFilled, VoidCallback? onPressed})
  _inspectButton(Widget child) {
    Widget current = child;
    while (true) {
      if (current is ButtonStyleButton) {
        return (
          isButton: true,
          isFilled: current is FilledButton,
          onPressed: current.onPressed,
        );
      }
      if (current is IconButton) {
        return (
          isButton: true,
          isFilled: false,
          onPressed: current.onPressed,
        );
      }
      if (current is Semantics && current.child != null) {
        current = current.child!;
      } else if (current is MergeSemantics && current.child != null) {
        current = current.child!;
      } else if (current is SizedBox && current.child != null) {
        current = current.child!;
      } else if (current is ConstrainedBox && current.child != null) {
        current = current.child!;
      } else if (current is Tooltip && current.child != null) {
        current = current.child!;
      } else if (current is KeyedSubtree) {
        current = current.child;
      } else if (current is Padding && current.child != null) {
        current = current.child!;
      } else {
        return (isButton: false, isFilled: false, onPressed: null);
      }
    }
  }

  /// context 提供主题；返回原生材料与前景的有序叠放，材料不抢占手势。
  @override
  Widget build(BuildContext context) {
    final button = _inspectButton(child);
    final radius =
        this.radius ??
        (material
            ? (button.isFilled
                  ? GlassMetrics.primaryRadius
                  : GlassMetrics.controlRadius)
            : GlassMetrics.panelRadius);
    // 材料配置也是依赖；只改透明度时主题颜色可能不变，仍需更新原生视图。
    context.dependOnInheritedWidgetOfExactType<_GlassAppearanceScope>();
    final brightness = Theme.of(context).brightness;
    final highContrast = MediaQuery.highContrastOf(context);
    // 新弹窗成为活动层时，下面的页面使用普通内容底色，避免叠加两层折射。
    final activeLayer = ModalRoute.isCurrentOf(context) != false;
    if (material &&
        context.dependOnInheritedWidgetOfExactType<_GlassMaterialScope>() !=
            null) {
      // 下拉已选项等共享父材料；弹出路由脱离此scope后才创建自己的玻璃，按钮仍保留微交互与焦点环。
      return button.isButton
          ? NativeGlassButtonFeedback(
              radius: radius,
              enabled: button.onPressed != null,
              child: child,
            )
          : child;
    }
    if (!material) {
      return ClipRSuperellipse(
        borderRadius: BorderRadius.circular(radius),
        child: ColoredBox(
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.78),
          // 浮层不经过Scaffold，必须在阅读表面建立Material文本基底，避免继承诊断双下划线。
          child: Material(type: MaterialType.transparency, child: child),
        ),
      );
    }
    final glass = ClipRSuperellipse(
      borderRadius: BorderRadius.circular(radius),
      child: Stack(
        children: [
          if (!activeLayer)
            Positioned.fill(
              child: ColoredBox(color: Theme.of(context).colorScheme.surface),
            )
          else
            Positioned.fill(
              // 原生材料只绘图，Flutter平台视图包装层也必须退出键盘遍历。
              child: ExcludeFocus(
                child: ExcludeSemantics(
                  child: AppKitView(
                    key: ValueKey((
                      brightness,
                      highContrast,
                      radius,
                      GlassAppearance.current.value.opacity,
                    )),
                    viewType: PlatformViewTypes.nativeGlass,
                    creationParams: {
                      'cornerRadius': radius,
                      'brightness': brightness.name,
                      'highContrast': highContrast,
                      'opacity': GlassAppearance.current.value.opacity,
                    },
                    creationParamsCodec: const StandardMessageCodec(),
                    hitTestBehavior: PlatformViewHitTestBehavior.transparent,
                  ),
                ),
              ),
            ),
          Material(
            type: MaterialType.transparency,
            child: _GlassMaterialScope(child: child),
          ),
        ],
      ),
    );
    final interactiveGlass = button.isButton
        ? NativeGlassButtonFeedback(
            radius: radius,
            enabled: button.onPressed != null,
            child: glass,
          )
        : glass;
    // 放松列表的横向紧约束，让材料跟随前景尺寸；输入框/滑块自身仍填满可用宽度。
    // 外层始终包一层 BusyRing 保持子树结构恒定，等待态切换不重建底层 AppKitView（#142）。
    final surface = Align(
      alignment: AlignmentDirectional.centerStart,
      widthFactor: 1,
      heightFactor: 1,
      child: BusyRing(
        active: busy,
        color: NativeGlassTheme.accentOf(context),
        radius: radius + MotionMetrics.busyRingOutset,
        child: interactiveGlass,
      ),
    );
    if (!button.isButton) return surface;
    // 可见按钮保持28/30pt，外围透明命中区域至少32pt；标准按钮仍处理自身语义和键盘。
    return GestureDetector(
      excludeFromSemantics: true,
      behavior: HitTestBehavior.opaque,
      onTap: button.onPressed,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: GlassMetrics.hitSize,
          minHeight: GlassMetrics.hitSize,
        ),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          widthFactor: 1,
          heightFactor: 1,
          child: surface,
        ),
      ),
    );
  }
}

/// 复用标准按钮的动作与语义，统一提供悬停高光、按下弹性微缩及强调色焦点环（#67、#144）。
class NativeGlassButtonFeedback extends StatefulWidget {
  /// child 为可操作控件或完整玻璃胶囊，radius 为超椭圆圆角，enabled 决定是否响应交互反馈，
  /// inset 为外围命中与描边留白，hoverFeedback 控制悬停视觉层，pressScale 为按下缩放比例，
  /// accentHighlight 控制悬停边框是否使用强调色高光。
  const NativeGlassButtonFeedback({
    super.key,
    required this.child,
    required this.radius,
    required this.enabled,
    this.inset = EdgeInsets.zero,
    this.hoverFeedback = true,
    this.pressScale = GlassMetrics.buttonPressedScale,
    this.accentHighlight = false,
  });

  final Widget child;
  final double radius;
  final bool enabled;
  final EdgeInsets inset;
  final bool hoverFeedback;
  final double pressScale;
  final bool accentHighlight;

  /// 无参数；创建按钮瞬时交互状态，不持有业务数据。
  @override
  State<NativeGlassButtonFeedback> createState() =>
      _NativeGlassButtonFeedbackState();
}

/// 维护控件悬停、按下微缩和焦点绘制；业务动作仍由标准按钮处理。
class _NativeGlassButtonFeedbackState extends State<NativeGlassButtonFeedback> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  /// context 提供主题与动态效果偏好；抑制子按钮内置 Material 叠色与焦点边后统一绘制悬停、微缩与强调色焦点环。
  @override
  Widget build(BuildContext context) {
    final outerTheme = Theme.of(context);
    final colors = outerTheme.colorScheme;
    final accent = NativeGlassTheme.accentOf(context);
    final reduced = AppMotion.reduced(context);
    final alpha = !widget.enabled
        ? 0.0
        : _pressed
        ? (widget.hoverFeedback
              ? GlassMetrics.pressedOpacity
              : (Theme.of(context).brightness == Brightness.dark ? 0.10 : 0.08))
        : _hovered && widget.hoverFeedback
        ? GlassMetrics.hoverOpacity
        : 0.0;
    final BorderSide side;
    if (_focused && widget.enabled) {
      side = BorderSide(color: accent, width: GlassMetrics.focusRingWidth);
    } else if (_hovered && widget.enabled && widget.hoverFeedback) {
      side = BorderSide(
        color: widget.accentHighlight
            ? accent.withValues(alpha: 0.45)
            : colors.onSurface.withValues(alpha: 0.14),
        width: 1,
      );
    } else {
      side = BorderSide.none;
    }

    const transparentOverlay = WidgetStatePropertyAll(Colors.transparent);
    final noneSide = const WidgetStatePropertyAll(BorderSide.none);
    // 屏蔽内层 ButtonStyle 自带叠色与默认焦点边，避免与外层统一玻璃反馈重影。
    final cleanChild = Theme(
      data: outerTheme.copyWith(
        filledButtonTheme: FilledButtonThemeData(
          style: outerTheme.filledButtonTheme.style?.copyWith(
            overlayColor: transparentOverlay,
            side: noneSide,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: outerTheme.outlinedButtonTheme.style?.copyWith(
            overlayColor: transparentOverlay,
            side: WidgetStatePropertyAll(BorderSide(color: colors.outlineVariant)),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: outerTheme.textButtonTheme.style?.copyWith(
            overlayColor: transparentOverlay,
            side: noneSide,
          ),
        ),
        iconButtonTheme: IconButtonThemeData(
          style: outerTheme.iconButtonTheme.style?.copyWith(
            overlayColor: transparentOverlay,
            side: noneSide,
          ),
        ),
      ),
      child: widget.child,
    );

    final duration = reduced ? Duration.zero : GlassMetrics.transition;
    return Focus(
      canRequestFocus: false,
      onFocusChange: (value) => setState(() => _focused = value),
      onKeyEvent: (_, event) {
        if (event.logicalKey == LogicalKeyboardKey.space ||
            event.logicalKey == LogicalKeyboardKey.enter) {
          setState(() => _pressed = event is! KeyUpEvent);
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: Listener(
          onPointerDown: (_) => setState(() => _pressed = true),
          onPointerUp: (_) => setState(() => _pressed = false),
          onPointerCancel: (_) => setState(() => _pressed = false),
          child: AnimatedScale(
            scale: _pressed && widget.enabled && !reduced
                ? widget.pressScale
                : 1.0,
            duration: duration,
            curve: Curves.easeOutCubic,
            child: Stack(
              children: [
                cleanChild,
                Positioned.fill(
                  child: IgnorePointer(
                    child: Padding(
                      padding: widget.inset,
                      child: AnimatedContainer(
                        duration: duration,
                        decoration: ShapeDecoration(
                          color: colors.onSurface.withValues(alpha: alpha),
                          shape: RoundedSuperellipseBorder(
                            borderRadius: BorderRadius.circular(widget.radius),
                            side: side,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 字段标题、行内校验错误和说明位于材料外，避免浮动元素越过原生视图裁剪边界。
class NativeGlassField extends StatefulWidget {
  /// label 为可选字段标题，semanticLabel 在无可见标题时补足语义名，helper 为补充说明，
  /// errorText 为行内校验错误信息；child 是不带浮动标签的输入或选择控件。
  const NativeGlassField({
    super.key,
    this.label,
    required this.child,
    this.helper,
    this.semanticLabel,
    this.errorText,
  });

  final String? label;
  final String? helper;
  final String? semanticLabel;
  final String? errorText;
  final Widget child;

  /// 无参数；创建仅跟踪键盘焦点的状态，不持有业务输入。
  @override
  State<NativeGlassField> createState() => _NativeGlassFieldState();
}

/// 跟踪字段焦点以绘制连续曲线边框，不持有输入内容。
class _NativeGlassFieldState extends State<NativeGlassField> {
  bool _focused = false;

  /// context 提供主题；返回外置标题、连续圆角焦点/报错边框、报错行与说明，保留输入子树状态。
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasError = widget.errorText != null && widget.errorText!.isNotEmpty;
    final borderColor = hasError
        ? colors.error
        : (_focused
              ? NativeGlassTheme.accentOf(context)
              : colors.outlineVariant);
    final borderWidth = _focused
        ? GlassMetrics.focusRingWidth
        : (hasError ? 1.5 : 1.0);
    return Padding(
      padding: const EdgeInsets.only(bottom: GlassMetrics.space12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.label != null) ...[
            Text(
              widget.label!,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: GlassMetrics.labelGap),
          ],
          Semantics(
            label: widget.semanticLabel ?? widget.label,
            child: Focus(
              canRequestFocus: false,
              onFocusChange: (focused) => setState(() => _focused = focused),
              child: NativeGlassSurface(
                material: true,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: RoundedSuperellipseBorder(
                      borderRadius: BorderRadius.circular(
                        GlassMetrics.controlRadius,
                      ),
                      side: BorderSide(color: borderColor, width: borderWidth),
                    ),
                  ),
                  // 标题由外层承担；移除输入框自带圆弧边框，焦点只绘制一层连续曲线。
                  child: InputDecorationTheme(
                    data: const InputDecorationThemeData(
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      errorBorder: InputBorder.none,
                      focusedErrorBorder: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 7,
                      ),
                    ),
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ),
          if (hasError) ...[
            const SizedBox(height: GlassMetrics.space4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    Icons.error_outline,
                    size: 13,
                    color: colors.error,
                  ),
                ),
                const SizedBox(width: GlassMetrics.space4),
                Expanded(
                  child: Text(
                    widget.errorText!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: colors.error),
                  ),
                ),
              ],
            ),
          ],
          if (widget.helper != null) ...[
            const SizedBox(height: GlassMetrics.labelGap),
            Text(widget.helper!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// 设置行只给开关本身提供胶囊材料，标题与说明直接融入页面。
class NativeGlassSwitchTile extends StatelessWidget {
  /// title/subtitle 为文字语义，value 是开关状态，onChanged 为空表示禁用。
  const NativeGlassSwitchTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// context 提供控件主题；返回只有右侧按钮可交互的设置项。
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: subtitle == null
        ? null
        : Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
    // 标题和说明只读，避免点击文字意外更改并自动保存偏好。
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
    splashColor: Colors.transparent,
    minVerticalPadding: 0,
    minTileHeight: subtitle == null
        ? GlassMetrics.rowHeight
        : GlassMetrics.captionRowHeight,
    trailing: NativeGlassSwitch(
      value: value,
      onChanged: onChanged,
      label: title,
    ),
  );
}

/// 紧凑选择器；当前值与菜单分别布局，避免菜单内边距裁切选中值。
class NativeGlassDropdown<T> extends StatelessWidget {
  /// label/value/items 是字段名称、选中值和有序选项；caption 为标题下方说明，onChanged 为空表示禁用。
  const NativeGlassDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.caption,
  });
  final String label;
  final T value;
  final Map<T, String> items;
  final ValueChanged<T>? onChanged;
  final String? caption;

  /// 无参数；返回带字段名称的设置行，右侧为玻璃菜单按钮。
  @override
  Widget build(BuildContext context) => NativeGlassSettingRow(
    title: label,
    caption: caption,
    child: NativeGlassMenuButton<T>(
      value: value,
      items: items,
      onChanged: onChanged,
    ),
  );
}

/// 不带字段名称的玻璃菜单按钮；设置行与译文卡片标题区共用同一菜单材料与选项样式。
class NativeGlassMenuButton<T> extends StatefulWidget {
  /// value/items 是选中值和有序选项；onChanged 为空表示禁用；
  /// dense 为真时不设最小宽度、左右内边距 6pt，用于截图工具栏编辑器 72pt 宽的组头（#67）；
  /// flat 非空时触发器用该平面装饰代替独立玻璃材料，与周围平面格子同底（#67 原生克制风格）。
  const NativeGlassMenuButton({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.dense = false,
    this.flat,
  });
  final T value;
  final Map<T, String> items;
  final ValueChanged<T>? onChanged;
  final bool dense;
  final Decoration? flat;

  /// 无参数；创建触发器和当前菜单项的焦点状态。
  @override
  State<NativeGlassMenuButton<T>> createState() =>
      _NativeGlassMenuButtonState<T>();
}

/// 管理触发器与当前菜单选项焦点；选中值由调用方持有。
class _NativeGlassMenuButtonState<T> extends State<NativeGlassMenuButton<T>> {
  final _buttonFocus = FocusNode();
  final _selectedFocus = FocusNode();

  /// 无参数；释放窗口内持有的两个焦点节点。
  @override
  void dispose() {
    _buttonFocus.dispose();
    _selectedFocus.dispose();
    super.dispose();
  }

  /// context 提供主题；菜单共享一层材料，值超过一行时按18pt行高增长。
  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final items = widget.items;
    final onChanged = widget.onChanged;
    return MenuAnchor(
      childFocusNode: _buttonFocus,
      onOpen: () {
        // 菜单挂载后聚焦当前值，使鼠标和键盘打开都能直接用方向键选择。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _selectedFocus.context != null) {
            _selectedFocus.requestFocus();
          }
        });
      },
      style: NativeGlassMenuPanel.anchorStyle,
      menuChildren: [
        // NativeGlassMenuPanel/NativeGlassMenuItem提供与其他玻璃菜单一致的材料和选项样式。
        NativeGlassMenuPanel(
          children: [
            for (final option in items.entries)
              NativeGlassMenuItem(
                label: option.value,
                focusNode: option.key == value ? _selectedFocus : null,
                onPressed: onChanged == null
                    ? null
                    : () => onChanged(option.key),
              ),
          ],
        ),
      ],
      builder: (context, controller, _) => ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: widget.dense ? 0 : GlassMetrics.dropdownMinWidth,
          maxWidth: GlassMetrics.dropdownMaxWidth,
        ),
        child: _surface(
          TextButton(
            focusNode: _buttonFocus,
            onPressed: onChanged == null
                ? null
                : () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
            style: TextButton.styleFrom(
              padding: EdgeInsets.symmetric(
                horizontal: widget.dense ? 6 : 10,
                vertical: 5,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    items[value] ?? (items.isNotEmpty ? items.values.first : ''),
                    textAlign: TextAlign.left,
                    maxLines: widget.dense ? 1 : null,
                    overflow: widget.dense ? TextOverflow.ellipsis : null,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.unfold_more, size: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// trigger 为下拉触发按钮；flat 非空时返回带悬停、微缩与焦点反馈的平面按钮包装，否则返回独立玻璃材料包装。
  Widget _surface(Widget trigger) {
    final flat = widget.flat;
    if (flat == null) return NativeGlassSurface(material: true, child: trigger);
    return NativeGlassButtonFeedback(
      radius: GlassMetrics.controlRadius,
      enabled: widget.onChanged != null,
      child: DecoratedBox(decoration: flat, child: trigger),
    );
  }
}

/// 玻璃菜单的共享材料面板；下拉菜单按钮与截图「录制选项」共用，超出最大高度时内部滚动。
class NativeGlassMenuPanel extends StatelessWidget {
  /// children 为自上而下的菜单项或分隔线，maxHeight 为面板最大高度（默认 320pt）。
  const NativeGlassMenuPanel({
    super.key,
    required this.children,
    this.maxHeight = GlassMetrics.menuMaxHeight,
  });
  final List<Widget> children;
  final double maxHeight;

  /// MenuAnchor 自身不绘制材料、阴影与内边距，外观全部由面板提供。
  static const anchorStyle = MenuStyle(
    padding: WidgetStatePropertyAll(EdgeInsets.zero),
    backgroundColor: WidgetStatePropertyAll(Colors.transparent),
    elevation: WidgetStatePropertyAll(0),
  );

  /// context 未使用；返回一层玻璃材料包裹的可滚动纵向菜单，宽度与高度受规格边界约束。
  @override
  Widget build(BuildContext context) => NativeGlassSurface(
    material: true,
    radius: GlassMetrics.menuRadius,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: GlassMetrics.menuMinWidth,
        maxWidth: GlassMetrics.menuMaxWidth,
        maxHeight: maxHeight,
      ),
      child: SingleChildScrollView(
        primary: false,
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );
}

/// 玻璃菜单的单个选项；命中高 32pt、圆角与按压反馈与下拉选项一致。
class NativeGlassMenuItem extends StatelessWidget {
  /// label 为选项文字；onPressed 为空表示禁用；checked 非空时在文字前保留 16pt 勾选位，
  /// true 显示勾选；focusNode 用于打开菜单时聚焦当前项。
  const NativeGlassMenuItem({
    super.key,
    required this.label,
    required this.onPressed,
    this.checked,
    this.focusNode,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool? checked;
  final FocusNode? focusNode;

  /// context 未使用；返回带统一悬停、微缩与按压反馈的菜单按钮。
  @override
  Widget build(BuildContext context) => NativeGlassButtonFeedback(
    radius: GlassMetrics.menuItemRadius,
    enabled: onPressed != null,
    inset: const EdgeInsets.symmetric(vertical: 2),
    pressScale: 0.98,
    child: MenuItemButton(
      focusNode: focusNode,
      onPressed: onPressed,
      // 勾选位固定宽度，同组未勾选项的文字仍左对齐。
      leadingIcon: checked == null
          ? null
          : SizedBox.square(
              dimension: GlassMetrics.icon,
              child: checked!
                  ? const Icon(Icons.check, size: GlassMetrics.icon)
                  : null,
            ),
      style: ButtonStyle(
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        minimumSize: const WidgetStatePropertyAll(
          Size(0, GlassMetrics.hitSize),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        ),
        shape: WidgetStatePropertyAll(
          RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(GlassMetrics.menuItemRadius),
          ),
        ),
      ),
      child: Text(label),
    ),
  );
}

/// 常规设置行；文字与右侧控件不足时按Spec换行，不压缩字号。
class NativeGlassSettingRow extends StatelessWidget {
  /// title 为独立字段名称，child 为宽度最多240pt的控件，caption为可换行说明。
  const NativeGlassSettingRow({
    super.key,
    required this.title,
    required this.child,
    this.caption,
  });
  final String title;
  final String? caption;
  final Widget child;

  /// context 提供文字缩放；以可用宽度判断是否保持左右两列。
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final label = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title),
          if (caption != null)
            Text(caption!, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
      // 160pt文字列+16pt列间距+240pt控件列，低于该值时明确换行。
      return ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: caption == null
              ? GlassMetrics.rowHeight
              : GlassMetrics.captionRowHeight,
        ),
        child: constraints.maxWidth < 416
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [label, const SizedBox(height: 8), child],
              )
            : Row(
                children: [
                  Expanded(child: label),
                  const SizedBox(width: 16),
                  child,
                ],
              ),
      );
    },
  );
}

/// 授权状态标签（#67 第 14 条、#142）：带圆点的固定语义色胶囊，不随系统强调色变化。
class NativeGlassStatus extends StatelessWidget {
  /// granted 为真显示绿色「已授权」，为假显示橙色「未授权」；label 可覆写展示与语义文字。
  const NativeGlassStatus({super.key, required this.granted, this.label});

  final bool granted;
  final String? label;

  /// context 提供明暗外观；返回高 18、圆角 9、左右内边距 8 的语义状态标签。
  @override
  Widget build(BuildContext context) {
    final text = label ?? (granted ? '已授权' : '未授权');
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 固定语义色（#67 第 14 条、#144）：浅色取深绿/深橙与 12% 同色底，深色取亮绿/亮橙，满足 WCAG 2.2 AA 4.5:1。
    final foreground = granted
        ? (dark ? const Color(0xFF32D74B) : const Color(0xFF126326))
        : (dark ? const Color(0xFFFF9F0A) : const Color(0xFF8A4A00));
    final background = foreground.withValues(
      alpha: dark ? (granted ? 0.16 : 0.18) : 0.12,
    );
    return Semantics(
      container: true,
      label: text,
      child: Container(
        height: GlassMetrics.statusHeight,
        padding: const EdgeInsets.symmetric(
          horizontal: GlassMetrics.statusPaddingX,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(GlassMetrics.statusRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ExcludeSemantics(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: foreground,
                  shape: BoxShape.circle,
                ),
                child: const SizedBox.square(
                  dimension: GlassMetrics.statusDotSize,
                ),
              ),
            ),
            const SizedBox(width: GlassMetrics.statusDotGap),
            ExcludeSemantics(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: GlassMetrics.statusFont,
                  height: 1,
                  fontWeight: FontWeight.w500,
                  color: foreground,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 同组设置共享阅读背景；材料不逐行重复折射，行间自动插入 0.5pt 细线（#67 第 14 条）。
class NativeGlassGroup extends StatelessWidget {
  /// children 为按顺序排列的设置行；高度由实际行高、32pt内边距及行间 0.5pt 细线决定。
  const NativeGlassGroup({super.key, required this.children});
  final List<Widget> children;

  /// context 提供语义底色与明暗外观；返回16pt连续圆角、n 行间含 n−1 条细线的分组。
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final dividerColor = (dark ? Colors.white : Colors.black).withValues(
      alpha: 0.10,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: GlassMetrics.groupGap),
      // 分组本身承载Material，组内ListTile的焦点与悬停层才绘制在背景之上。
      child: Material(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.035),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.panelRadius),
        ),
        child: Padding(
          padding: const EdgeInsets.all(GlassMetrics.panelPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: GlassMetrics.groupDividerThickness,
                    thickness: GlassMetrics.groupDividerThickness,
                    color: dividerColor,
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

/// 外观与导航共用平整分段；共享强调色选中底由 Bouncy 物理弹簧驱动位置与宽度，减少动态效果时直接切换（#142）。
class NativeGlassSegments<T> extends StatefulWidget {
  /// value/options/onChanged 为选中状态；navigation决定72×32导航或76×28外观分段。
  const NativeGlassSegments({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.icons = const {},
    this.navigation = false,
  });
  final T value;
  final Map<T, String> options;
  final Map<T, IconData> icons;
  final ValueChanged<T> onChanged;
  final bool navigation;

  /// 无参数；创建跟踪分段测量坐标的滑块状态。
  @override
  State<NativeGlassSegments<T>> createState() => _NativeGlassSegmentsState<T>();
}

class _NativeGlassSegmentsState<T> extends State<NativeGlassSegments<T>> {
  final _stackKey = GlobalKey();
  late List<GlobalKey> _itemKeys = _makeKeys(widget.options.length);
  List<({double left, double width})>? _rects;
  bool _measureScheduled = false;

  /// count 为分段数；返回每段对应的全局键，用于测量真实横坐标与宽度。
  static List<GlobalKey> _makeKeys(int count) =>
      List.generate(count, (_) => GlobalKey());

  /// 无参数；初始化各段测量回调。
  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  /// 无参数；字体或文本缩放变化时重新测量各段位置与宽度。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleMeasure();
  }

  /// oldWidget 为旧配置；分段数目、文案、图标或模式变更时重新测量。
  @override
  void didUpdateWidget(covariant NativeGlassSegments<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.options.length != oldWidget.options.length) {
      _itemKeys = _makeKeys(widget.options.length);
      _rects = null;
      _scheduleMeasure();
      return;
    }
    if (widget.navigation != oldWidget.navigation ||
        !_sameOptions(oldWidget.options, widget.options) ||
        !_sameIcons(oldWidget.icons, widget.icons)) {
      _scheduleMeasure();
    }
  }

  /// a/b 为分段映射；返回键值顺序是否完全一致。
  static bool _sameOptions<K>(Map<K, String> a, Map<K, String> b) {
    if (a.length != b.length) return false;
    final itA = a.entries.iterator;
    final itB = b.entries.iterator;
    while (itA.moveNext() && itB.moveNext()) {
      if (itA.current.key != itB.current.key ||
          itA.current.value != itB.current.value) {
        return false;
      }
    }
    return true;
  }

  /// a/b 为分段图标映射；返回是否完全一致。
  static bool _sameIcons<K>(Map<K, IconData> a, Map<K, IconData> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// 无参数；合并多次重建请求，在帧末统一测量各段真实矩形。
  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      _measure();
    });
  }

  /// 无参数；将各段相对 Stack 的起点与宽度写入状态，供滑块对齐。
  void _measure() {
    if (!mounted) return;
    final stackBox = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null || !stackBox.hasSize) return;
    final measured = <({double left, double width})>[];
    for (final key in _itemKeys) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final topLeft = stackBox.globalToLocal(box.localToGlobal(Offset.zero));
      measured.add((left: topLeft.dx, width: box.size.width));
    }
    final existing = _rects;
    if (existing != null && existing.length == measured.length) {
      var identical = true;
      for (var i = 0; i < measured.length; i++) {
        if ((existing[i].left - measured[i].left).abs() > 0.01 ||
            (existing[i].width - measured[i].width).abs() > 0.01) {
          identical = false;
          break;
        }
      }
      if (identical) return;
    }
    setState(() => _rects = measured);
  }

  /// dx 为命中点横坐标，defaultWidth 为未测量前的固定段宽；返回对应的分段键。
  T _hitOption(double dx, double defaultWidth) {
    final rects = _rects;
    if (rects != null && rects.length == widget.options.length) {
      for (var i = 0; i < rects.length; i++) {
        final rect = rects[i];
        if (dx >= rect.left && dx <= rect.left + rect.width) {
          return widget.options.keys.elementAt(i);
        }
      }
    }
    final index = (dx / defaultWidth).floor().clamp(
      0,
      widget.options.length - 1,
    );
    return widget.options.keys.elementAt(index);
  }

  /// context 提供主题与文字缩放；可见高度固定基线，点击区域至少32pt。
  @override
  Widget build(BuildContext context) {
    final width = widget.navigation
        ? GlassMetrics.navigationWidth
        : GlassMetrics.appearanceSegmentWidth;
    final height = widget.navigation
        ? GlassMetrics.hitSize
        : GlassMetrics.buttonHeight;
    final radius = widget.navigation
        ? GlassMetrics.primaryRadius
        : GlassMetrics.controlRadius;
    final colors = Theme.of(context).colorScheme;
    final reduced = AppMotion.reduced(context);
    final keys = widget.options.keys.toList();
    final selectedIndex = keys.indexOf(widget.value);
    final rects = _rects;
    final target = selectedIndex < 0
        ? null
        : (rects != null && selectedIndex < rects.length
              ? rects[selectedIndex]
              : (left: width * selectedIndex, width: width));

    Widget indicator(double left, double segmentWidth) => Positioned(
      left: left,
      top: 0,
      width: segmentWidth,
      height: height,
      child: IgnorePointer(
        child: DecoratedBox(
          key: const ValueKey('native-glass-segments-indicator'),
          decoration: ShapeDecoration(
            color: NativeGlassTheme.accentFillOf(context),
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(radius),
            ),
          ),
        ),
      ),
    );
    final onAccent = NativeGlassTheme.onAccentOf(context);

    return GestureDetector(
      excludeFromSemantics: true,
      behavior: HitTestBehavior.opaque,
      onTapUp: (event) =>
          widget.onChanged(_hitOption(event.localPosition.dx, width)),
      child: SizedBox(
        height: GlassMetrics.hitSize,
        child: Center(
          widthFactor: 1,
          child: ClipRSuperellipse(
            borderRadius: BorderRadius.circular(radius),
            child: ColoredBox(
              color: colors.onSurface.withValues(alpha: 0.10),
              child: SizedBox(
                height: height,
                child: Stack(
                  key: _stackKey,
                  children: [
                    if (target != null && reduced)
                      indicator(target.left, target.width)
                    else if (target != null)
                      SingleMotionBuilder(
                        value: target.left,
                        motion: AppMotion.bouncy(context),
                        builder: (context, animatedLeft, _) =>
                            SingleMotionBuilder(
                              value: target.width,
                              motion: AppMotion.bouncy(context),
                              builder: (context, animatedWidth, _) =>
                                  indicator(animatedLeft, animatedWidth),
                            ),
                      ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final (index, option)
                            in widget.options.entries.indexed)
                          ConstrainedBox(
                            key: _itemKeys[index],
                            constraints: BoxConstraints(
                              minWidth: width,
                              minHeight: height,
                              maxHeight: height,
                            ),
                            child: Semantics(
                              selected: widget.value == option.key,
                              inMutuallyExclusiveGroup: true,
                              child: NativeGlassButtonFeedback(
                                radius: radius,
                                enabled: true,
                                hoverFeedback: true,
                                child: TextButton(
                                  onPressed: () => widget.onChanged(option.key),
                                  style: TextButton.styleFrom(
                                    // 局部foregroundColor会生成Ink悬停层，反馈仅由外层统一玻璃反馈负责。
                                    overlayColor: Colors.transparent,
                                    // 保证每段至少为规范基线尺寸，较长文字自然横向伸展。
                                    minimumSize: Size(width, height),
                                    maximumSize: Size(double.infinity, height),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                    foregroundColor: widget.value == option.key
                                        ? onAccent
                                        : colors.onSurface,
                                    backgroundColor: Colors.transparent,
                                    shape: RoundedSuperellipseBorder(
                                      borderRadius: BorderRadius.circular(
                                        radius,
                                      ),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      if (widget.icons[option.key] != null) ...[
                                        Icon(
                                          widget.icons[option.key],
                                          size: GlassMetrics.icon,
                                        ),
                                        const SizedBox(
                                          width: GlassMetrics.iconGap,
                                        ),
                                      ],
                                      Text(option.value),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    // 仅相邻未选项之间保留1pt分隔，选中块边缘不叠线。
                    for (var index = 1; index < keys.length; index++)
                      if (keys[index - 1] != widget.value &&
                          keys[index] != widget.value)
                        Positioned(
                          left:
                              (rects != null && index < rects.length
                                  ? rects[index].left
                                  : width * index) -
                              0.5,
                          top: 7,
                          bottom: 7,
                          width: 1,
                          child: IgnorePointer(
                            child: ColoredBox(
                              color: colors.onSurface.withValues(alpha: 0.35),
                            ),
                          ),
                        ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 侧边栏一级分组：title/icon 为分组标题与图标；value 非空时分组本身可选中（无子页），
/// 否则 children 为按顺序排列的子页值与名称，分组只作标签。
typedef NativeGlassSidebarSection<T> = ({
  String title,
  IconData icon,
  T? value,
  Map<T, String> children,
});

/// 设置窗口左侧两级导航（#67）：玻璃材料、固定宽度，不随正文滚动；一级分组始终展开。
class NativeGlassSidebar<T> extends StatelessWidget {
  /// value 为当前子页，sections 为一级分组，onChanged 接收被点选的子页。
  const NativeGlassSidebar({
    super.key,
    required this.value,
    required this.sections,
    required this.onChanged,
  });
  final T value;
  final List<NativeGlassSidebarSection<T>> sections;
  final ValueChanged<T> onChanged;

  /// 无参数；计算当前选中项在列表内容坐标系中的纵向起点与高度，未命中时返回 null。
  ({double top, double height})? _selectedGeometry() {
    var top = 0.0;
    for (final section in sections) {
      if (section.value != null && section.value == value) {
        return (top: top, height: GlassMetrics.sidebarSectionHeight);
      }
      top += GlassMetrics.sidebarSectionHeight;
      for (final child in section.children.keys) {
        if (child == value) {
          return (top: top, height: GlassMetrics.sidebarItemHeight);
        }
        top += GlassMetrics.sidebarItemHeight;
      }
    }
    return null;
  }

  /// context 提供主题；返回固定宽度的导航列，选中滑块由 Bouncy 物理弹簧驱动（#142）。
  @override
  Widget build(BuildContext context) {
    final selection = _selectedGeometry();
    final reduced = AppMotion.reduced(context);
    final rows = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final section in sections) ...[
          // 一级行：可选中的分组直接是子页，其余只作标签。
          _row(
            context,
            height: GlassMetrics.sidebarSectionHeight,
            indent: 0,
            icon: section.icon,
            label: section.title,
            bold: true,
            target: section.value,
          ),
          for (final child in section.children.entries)
            _row(
              context,
              height: GlassMetrics.sidebarItemHeight,
              indent: GlassMetrics.sidebarItemIndent,
              label: child.value,
              target: child.key,
            ),
        ],
      ],
    );
    Widget indicator(double top, double height) => Positioned(
      left: GlassMetrics.sidebarSelectionInset,
      right: GlassMetrics.sidebarSelectionInset,
      top: top,
      height: height,
      child: IgnorePointer(
        child: DecoratedBox(
          key: const ValueKey('native-glass-sidebar-indicator'),
          decoration: ShapeDecoration(
            color: NativeGlassTheme.accentFillOf(context),
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
            ),
          ),
        ),
      ),
    );
    return NativeGlassSurface(
      material: true,
      radius: 0,
      child: SizedBox(
        width: GlassMetrics.sidebarWidth,
        height: double.infinity,
        child: ListView(
          padding: const EdgeInsets.symmetric(
            vertical: GlassMetrics.sidebarPadding,
          ),
          children: [
            Stack(
              children: [
                if (selection != null && reduced)
                  indicator(selection.top, selection.height)
                else if (selection != null)
                  SingleMotionBuilder(
                    value: selection.top,
                    motion: AppMotion.bouncy(context),
                    builder: (context, animatedTop, _) => SingleMotionBuilder(
                      value: selection.height,
                      motion: AppMotion.bouncy(context),
                      builder: (context, animatedHeight, _) =>
                          indicator(animatedTop, animatedHeight),
                    ),
                  ),
                rows,
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// height/indent 为行高与左缩进，icon/label/bold 为行内容，target 为点选后切换到的子页；
  /// target 为空时返回不可点选的标签行，否则返回透明背景按钮行（由底层弹簧滑块呈现选中底）。
  Widget _row(
    BuildContext context, {
    required double height,
    required double indent,
    required String label,
    IconData? icon,
    bool bold = false,
    T? target,
  }) {
    final colors = Theme.of(context).colorScheme;
    final onAccent = NativeGlassTheme.onAccentOf(context);
    final selected = target != null && target == value;
    // 一级分组图标放在 22×22 圆角 6 强调色方块内（自身选中时叠加半透前景色以保持对比），配自适应高对比 12pt 图标（#67 第 14 条、#144）。
    final content = Row(
      children: [
        if (icon != null) ...[
          DecoratedBox(
            decoration: ShapeDecoration(
              color: selected
                  ? onAccent.withValues(alpha: 0.22)
                  : NativeGlassTheme.accentFillOf(context),
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(
                  GlassMetrics.sidebarIconRadius,
                ),
              ),
            ),
            child: SizedBox.square(
              dimension: GlassMetrics.sidebarIconBox,
              child: Icon(
                icon,
                size: GlassMetrics.sidebarIconSize,
                color: onAccent,
              ),
            ),
          ),
          const SizedBox(width: GlassMetrics.iconGap),
        ],
        Expanded(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: bold ? const TextStyle(fontWeight: FontWeight.w600) : null,
          ),
        ),
      ],
    );
    final Widget row;
    if (target == null) {
      row = SizedBox(
        height: height,
        child: Padding(
          padding: EdgeInsets.only(left: indent + GlassMetrics.iconGap),
          child: content,
        ),
      );
    } else {
      row = Semantics(
        selected: selected,
        child: NativeGlassButtonFeedback(
          radius: GlassMetrics.controlRadius,
          enabled: true,
          hoverFeedback: true,
          pressScale: 0.98,
          child: TextButton(
            onPressed: () => onChanged(target),
            style: TextButton.styleFrom(
              overlayColor: Colors.transparent,
              minimumSize: Size.fromHeight(height),
              fixedSize: Size.fromHeight(height),
              padding: EdgeInsets.only(left: indent + GlassMetrics.iconGap),
              alignment: Alignment.centerLeft,
              foregroundColor: selected ? onAccent : colors.onSurface,
              backgroundColor: Colors.transparent,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
              ),
            ),
            child: content,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: GlassMetrics.sidebarSelectionInset,
      ),
      child: row,
    );
  }
}

/// 固定36×20轨道和16×16滑块；系统Switch没有这些几何尺寸的公开配置。
class NativeGlassSwitch extends StatefulWidget {
  /// value 为当前开关值，onChanged为空时禁用；label提供可访问名称，busy为真时外圈显示等待进度环。
  const NativeGlassSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    required this.label,
    this.busy = false,
  });
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String label;
  final bool busy;

  /// 无参数；创建键盘焦点状态，业务值由调用方持有。
  @override
  State<NativeGlassSwitch> createState() => _NativeGlassSwitchState();
}

/// 维护开关键盘焦点、悬停与按下微缩反馈；将用户动作映射为值反转，不保存业务偏好。
class _NativeGlassSwitchState extends State<NativeGlassSwitch> {
  bool _focused = false;
  bool _hovered = false;
  bool _pressed = false;

  /// 无参数；仅在启用时向业务层发布反转后的值。
  void _toggle() => widget.onChanged?.call(!widget.value);

  /// context 提供主题与减少动态效果；返回带键盘、悬停微光、按压微缩、语义和 32pt 命中高度的开关。
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = widget.onChanged != null;
    final accent = NativeGlassTheme.accentOf(context);
    final accentFill = NativeGlassTheme.accentFillOf(context);
    final reduced = AppMotion.reduced(context);
    final duration = reduced ? Duration.zero : GlassMetrics.transition;
    final Border? border;
    if (_focused && enabled) {
      border = Border.all(color: accent, width: GlassMetrics.focusRingWidth);
    } else if (_hovered && enabled) {
      border = Border.all(
        color: colors.onSurface.withValues(alpha: 0.28),
        width: 1,
      );
    } else {
      border = null;
    }
    return Semantics(
      label: widget.label,
      toggled: widget.value,
      enabled: enabled,
      onTap: enabled ? _toggle : null,
      child: FocusableActionDetector(
        // 仅开关36×32命中区显示可点击手形；标题区域保持默认指针。
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        enabled: enabled,
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _toggle();
              return null;
            },
          ),
        },
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() {
            _hovered = false;
            _pressed = false;
          }),
          child: Listener(
            onPointerDown: (_) {
              if (enabled) setState(() => _pressed = true);
            },
            onPointerUp: (_) => setState(() => _pressed = false),
            onPointerCancel: (_) => setState(() => _pressed = false),
            child: GestureDetector(
              excludeFromSemantics: true,
              behavior: HitTestBehavior.opaque,
              onTap: enabled ? _toggle : null,
              child: SizedBox(
                width: GlassMetrics.switchWidth,
                height: GlassMetrics.hitSize,
                child: Center(
                  child: AnimatedScale(
                    scale: _pressed && enabled && !reduced ? 0.95 : 1.0,
                    duration: duration,
                    curve: Curves.easeOutCubic,
                    child: Opacity(
                      opacity: enabled ? 1 : 0.38,
                      child: NativeGlassSurface(
                        material: true,
                        radius: GlassMetrics.switchHeight / 2,
                        busy: widget.busy,
                        child: AnimatedContainer(
                          duration: duration,
                          width: GlassMetrics.switchWidth,
                          height: GlassMetrics.switchHeight,
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: widget.value
                                ? accentFill
                                : colors.outlineVariant,
                            borderRadius: BorderRadius.circular(
                              GlassMetrics.switchHeight / 2,
                            ),
                          ),
                          foregroundDecoration: border == null
                              ? null
                              : BoxDecoration(
                                  borderRadius: BorderRadius.circular(
                                    GlassMetrics.switchHeight / 2,
                                  ),
                                  border: border,
                                ),
                          child: AnimatedAlign(
                            alignment: widget.value
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            duration: duration,
                            child: SizedBox.square(
                              dimension: GlassMetrics.switchThumb,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.black.withValues(alpha: 0.12),
                                    width: 0.5,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
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

/// 服务配置等模态表单的玻璃容器；内容不重复折射，长表单由内容自身滚动。
class NativeGlassDialog extends StatelessWidget {
  /// title/content/actions 为标题、表单及操作列表，maxWidth 为最大宽度（点，默认表单宽度 568）；创建保持键盘和弹窗语义的对话框。
  const NativeGlassDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.maxWidth = 568,
  });
  final Widget title;
  final Widget content;
  final List<Widget> actions;
  final double maxWidth;

  /// 弹出统一规范的二次确认玻璃弹窗；title 为确认标题，message 为不可逆影响说明，
  /// confirmLabel/cancelLabel 为主次按钮文案，destructive 为真时主按钮使用错误语义实底；返回用户是否确认。
  static Future<bool> confirm({
    required BuildContext context,
    required String title,
    required String message,
    String confirmLabel = '确认',
    String cancelLabel = '取消',
    bool destructive = false,
  }) async {
    final colors = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => NativeGlassDialog(
        maxWidth: 420,
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(cancelLabel),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: colors.error,
                    foregroundColor: colors.onError,
                  )
                : null,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// context 提供主题；返回宽度受限、可容纳长表单的独立玻璃弹窗。
  @override
  Widget build(BuildContext context) => Dialog(
    // 弹窗使用95%阅读底色，避免底层设置文字透过表单干扰阅读。
    backgroundColor: Theme.of(context).dialogTheme.backgroundColor,
    insetPadding: const EdgeInsets.all(GlassMetrics.space24),
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Padding(
        padding: const EdgeInsets.all(GlassMetrics.space24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DefaultTextStyle(
              style: Theme.of(context).textTheme.headlineSmall!,
              child: title,
            ),
            const SizedBox(height: GlassMetrics.space20),
            // 弹窗表单内隐藏系统自动挂载的滚动条，避免与右侧按钮（如「恢复默认」）及输入边框重叠，仍保留正常滚动。
            Flexible(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(
                  context,
                ).copyWith(scrollbars: false),
                child: content,
              ),
            ),
            const SizedBox(height: GlassMetrics.space20),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: GlassMetrics.space8,
              overflowSpacing: GlassMetrics.space8,
              children: actions,
            ),
          ],
        ),
      ),
    ),
  );
}

/// 页内统一语义提示横幅（#144）；集中呈现错误或提醒文案及可选重试操作。
class NativeGlassBanner extends StatelessWidget {
  /// message 为明确提示内容，isError 为真时使用错误语义色与图标，否则使用主题提示色与图标，action 为右侧可选内联操作。
  const NativeGlassBanner({
    super.key,
    required this.message,
    this.isError = true,
    this.action,
  });

  final String message;
  final bool isError;
  final Widget? action;

  /// context 提供明暗外观与强调色；返回具备 ≥ 4.5:1 前景对比度的语义横幅。
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = NativeGlassTheme.accentOf(context);
    final foreground = isError
        ? (dark ? const Color(0xFFFF6961) : const Color(0xFFB3261E))
        : (dark ? const Color(0xFFCCCCCC) : const Color(0xFF1C1C1E));
    final tint = isError ? foreground : accent;
    return Semantics(
      liveRegion: isError,
      container: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: GlassMetrics.space12,
          vertical: GlassMetrics.space8,
        ),
        decoration: BoxDecoration(
          color: tint.withValues(alpha: dark ? 0.16 : 0.10),
          borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
          border: Border.all(
            color: tint.withValues(alpha: dark ? 0.40 : 0.28),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.info_outline,
              size: GlassMetrics.icon,
              color: foreground,
            ),
            const SizedBox(width: GlassMetrics.space8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: foreground),
              ),
            ),
            if (action != null) ...[
              const SizedBox(width: GlassMetrics.space8),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Material默认将激活轨道增高2pt；统一轨道厚度使两侧均符合6pt规格。
class _UniformSliderTrack extends RoundedRectSliderTrackShape {
  const _UniformSliderTrack();

  /// 参数为Slider布局、状态和位置；仅取消激活轨道额外厚度，保留原生绘制/命中。
  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
    double additionalActiveTrackHeight = 0,
  }) => super.paint(
    context,
    offset,
    parentBox: parentBox,
    sliderTheme: sliderTheme,
    enableAnimation: enableAnimation,
    thumbCenter: thumbCenter,
    secondaryOffset: secondaryOffset,
    isEnabled: isEnabled,
    isDiscrete: isDiscrete,
    textDirection: textDirection,
    additionalActiveTrackHeight: 0,
  );
}

/// 强调色滑点：绘制白色圆点、轻投影与系统强调色描边，使滑点与轨道一体响应系统强调色（#67、#144）。
class _AccentSliderThumbShape extends SliderComponentShape {
  /// borderColor 为描边强调色，固定采用 GlassMetrics.sliderThumbRadius（8pt）。
  const _AccentSliderThumbShape({required this.borderColor});

  final Color borderColor;

  /// isEnabled/isDiscrete 为控件可用与分段标记；返回固定 16×16 布局占用尺寸。
  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.fromRadius(GlassMetrics.sliderThumbRadius);

  /// center 为滑点中心；依次绘制柔阴影、不透明白芯与 1.5pt 系统强调色外圈，禁用时淡出边框。
  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    const radius = GlassMetrics.sliderThumbRadius;
    final enabledAlpha = enableAnimation.value.clamp(0.35, 1.0);
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.14 * enabledAlpha)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    canvas.drawCircle(center.translate(0, 1), radius, shadowPaint);
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = sliderTheme.thumbColor ?? Colors.white,
    );
    const stroke = GlassMetrics.sliderThumbBorderWidth;
    canvas.drawCircle(
      center,
      radius - stroke / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = borderColor.withValues(alpha: enabledAlpha),
    );
  }
}

/// 五类窗口共用的语义主题；材料保持系统原生，内容区域以普通颜色保证可读性。
abstract final class NativeGlassTheme {
  /// a/b 为任意不透明色彩；按 WCAG 2.2 sRGB 相对亮度返回 1.0–21.0 对比度比值。
  static double contrastRatio(Color a, Color b) {
    final l1 = a.computeLuminance();
    final l2 = b.computeLuminance();
    return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
  }

  /// accent 为系统强调色；返回满足 WCAG 2.2 AA（>= 4.5:1）的实底填充与自适应前景字色（#67、#144）。
  static ({Color fill, Color foreground}) accentColorsFor(Color accent) {
    if (contrastRatio(Colors.white, accent) >= 4.5) {
      return (fill: accent, foreground: Colors.white);
    }
    const darkInk = Color(0xFF1C1C1E);
    // 仅浅亮强调色（如亮黄/绿/橙）保留原色配深字；中深蓝与品红适度向黑压暗以维持高雅白字。
    if (accent.computeLuminance() >= 0.27 &&
        contrastRatio(darkInk, accent) >= 4.5) {
      return (fill: accent, foreground: darkInk);
    }
    var low = 0.0;
    var high = 1.0;
    var best = Colors.black;
    for (var i = 0; i < 16; i++) {
      final mid = (low + high) / 2;
      final candidate = Color.lerp(accent, Colors.black, mid)!;
      if (contrastRatio(Colors.white, candidate) >= 4.55) {
        best = candidate;
        high = mid;
      } else {
        low = mid;
      }
    }
    return (fill: best, foreground: Colors.white);
  }

  /// context 为主题内的位置；返回当前明暗外观下的原始系统强调色（用于选区框、滑块、焦点框与进度环，#142）。
  static Color accentOf(BuildContext context) =>
      Theme.of(context).extension<GlassAccent>()?.color ??
      Theme.of(context).colorScheme.primary;

  /// context 为主题内的位置；返回用于选中实底按钮、滑块指示条与开态轨道的 ≥4.5:1 对比实底色。
  static Color accentFillOf(BuildContext context) =>
      Theme.of(context).extension<GlassAccent>()?.fill ??
      accentColorsFor(accentOf(context)).fill;

  /// context 为主题内的位置；返回与 accentFillOf 配对的高对比前景文字或图标色。
  static Color onAccentOf(BuildContext context) =>
      Theme.of(context).extension<GlassAccent>()?.onAccent ??
      accentColorsFor(accentOf(context)).foreground;

  /// base 为基础按钮样式，hoverOverlay/pressedOverlay 指定叠加色，focusedSide/restingSide 定义聚焦与常规描边。
  static ButtonStyle _withButtonStates(
    ButtonStyle base, {
    required Color overlayBase,
    required double hoverAlpha,
    required double pressedAlpha,
    required BorderSide focusedSide,
    BorderSide restingSide = BorderSide.none,
  }) => base.copyWith(
    overlayColor: WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.disabled)) return Colors.transparent;
      if (states.contains(WidgetState.pressed)) {
        return overlayBase.withValues(alpha: pressedAlpha);
      }
      if (states.contains(WidgetState.hovered)) {
        return overlayBase.withValues(alpha: hoverAlpha);
      }
      return Colors.transparent;
    }),
    side: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.focused) ? focusedSide : restingSide,
    ),
  );

  /// brightness 为当前明暗模式，appearance 为视觉快照（取对应外观的系统强调色，默认系统蓝）；
  /// 返回统一控件、输入框、卡片与弹窗的 Material 主题，accent 与 primary 只在这里定义（#67、#144）。
  static ThemeData data(
    Brightness brightness, [
    GlassAppearance appearance = const GlassAppearance(),
  ]) {
    final dark = brightness == Brightness.dark;
    final accent = dark ? appearance.accentDark : appearance.accentLight;
    final accentPair = accentColorsFor(accent);
    final colors =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
        ).copyWith(
          surface: dark ? const Color(0xFF171717) : const Color(0xFFF7F7F7),
          onSurface: dark ? Colors.white : Colors.black,
          onSurfaceVariant: dark
              ? const Color(0xFFCCCCCC)
              : const Color(0xFF454545),
          outline: dark ? const Color(0xFF929292) : const Color(0xFF696969),
          outlineVariant: dark
              ? const Color(0xFF76767A)
              : const Color(0xFF848489),
          // 文字与图标强调需要比实底更高的对比度：浅色向黑、深色向白混合（系统蓝时约 #005BC5 / #64ACFF）。
          primary: dark
              ? Color.lerp(accent, Colors.white, 0.35)
              : Color.lerp(accent, Colors.black, 0.25),
          onPrimary: dark ? Colors.black : Colors.white,
        );
    final controlShape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
    );
    final text = TextStyle(
      fontSize: GlassMetrics.bodyFont,
      height: GlassMetrics.bodyLine / GlassMetrics.bodyFont,
      color: colors.onSurface,
    );
    final typography = Typography.material2021(platform: TargetPlatform.macOS);
    final baseText = dark ? typography.white : typography.black;
    final content = dark ? const Color(0xF2232323) : const Color(0xF2FFFFFF);
    final focusSide = BorderSide(
      color: accent,
      width: GlassMetrics.focusRingWidth,
    );
    return ThemeData(
      useMaterial3: true,
      platform: TargetPlatform.macOS,
      typography: typography,
      textTheme: baseText.copyWith(
        bodyLarge: text,
        bodyMedium: text,
        labelLarge: text.copyWith(
          fontSize: GlassMetrics.captionFont,
          height: GlassMetrics.captionLine / GlassMetrics.captionFont,
          fontWeight: FontWeight.w500,
        ),
        titleMedium: text.copyWith(
          fontSize: 15,
          height: 22 / 15,
          fontWeight: FontWeight.w600,
        ),
        bodySmall: text.copyWith(
          fontSize: GlassMetrics.captionFont,
          height: GlassMetrics.captionLine / GlassMetrics.captionFont,
          color: colors.onSurfaceVariant,
        ),
        titleSmall: text.copyWith(
          fontSize: 14,
          height: 20 / 14,
          fontWeight: FontWeight.w600,
        ),
        headlineSmall: text.copyWith(
          fontSize: 20,
          height: 26 / 20,
          fontWeight: FontWeight.w700,
        ),
      ),
      iconTheme: IconThemeData(
        size: GlassMetrics.icon,
        color: colors.onSurface,
      ),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      splashFactory: NoSplash.splashFactory,
      colorScheme: colors,
      extensions: [GlassAccent(accent)],
      brightness: brightness,
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: colors.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: content,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.panelRadius),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: content,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.panelRadius),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: _withButtonStates(
          FilledButton.styleFrom(
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(GlassMetrics.primaryRadius),
            ),
            minimumSize: const Size(
              GlassMetrics.primaryMinWidth,
              GlassMetrics.primaryHeight,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            textStyle: text.copyWith(fontWeight: FontWeight.w500),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            animationDuration: GlassMetrics.transition,
            foregroundColor: accentPair.foreground,
            backgroundColor: accentPair.fill,
            disabledBackgroundColor: colors.onSurface.withValues(alpha: 0.12),
            disabledForegroundColor: colors.onSurface.withValues(alpha: 0.38),
            shadowColor: Colors.transparent,
            elevation: 0,
          ),
          overlayBase: accentPair.foreground,
          hoverAlpha: 0.08,
          pressedAlpha: 0.16,
          focusedSide: BorderSide(
            color: colors.onSurface,
            width: GlassMetrics.focusRingWidth,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: _withButtonStates(
          OutlinedButton.styleFrom(
            shape: controlShape,
            minimumSize: const Size(
              GlassMetrics.buttonMinWidth,
              GlassMetrics.buttonHeight,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            textStyle: text,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            animationDuration: GlassMetrics.transition,
            foregroundColor: colors.onSurface,
            backgroundColor: Colors.transparent,
          ),
          overlayBase: colors.onSurface,
          hoverAlpha: GlassMetrics.hoverOpacity,
          pressedAlpha: GlassMetrics.pressedOpacity,
          focusedSide: focusSide,
          restingSide: BorderSide(color: colors.outlineVariant),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: _withButtonStates(
          TextButton.styleFrom(
            foregroundColor: colors.onSurface,
            minimumSize: const Size(
              GlassMetrics.buttonMinWidth,
              GlassMetrics.buttonHeight,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            textStyle: text,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            animationDuration: GlassMetrics.transition,
            shape: controlShape,
          ),
          overlayBase: colors.onSurface,
          hoverAlpha: GlassMetrics.hoverOpacity,
          pressedAlpha: GlassMetrics.pressedOpacity,
          focusedSide: focusSide,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: _withButtonStates(
          IconButton.styleFrom(
            minimumSize: const Size.square(GlassMetrics.hitSize),
            maximumSize: const Size.square(GlassMetrics.hitSize),
            iconSize: GlassMetrics.icon,
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            animationDuration: GlassMetrics.transition,
            shape: controlShape,
            foregroundColor: colors.onSurface,
            backgroundColor: Colors.transparent,
          ),
          overlayBase: colors.onSurface,
          hoverAlpha: GlassMetrics.hoverOpacity,
          pressedAlpha: GlassMetrics.pressedOpacity,
          focusedSide: focusSide,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(controlShape),
          foregroundColor: WidgetStatePropertyAll(colors.onSurface),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? colors.primary.withValues(alpha: 0.18)
                : Colors.transparent,
          ),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: content,
        surfaceTintColor: Colors.transparent,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(backgroundColor: WidgetStatePropertyAll(content)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStatePropertyAll(colors.onSurface),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accentPair.fill
              : colors.outlineVariant,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: colors.onSurface.withValues(
          alpha: dark ? 0.24 : 0.18,
        ),
        thumbColor: Colors.white,
        overlayColor: accent.withValues(alpha: 0.24),
        trackHeight: GlassMetrics.sliderTrack,
        trackShape: const _UniformSliderTrack(),
        thumbShape: _AccentSliderThumbShape(borderColor: accent),
        overlayShape: const RoundSliderOverlayShape(
          overlayRadius: GlassMetrics.sliderOverlayRadius,
        ),
        tickMarkShape: SliderTickMarkShape.noTickMark,
        showValueIndicator: ShowValueIndicator.never,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? accentPair.fill
              : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(accentPair.foreground),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => (states.contains(WidgetState.focused) ||
                  states.contains(WidgetState.hovered))
              ? accent.withValues(alpha: 0.18)
              : Colors.transparent,
        ),
        side: WidgetStateBorderSide.resolveWith((states) {
          if (states.contains(WidgetState.focused)) return focusSide;
          if (states.contains(WidgetState.selected)) {
            return BorderSide(color: accentPair.fill, width: 1.5);
          }
          return BorderSide(color: colors.outlineVariant, width: 1.5);
        }),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: accent,
        selectionColor: accent.withValues(alpha: 0.28),
        selectionHandleColor: accent,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.transparent,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
          borderSide: BorderSide(color: accent, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
          borderSide: BorderSide(color: colors.error),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colors.inverseSurface,
          borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
        ),
        textStyle: TextStyle(color: colors.onInverseSurface),
      ),
    );
  }
}

/// 每个引擎仅持有视觉快照，业务设置仍归主引擎；改变主题不会替换表单或截图状态。
class GlassAppearance {
  /// mode 为 system/light/dark；opacity 为材料不透明度0.2–1，前景始终不透明；
  /// accentLight/accentDark 为浅、深外观下的系统强调色，原生快照到达前为系统蓝（#142）。
  const GlassAppearance({
    this.mode = AppearanceModes.system,
    this.opacity = 0.8,
    this.accentLight = const Color(0xFF007AFF),
    this.accentDark = const Color(0xFF0A84FF),
  });
  final String mode;
  final double opacity;
  final Color accentLight;
  final Color accentDark;
  static final current = ValueNotifier(const GlassAppearance());
  static const channel = MethodChannel(ChannelNames.appearance);

  /// map 为原生视觉快照（偏好与系统强调色）；校验边界后返回不可变配置，缺少强调色时抛出 FormatException。
  factory GlassAppearance.fromMap(Map<Object?, Object?> map) {
    final mode =
        map[PreferenceKeys.glassAppearance] as String? ??
        AppearanceModes.system;
    final opacity =
        (map[PreferenceKeys.glassOpacity] as num?)?.toDouble() ?? 0.8;
    if (!AppearanceModes.values.contains(mode) ||
        !opacity.isFinite ||
        opacity < 0.2 ||
        opacity > 1) {
      throw const FormatException('外观模式或玻璃透明度无效。');
    }
    final accentLight = map[AppearanceKeys.accentLight];
    final accentDark = map[AppearanceKeys.accentDark];
    if (accentLight is! int || accentDark is! int) {
      throw const FormatException('外观快照缺少系统强调色。');
    }
    return GlassAppearance(
      mode: mode,
      opacity: opacity,
      accentLight: Color(accentLight),
      accentDark: Color(accentDark),
    );
  }

  /// 无参数；返回Material主题模式，跟随系统由Flutter现有亮度通知驱动。
  ThemeMode get themeMode => switch (mode) {
    AppearanceModes.light => ThemeMode.light,
    AppearanceModes.dark => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}

/// 五类窗口共享的外观入口；专用视觉通道不覆盖任何业务通道的回调。
class NativeGlassApp extends StatefulWidget {
  /// home 为保留状态的业务根，title 为窗口语义名称；创建统一主题应用。
  const NativeGlassApp({super.key, required this.home, this.title = ''});
  final Widget home;
  final String title;

  /// 无参数；返回仅订阅视觉偏好的状态，业务状态由home持有。
  @override
  State<NativeGlassApp> createState() => _NativeGlassAppState();
}

/// 订阅当前引擎视觉广播；dispose解除回调，不管理业务会话。
class _NativeGlassAppState extends State<NativeGlassApp> {
  /// 无参数；先注册广播再读取快照，不接管业务通道。
  @override
  void initState() {
    super.initState();
    GlassAppearance.channel.setMethodCallHandler((call) async {
      if (call.method == MethodNames.appearanceChanged) {
        GlassAppearance.current.value = GlassAppearance.fromMap(
          Map<Object?, Object?>.from(call.arguments as Map),
        );
      }
    });
    unawaited(_load());
  }

  /// 无参数；读取本引擎启动时的视觉快照，返回加载完成的Future。
  Future<void> _load() async {
    final value = await GlassAppearance.channel
        .invokeMapMethod<Object?, Object?>(MethodNames.getAppearance);
    if (mounted && value != null) {
      GlassAppearance.current.value = GlassAppearance.fromMap(value);
    }
  }

  /// 无参数；解除当前引擎回调，不清除已保存偏好。
  @override
  void dispose() {
    GlassAppearance.channel.setMethodCallHandler(null);
    super.dispose();
  }

  /// context 为当前引擎；仅重建主题与中文本地化委托，home的元素身份保持不变。
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<GlassAppearance>(
    valueListenable: GlassAppearance.current,
    builder: (context, appearance, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: widget.title,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      themeMode: appearance.themeMode,
      theme: NativeGlassTheme.data(Brightness.light, appearance),
      darkTheme: NativeGlassTheme.data(Brightness.dark, appearance),
      builder: (context, child) => _GlassAppearanceScope(child: child!),
      home: widget.home,
    ),
  );
}

/// 把视觉广播传到已保留的子树，透明度更新不要求重建业务页面。
class _GlassAppearanceScope
    extends InheritedNotifier<ValueNotifier<GlassAppearance>> {
  /// child 为当前Navigator；订阅引擎视觉状态而不修改业务对象。
  _GlassAppearanceScope({required super.child})
    : super(notifier: GlassAppearance.current);
}

/// 标记单个原生材料的前景子树，避免共享控件重复折射。
class _GlassMaterialScope extends InheritedWidget {
  /// child为共享当前材料的内容；不保存业务状态。
  const _GlassMaterialScope({required super.child});

  /// oldWidget为上次作用域；标记恒定，无需通知。
  @override
  bool updateShouldNotify(_GlassMaterialScope oldWidget) => false;
}

/// 主题携带的系统强调色（#142）；经 NativeGlassTheme.accentOf 读取，明暗切换时随主题插值，并派生满足 WCAG AA 的实底与前景色。
class GlassAccent extends ThemeExtension<GlassAccent> {
  /// color 为当前外观下解析的系统强调色。
  const GlassAccent(this.color);
  final Color color;

  /// 无参数；返回适配 WCAG 2.2 AA（>= 4.5:1）的选中实底颜色。
  Color get fill => NativeGlassTheme.accentColorsFor(color).fill;

  /// 无参数；返回与 fill 配对的前景字色。
  Color get onAccent => NativeGlassTheme.accentColorsFor(color).foreground;

  /// color 为替换值；返回新的强调色扩展。
  @override
  GlassAccent copyWith({Color? color}) => GlassAccent(color ?? this.color);

  /// other 为目标主题的扩展，t 为插值进度；返回颜色插值后的扩展。
  @override
  GlassAccent lerp(covariant GlassAccent? other, double t) =>
      other == null ? this : GlassAccent(Color.lerp(color, other.color, t)!);
}
