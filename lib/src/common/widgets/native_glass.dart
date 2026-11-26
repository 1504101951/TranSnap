import 'line_icon.dart';
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
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:motor/motor.dart';

import 'app_motion.dart';
import '../constants/app_colors.dart';

class NativeGlassWindowPage extends StatelessWidget {
  const NativeGlassWindowPage({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ColoredBox(color: Theme.of(context).colorScheme.surface, child: child);
}

class NativeGlassSurface extends StatelessWidget {
  const NativeGlassSurface({
    super.key,
    required this.child,
    this.radius,
    this.material = false,
    this.busy = false,
  });

  final Widget child;
  final double? radius;

  final bool material;

  final bool busy;

  static ({
    bool isButton,
    bool isFilled,
    bool isIconButton,
    VoidCallback? onPressed,
  })
  _inspectButton(Widget child) {
    Widget current = child;
    while (true) {
      if (current is ButtonStyleButton) {
        return (
          isButton: true,
          isFilled: current is FilledButton,
          isIconButton: false,
          onPressed: current.onPressed,
        );
      }
      if (current is IconButton) {
        return (
          isButton: true,
          isFilled: false,
          isIconButton: true,
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
        return (
          isButton: false,
          isFilled: false,
          isIconButton: false,
          onPressed: null,
        );
      }
    }
  }

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
    context.dependOnInheritedWidgetOfExactType<_GlassAppearanceScope>();
    final brightness = Theme.of(context).brightness;
    final highContrast = MediaQuery.highContrastOf(context);
    final activeLayer = ModalRoute.isCurrentOf(context) != false;
    if (material &&
        context.dependOnInheritedWidgetOfExactType<_GlassMaterialScope>() !=
            null) {
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
            bezel: !button.isIconButton,
            child: glass,
          )
        : glass;
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

class NativeGlassButtonFeedback extends StatefulWidget {
  const NativeGlassButtonFeedback({
    super.key,
    required this.child,
    required this.radius,
    required this.enabled,
    this.inset = EdgeInsets.zero,
    this.hoverFeedback = true,
    this.pressScale = GlassMetrics.buttonPressedScale,
    this.accentHighlight = false,
    this.bezel = false,
  });

  final Widget child;
  final double radius;
  final bool enabled;
  final EdgeInsets inset;
  final bool hoverFeedback;
  final double pressScale;
  final bool accentHighlight;
  final bool bezel;

  @override
  State<NativeGlassButtonFeedback> createState() =>
      _NativeGlassButtonFeedbackState();
}

class _NativeGlassButtonFeedbackState extends State<NativeGlassButtonFeedback> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

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
            side: WidgetStatePropertyAll(
              BorderSide(color: colors.outlineVariant),
            ),
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
        cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
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
                if (widget.bezel && widget.enabled)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Padding(
                        padding: widget.inset,
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: outerTheme.brightness == Brightness.dark
                                  ? [
                                      Colors.white.withValues(alpha: 0.08),
                                      Colors.black.withValues(alpha: 0.05),
                                    ]
                                  : [
                                      Colors.white.withValues(alpha: 0.72),
                                      Colors.black.withValues(alpha: 0.03),
                                    ],
                            ),
                            shape: RoundedSuperellipseBorder(
                              borderRadius: BorderRadius.circular(
                                widget.radius,
                              ),
                              side: BorderSide(
                                color: outerTheme.brightness == Brightness.dark
                                    ? Colors.white.withValues(alpha: 0.14)
                                    : Colors.black.withValues(alpha: 0.10),
                                width: GlassMetrics.groupBorderWidth,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
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

class NativeGlassField extends StatefulWidget {
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

  @override
  State<NativeGlassField> createState() => _NativeGlassFieldState();
}

class _NativeGlassFieldState extends State<NativeGlassField> {
  bool _focused = false;

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
                  child: LineIcon(
                    LucideIcons.circleAlert,
                    size: 13,
                    color: colors.error,
                  ),
                ),
                const SizedBox(width: GlassMetrics.space4),
                Expanded(
                  child: Text(
                    widget.errorText!,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.error),
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

class NativeGlassSwitchTile extends StatelessWidget {
  const NativeGlassSwitchTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
    this.leading,
    this.busy = false,
  });
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget? leading;
  final bool busy;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: leading,
    title: Text(title),
    subtitle: subtitle == null
        ? null
        : Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
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
      busy: busy,
    ),
  );
}

class NativeGlassDropdown<T> extends StatelessWidget {
  const NativeGlassDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.caption,
    this.leading,
  });
  final String label;
  final T value;
  final Map<T, String> items;
  final ValueChanged<T>? onChanged;
  final String? caption;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => NativeGlassSettingRow(
    title: label,
    caption: caption,
    leading: leading,
    child: NativeGlassMenuButton<T>(
      value: value,
      items: items,
      onChanged: onChanged,
    ),
  );
}

class NativeGlassMenuButton<T> extends StatefulWidget {
  const NativeGlassMenuButton({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.dense = false,
    this.flat,
    this.quiet = false,
    this.quietTextStyle,
  });
  final T value;
  final Map<T, String> items;
  final ValueChanged<T>? onChanged;
  final bool dense;
  final Decoration? flat;
  final bool quiet;
  final TextStyle? quietTextStyle;

  @override
  State<NativeGlassMenuButton<T>> createState() =>
      _NativeGlassMenuButtonState<T>();
}

class _NativeGlassMenuButtonState<T> extends State<NativeGlassMenuButton<T>> {
  final _buttonFocus = FocusNode();
  final _selectedFocus = FocusNode();

  @override
  void dispose() {
    _buttonFocus.dispose();
    _selectedFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final items = widget.items;
    final onChanged = widget.onChanged;
    return MenuAnchor(
      childFocusNode: _buttonFocus,
      onOpen: () {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _selectedFocus.context != null) {
            _selectedFocus.requestFocus();
          }
        });
      },
      style: NativeGlassMenuPanel.anchorStyle,
      menuChildren: [
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
      builder: (context, controller, _) => widget.quiet
          ? _quietTrigger(context, controller)
          : ConstrainedBox(
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
                          items[value] ??
                              (items.isNotEmpty ? items.values.first : ''),
                          textAlign: TextAlign.left,
                          maxLines: widget.dense ? 1 : null,
                          overflow: widget.dense ? TextOverflow.ellipsis : null,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const LineIcon(LucideIcons.unfoldVertical, size: 12),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _quietTrigger(BuildContext context, MenuController controller) {
    final style =
        widget.quietTextStyle ?? Theme.of(context).textTheme.bodySmall!;
    final onChanged = widget.onChanged;
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: GlassMetrics.dropdownMaxWidth,
      ),
      child: NativeGlassButtonFeedback(
        radius: GlassMetrics.menuItemRadius,
        enabled: onChanged != null,
        child: TextButton(
          focusNode: _buttonFocus,
          onPressed: onChanged == null
              ? null
              : () =>
                    controller.isOpen ? controller.close() : controller.open(),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, GlassMetrics.hitSize),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            foregroundColor: style.color,
            textStyle: style,
            shape: RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(GlassMetrics.menuItemRadius),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  widget.items[widget.value] ??
                      (widget.items.isNotEmpty
                          ? widget.items.values.first
                          : ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: GlassMetrics.space4),
              const LineIcon(LucideIcons.chevronDown, size: 12),
            ],
          ),
        ),
      ),
    );
  }

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

class NativeGlassMenuPanel extends StatelessWidget {
  const NativeGlassMenuPanel({
    super.key,
    required this.children,
    this.maxHeight = GlassMetrics.menuMaxHeight,
  });
  final List<Widget> children;
  final double maxHeight;

  static const anchorStyle = MenuStyle(
    padding: WidgetStatePropertyAll(EdgeInsets.zero),
    backgroundColor: WidgetStatePropertyAll(Colors.transparent),
    elevation: WidgetStatePropertyAll(0),
  );

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

class NativeGlassMenuItem extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) => NativeGlassButtonFeedback(
    radius: GlassMetrics.menuItemRadius,
    enabled: onPressed != null,
    inset: const EdgeInsets.symmetric(vertical: 2),
    pressScale: 0.98,
    child: MenuItemButton(
      focusNode: focusNode,
      onPressed: onPressed,
      leadingIcon: checked == null
          ? null
          : SizedBox.square(
              dimension: GlassMetrics.icon,
              child: checked!
                  ? const LineIcon(LucideIcons.check, size: GlassMetrics.icon)
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

class NativeGlassRowIcon extends StatelessWidget {
  const NativeGlassRowIcon({super.key, required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: LineIcon(
      icon,
      size: GlassMetrics.rowIconSize,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

class NativeGlassKeycaps extends StatelessWidget {
  const NativeGlassKeycaps({super.key, required this.tokens});

  final List<String> tokens;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;
    final fill = dark
        ? Colors.white.withValues(alpha: 0.11)
        : Colors.white.withValues(alpha: 0.94);
    final border = dark
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.black.withValues(alpha: 0.13);
    final edgeShadow = dark
        ? Colors.black.withValues(alpha: 0.50)
        : Colors.black.withValues(alpha: 0.09);

    return Semantics(
      label: tokens.join(' '),
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < tokens.length; i++) ...[
            if (i > 0) const SizedBox(width: GlassMetrics.keycapGap),
            ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: GlassMetrics.keycapMinWidth,
                minHeight: GlassMetrics.keycapHeight,
                maxHeight: GlassMetrics.keycapHeight,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(
                    GlassMetrics.keycapRadius,
                  ),
                  border: Border.all(
                    color: border,
                    width: GlassMetrics.groupBorderWidth,
                  ),
                  boxShadow: [
                    BoxShadow(color: edgeShadow, offset: const Offset(0, 1.5)),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      tokens[i],
                      style: TextStyle(
                        fontSize: GlassMetrics.statusFont,
                        height: 1,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class NativeGlassSettingRow extends StatelessWidget {
  const NativeGlassSettingRow({
    super.key,
    required this.title,
    required this.child,
    this.caption,
    this.leading,
    this.captionWarning = false,
  });
  final String title;
  final String? caption;
  final Widget child;
  final Widget? leading;
  final bool captionWarning;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final label = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title),
          if (caption != null)
            Text(
              caption!,
              style: Theme.of(context).textTheme.bodySmall!.copyWith(
                color: captionWarning
                    ? AppColors.warning(
                        Theme.of(context).brightness == Brightness.dark,
                      )
                    : null,
              ),
            ),
        ],
      );
      final titleWithIcon = leading == null
          ? label
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                leading!,
                const SizedBox(width: GlassMetrics.rowIconGap),
                Expanded(child: label),
              ],
            );
      return ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: caption == null
              ? GlassMetrics.rowHeight
              : GlassMetrics.captionRowHeight,
        ),
        child: constraints.maxWidth < 416
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (leading == null)
                    label
                  else
                    Row(
                      children: [
                        leading!,
                        const SizedBox(width: GlassMetrics.rowIconGap),
                        Expanded(child: label),
                      ],
                    ),
                  const SizedBox(height: 8),
                  child,
                ],
              )
            : Row(
                children: [
                  Expanded(child: titleWithIcon),
                  const SizedBox(width: 16),
                  child,
                ],
              ),
      );
    },
  );
}

class NativeGlassStatus extends StatelessWidget {
  const NativeGlassStatus({super.key, required this.granted, this.label});

  final bool granted;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final text = label ?? (granted ? '已开启' : '未开启');
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = granted
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : AppColors.warning(dark);
    return Semantics(
      container: true,
      label: text,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            LineIcon(
              granted ? LucideIcons.check : LucideIcons.triangleAlert,
              size: GlassMetrics.statusIcon,
              color: color,
            ),
            const SizedBox(width: GlassMetrics.space4),
            Text(
              text,
              style: Theme.of(context).textTheme.bodySmall!
                  .copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class NativeGlassGroup extends StatelessWidget {
  const NativeGlassGroup({
    super.key,
    required this.children,
    this.title,
    this.dividerIndent = GlassMetrics.rowIconSize + GlassMetrics.rowIconGap,
  });
  final List<Widget> children;
  final String? title;
  final double dividerIndent;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;
    final line = (dark ? Colors.white : Colors.black).withValues(alpha: 0.10);
    final card = DecoratedBox(
      decoration: ShapeDecoration(
        color: AppColors.card(dark),
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
            vertical: GlassMetrics.groupPaddingY,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: GlassMetrics.groupDividerThickness,
                    thickness: GlassMetrics.groupDividerThickness,
                    indent: dividerIndent,
                    color: line,
                  ),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: GlassMetrics.groupGap),
      child: title == null
          ? card
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    left: GlassMetrics.groupHeaderIndent,
                    bottom: GlassMetrics.groupHeaderGap,
                  ),
                  child: Text(
                    title!,
                    style: TextStyle(
                      fontSize: GlassMetrics.groupHeaderFont,
                      height: 16 / GlassMetrics.groupHeaderFont,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                card,
              ],
            ),
    );
  }
}

class NativeGlassSegments<T> extends StatefulWidget {
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

  @override
  State<NativeGlassSegments<T>> createState() => _NativeGlassSegmentsState<T>();
}

class _NativeGlassSegmentsState<T> extends State<NativeGlassSegments<T>> {
  final _stackKey = GlobalKey();
  late List<GlobalKey> _itemKeys = _makeKeys(widget.options.length);
  List<({double left, double width})>? _rects;
  bool _measureScheduled = false;

  static List<GlobalKey> _makeKeys(int count) =>
      List.generate(count, (_) => GlobalKey());

  @override
  void initState() {
    super.initState();
    _scheduleMeasure();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleMeasure();
  }

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

  static bool _sameIcons<K>(Map<K, IconData> a, Map<K, IconData> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  void _scheduleMeasure() {
    if (_measureScheduled) return;
    _measureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureScheduled = false;
      _measure();
    });
  }

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

    Widget indicator(double left, double segmentWidth) {
      final accentFill = NativeGlassTheme.accentFillOf(context);
      return Positioned(
        left: left,
        top: 0,
        width: segmentWidth,
        height: height,
        child: IgnorePointer(
          child: DecoratedBox(
            key: const ValueKey('native-glass-segments-indicator'),
            decoration: ShapeDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.lerp(accentFill, Colors.white, 0.10)!,
                  accentFill,
                ],
              ),
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(radius),
                side: BorderSide(
                  color: Colors.white.withValues(alpha: 0.24),
                  width: GlassMetrics.groupBorderWidth,
                ),
              ),
              shadows: [
                BoxShadow(
                  color: accentFill.withValues(alpha: 0.30),
                  blurRadius: 6,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
          ),
        ),
      );
    }

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
                                    overlayColor: Colors.transparent,
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
                                        LineIcon(
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

typedef NativeGlassSidebarSection<T> = ({
  String title,
  IconData icon,
  T? value,
  Map<T, String> children,
});

class NativeGlassSidebar<T> extends StatelessWidget {
  const NativeGlassSidebar({
    super.key,
    required this.value,
    required this.sections,
    required this.onChanged,
    this.topPadding = GlassMetrics.sidebarPadding,
  });
  final T value;
  final List<NativeGlassSidebarSection<T>> sections;
  final ValueChanged<T> onChanged;
  final double topPadding;

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

  @override
  Widget build(BuildContext context) {
    final selection = _selectedGeometry();
    final reduced = AppMotion.reduced(context);
    final rows = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final section in sections) ...[
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
    Widget indicator(double top, double height) {
      final accentFill = NativeGlassTheme.accentFillOf(context);
      return Positioned(
        left: GlassMetrics.sidebarSelectionInset,
        right: GlassMetrics.sidebarSelectionInset,
        top: top,
        height: height,
        child: IgnorePointer(
          child: DecoratedBox(
            key: const ValueKey('native-glass-sidebar-indicator'),
            decoration: ShapeDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.lerp(accentFill, Colors.white, 0.08)!,
                  accentFill,
                ],
              ),
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
                side: BorderSide(
                  color: Colors.white.withValues(alpha: 0.22),
                  width: GlassMetrics.groupBorderWidth,
                ),
              ),
              shadows: [
                BoxShadow(
                  color: accentFill.withValues(alpha: 0.28),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return NativeGlassSurface(
      material: true,
      radius: 0,
      child: SizedBox(
        width: GlassMetrics.sidebarWidth,
        height: double.infinity,
        child: ListView(
          padding: EdgeInsets.only(
            top: topPadding,
            bottom: GlassMetrics.sidebarPadding,
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
              child: LineIcon(
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

class NativeGlassSwitch extends StatefulWidget {
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

  @override
  State<NativeGlassSwitch> createState() => _NativeGlassSwitchState();
}

class _NativeGlassSwitchState extends State<NativeGlassSwitch> {
  bool _focused = false;
  bool _hovered = false;
  bool _pressed = false;

  void _toggle() => widget.onChanged?.call(!widget.value);

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
                        child: SingleMotionBuilder(
                          value: widget.value ? 1.0 : 0.0,
                          motion: AppMotion.bouncy(context),
                          builder: (context, progress, _) =>
                              SingleMotionBuilder(
                                value: _pressed && enabled && !reduced
                                    ? GlassMetrics.switchThumbPressedWidth
                                    : GlassMetrics.switchThumb,
                                motion: AppMotion.bouncy(context),
                                builder: (context, thumbWidth, _) {
                                  const innerSpan =
                                      GlassMetrics.switchWidth - 4;
                                  final maxLeft = innerSpan - thumbWidth;
                                  final left = (maxLeft * progress).clamp(
                                    -1.5,
                                    maxLeft + 1.5,
                                  );
                                  return Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      Positioned(
                                        left: left,
                                        top: 0,
                                        child: SizedBox(
                                          width: thumbWidth,
                                          height: GlassMetrics.switchThumb,
                                          child: DecoratedBox(
                                            key: const ValueKey(
                                              'native-glass-switch-thumb',
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.white,
                                              borderRadius:
                                                  BorderRadius.circular(
                                                    GlassMetrics.switchThumb /
                                                        2,
                                                  ),
                                              border: Border.all(
                                                color: Colors.black.withValues(
                                                  alpha: 0.12,
                                                ),
                                                width: 0.5,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.black
                                                      .withValues(alpha: 0.18),
                                                  blurRadius: 3,
                                                  offset: const Offset(0, 1),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
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

class NativeGlassDialog extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) => BouncyPresence(
    fromScale: 0.94,
    child: Dialog(
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
              Flexible(
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context)
                      .copyWith(scrollbars: false),
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
    ),
  );
}

class NativeGlassBanner extends StatelessWidget {
  const NativeGlassBanner({
    super.key,
    required this.message,
    this.isError = true,
    this.action,
  });

  final String message;
  final bool isError;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = NativeGlassTheme.accentOf(context);
    final foreground = isError
        ? AppColors.error(dark)
        : (dark ? const Color(0xFFCCCCCC) : AppColors.ink);
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
            LineIcon(
              isError ? LucideIcons.circleAlert : LucideIcons.info,
              size: GlassMetrics.icon,
              color: foreground,
            ),
            const SizedBox(width: GlassMetrics.space8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: foreground),
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

class _UniformSliderTrack extends RoundedRectSliderTrackShape {
  const _UniformSliderTrack();

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

class _AccentSliderThumbShape extends SliderComponentShape {
  const _AccentSliderThumbShape({required this.borderColor});

  final Color borderColor;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) =>
      const Size.fromRadius(GlassMetrics.sliderThumbRadius);

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

abstract final class NativeGlassTheme {
  static double contrastRatio(Color a, Color b) {
    final l1 = a.computeLuminance();
    final l2 = b.computeLuminance();
    return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
  }

  static ({Color fill, Color foreground}) accentColorsFor(
    Color accent, {
    String foreground = AccentForegrounds.auto,
  }) {
    final fixed = AccentForegrounds.colorOf(foreground);
    if (fixed != null) return (fill: accent, foreground: fixed);
    if (contrastRatio(Colors.white, accent) >= 4.5) {
      return (fill: accent, foreground: Colors.white);
    }
    if (accent.computeLuminance() >= 0.27 &&
        contrastRatio(AppColors.ink, accent) >= 4.5) {
      return (fill: accent, foreground: AppColors.ink);
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

  static Color accentOf(BuildContext context) =>
      Theme.of(context).extension<GlassAccent>()?.color ??
      Theme.of(context).colorScheme.primary;

  static Color accentFillOf(BuildContext context) =>
      Theme.of(context).extension<GlassAccent>()?.fill ??
      accentColorsFor(accentOf(context)).fill;

  static Color onAccentOf(BuildContext context) =>
      Theme.of(context).extension<GlassAccent>()?.onAccent ??
      accentColorsFor(accentOf(context)).foreground;

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
      (states) =>
          states.contains(WidgetState.focused) ? focusedSide : restingSide,
    ),
  );

  static ThemeData data(
    Brightness brightness, [
    GlassAppearance appearance = const GlassAppearance(),
  ]) {
    final dark = brightness == Brightness.dark;
    final accent = dark ? appearance.accentDark : appearance.accentLight;
    final accentPair = accentColorsFor(
      accent,
      foreground: appearance.accentForeground,
    );
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
          primary: dark
              ? Color.lerp(accent, Colors.white, 0.35)
              : Color.lerp(accent, Colors.black, 0.25),
          onPrimary: dark ? Colors.black : Colors.white,
          error: dark ? const Color(0xFFFF453A) : const Color(0xFFD70015),
          onError: Colors.white,
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
        labelSmall: text.copyWith(
          fontSize: GlassMetrics.statusFont,
          height: 16 / GlassMetrics.statusFont,
          fontWeight: FontWeight.w600,
        ),
        titleSmall: text.copyWith(
          fontSize: 15,
          height: 22 / 15,
          fontWeight: FontWeight.w600,
        ),
        headlineSmall: text.copyWith(
          fontSize: GlassMetrics.pageTitleFont,
          height: 26 / GlassMetrics.pageTitleFont,
          fontWeight: FontWeight.w600,
        ),
      ),
      iconTheme: IconThemeData(
        size: GlassMetrics.icon,
        color: colors.onSurface,
      ),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      splashFactory: NoSplash.splashFactory,
      listTileTheme: const ListTileThemeData(
        minLeadingWidth: GlassMetrics.rowIconSize,
        horizontalTitleGap: GlassMetrics.rowIconGap,
      ),
      colorScheme: colors,
      extensions: [
        GlassAccent(accent, foreground: appearance.accentForeground),
      ],
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
          (states) =>
              (states.contains(WidgetState.focused) ||
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
          color: dark ? const Color(0xFFE5E5EA) : const Color(0xFF2C2C2E),
          borderRadius: BorderRadius.circular(GlassMetrics.controlRadius),
        ),
        textStyle: TextStyle(
          fontSize: GlassMetrics.captionFont,
          color: dark ? AppColors.ink : Colors.white,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: GlassMetrics.space8,
          vertical: GlassMetrics.space4,
        ),
        waitDuration: const Duration(milliseconds: 200),
      ),
    );
  }
}

class GlassAppearance {
  const GlassAppearance({
    this.mode = AppearanceModes.system,
    this.opacity = 0.8,
    this.accentLight = SystemHues.blue,
    this.accentDark = SystemHues.blueDark,
    this.accentForeground = AccentForegrounds.auto,
  });
  final String mode;
  final double opacity;
  final Color accentLight;
  final Color accentDark;

  final String accentForeground;
  static final current = ValueNotifier(const GlassAppearance());
  static const channel = MethodChannel(ChannelNames.appearance);

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
    final foreground =
        map[PreferenceKeys.accentForeground] as String? ??
        AccentForegrounds.auto;
    if (!AccentForegrounds.isValid(foreground)) {
      throw const FormatException('外观快照的前景色无效。');
    }
    return GlassAppearance(
      mode: mode,
      opacity: opacity,
      accentLight: Color(accentLight),
      accentDark: Color(accentDark),
      accentForeground: foreground,
    );
  }

  ThemeMode get themeMode => switch (mode) {
    AppearanceModes.light => ThemeMode.light,
    AppearanceModes.dark => ThemeMode.dark,
    _ => ThemeMode.system,
  };
}

class NativeGlassApp extends StatefulWidget {
  const NativeGlassApp({super.key, required this.home, this.title = ''});
  final Widget home;
  final String title;

  @override
  State<NativeGlassApp> createState() => _NativeGlassAppState();
}

class _NativeGlassAppState extends State<NativeGlassApp> {
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

  Future<void> _load() async {
    final value = await GlassAppearance.channel
        .invokeMapMethod<Object?, Object?>(MethodNames.getAppearance);
    if (mounted && value != null) {
      GlassAppearance.current.value = GlassAppearance.fromMap(value);
    }
  }

  @override
  void dispose() {
    GlassAppearance.channel.setMethodCallHandler(null);
    super.dispose();
  }

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

class _GlassAppearanceScope
    extends InheritedNotifier<ValueNotifier<GlassAppearance>> {
  _GlassAppearanceScope({required super.child})
    : super(notifier: GlassAppearance.current);
}

class _GlassMaterialScope extends InheritedWidget {
  const _GlassMaterialScope({required super.child});

  @override
  bool updateShouldNotify(_GlassMaterialScope oldWidget) => false;
}

class GlassAccent extends ThemeExtension<GlassAccent> {
  const GlassAccent(this.color, {this.foreground = AccentForegrounds.auto});
  final Color color;
  final String foreground;

  Color get fill =>
      NativeGlassTheme.accentColorsFor(color, foreground: foreground).fill;

  Color get onAccent => NativeGlassTheme.accentColorsFor(
    color,
    foreground: foreground,
  ).foreground;

  @override
  GlassAccent copyWith({Color? color, String? foreground}) => GlassAccent(
    color ?? this.color,
    foreground: foreground ?? this.foreground,
  );

  @override
  GlassAccent lerp(covariant GlassAccent? other, double t) => other == null
      ? this
      : GlassAccent(
          Color.lerp(color, other.color, t)!,
          foreground: t < 0.5 ? foreground : other.foreground,
        );
}
