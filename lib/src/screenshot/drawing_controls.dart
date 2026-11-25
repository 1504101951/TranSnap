import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../common/widgets/line_icon.dart';
import '../common/constants/drawing_metrics.dart';
import '../common/constants/glass_metrics.dart';
import '../common/constants/screenshot_enums.dart';
import '../common/widgets/native_glass.dart';
import 'drawing_style.dart';

Color? parseDrawingColor(String text) {
  final hex = text.trim().replaceFirst(RegExp(r'^#'), '');
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
  return Color(0xFF000000 | int.parse(hex, radix: 16));
}

class ColorPicker extends StatefulWidget {
  const ColorPicker({
    super.key,
    required this.initial,
    required this.onApply,
    required this.onCancel,
    this.footer,
    this.allowGradient = true,
    this.onPreview,
  });
  final ColorFill initial;
  final ValueChanged<ColorFill> onApply;
  final VoidCallback onCancel;
  final Widget? footer;
  final bool allowGradient;
  final ValueChanged<Color>? onPreview;
  @override
  State<ColorPicker> createState() => _ColorPickerState();
}

class _ColorPickerState extends State<ColorPicker> {
  late bool _gradient = widget.initial.gradient != null;
  late HSVColor _start = HSVColor.fromColor(widget.initial.color);
  late HSVColor _end = HSVColor.fromColor(
    widget.initial.gradient?.end ?? DrawingMetrics.gradients.first.to,
  );
  late GradientDirection _direction =
      widget.initial.gradient?.direction ?? GradientDirection.downRight;

  bool _editingEnd = false;
  late final TextEditingController _hex = TextEditingController(
    text: _hexString(widget.initial.color),
  );
  bool _invalid = false;

  HSVColor get _hsv => _gradient && _editingEnd ? _end : _start;

  String _hexString(Color color) => (color.toARGB32() & 0xFFFFFF)
      .toRadixString(16)
      .padLeft(6, '0')
      .toUpperCase();

  void _setColor(HSVColor value) {
    setState(() {
      if (_gradient && _editingEnd) {
        _end = value;
      } else {
        _start = value;
      }
      _invalid = false;
      _hex.text = _hexString(value.toColor());
    });
    if (!_gradient) widget.onPreview?.call(value.toColor());
  }

  void _selectWell(bool end) => setState(() {
    _editingEnd = end;
    _invalid = false;
    _hex.text = _hexString(_hsv.toColor());
  });

  void _pickField(Offset point) => _setColor(
    _hsv
        .withSaturation((point.dx / DrawingMetrics.fieldWidth).clamp(0, 1))
        .withValue((1 - point.dy / DrawingMetrics.fieldHeight).clamp(0, 1)),
  );

  ColorFill get _value => (
    color: _start.toColor(),
    gradient: _gradient
        ? FillGradient(end: _end.toColor(), direction: _direction)
        : null,
  );

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  Widget _swatch({
    required Key key,
    required String label,
    required Color color,
    required bool selected,
    required VoidCallback onTap,
    Color? gradientEnd,
    double width = DrawingMetrics.swatch,
    double height = DrawingMetrics.swatch,
    double border = 1,
  }) => Semantics(
    button: true,
    selected: selected,
    label: label,
    child: InkWell(
      key: key,
      onTap: onTap,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: gradientEnd == null ? color : null,
          gradient: gradientEnd == null
              ? null
              : LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [color, gradientEnd],
                ),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.grey,
            width: border,
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final (begin, end) = switch (_direction) {
      GradientDirection.right => (Alignment.centerLeft, Alignment.centerRight),
      GradientDirection.down => (Alignment.topCenter, Alignment.bottomCenter),
      GradientDirection.downRight => (Alignment.topLeft, Alignment.bottomRight),
      GradientDirection.upRight => (Alignment.bottomLeft, Alignment.topRight),
    };
    return SizedBox(
      width: DrawingMetrics.paletteWidth,
      child: Padding(
        padding: const EdgeInsets.all(DrawingMetrics.padding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '颜色',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (widget.allowGradient)
                  NativeGlassSegments<bool>(
                    value: _gradient,
                    options: const {false: '纯色', true: '渐变'},
                    onChanged: (value) => setState(() {
                      _gradient = value;
                      _editingEnd = false;
                      _invalid = false;
                      _hex.text = _hexString(_start.toColor());
                    }),
                  ),
              ],
            ),
            const SizedBox(height: DrawingMetrics.gap),
            if (_gradient) ...[
              Wrap(
                spacing: DrawingMetrics.gap,
                children: [
                  for (final (index, preset)
                      in DrawingMetrics.gradients.indexed)
                    _swatch(
                      key: Key('gradient-preset-$index'),
                      label: '渐变 ${preset.name}',
                      color: preset.from,
                      gradientEnd: preset.to,
                      selected:
                          _start.toColor() == preset.from &&
                          _end.toColor() == preset.to,
                      onTap: () => setState(() {
                        _start = HSVColor.fromColor(preset.from);
                        _end = HSVColor.fromColor(preset.to);
                        _direction = GradientDirection.downRight;
                        _invalid = false;
                        _hex.text = _hexString(_hsv.toColor());
                      }),
                    ),
                ],
              ),
              const SizedBox(height: DrawingMetrics.gap),
              Row(
                children: [
                  _swatch(
                    key: const Key('gradient-start'),
                    label: '起始色',
                    color: _start.toColor(),
                    selected: !_editingEnd,
                    onTap: () => _selectWell(false),
                    width: DrawingMetrics.wellWidth,
                    height: DrawingMetrics.wellHeight,
                    border: _editingEnd ? 1 : DrawingMetrics.wellSelectedBorder,
                  ),
                  const SizedBox(width: DrawingMetrics.gap),
                  _swatch(
                    key: const Key('gradient-end'),
                    label: '结束色',
                    color: _end.toColor(),
                    selected: _editingEnd,
                    onTap: () => _selectWell(true),
                    width: DrawingMetrics.wellWidth,
                    height: DrawingMetrics.wellHeight,
                    border: _editingEnd ? DrawingMetrics.wellSelectedBorder : 1,
                  ),
                ],
              ),
              const SizedBox(height: DrawingMetrics.gap),
            ],
            Semantics(
              label: '饱和度与亮度',
              child: GestureDetector(
                key: const Key('color-field'),
                onTapDown: (e) => _pickField(e.localPosition),
                onPanStart: (e) => _pickField(e.localPosition),
                onPanUpdate: (e) => _pickField(e.localPosition),
                child: SizedBox(
                  height: DrawingMetrics.fieldHeight,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.white,
                                HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor(),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Colors.black],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: (_hsv.saturation * DrawingMetrics.fieldWidth - 4)
                            .clamp(0, DrawingMetrics.fieldWidth - 8),
                        top: ((1 - _hsv.value) * DrawingMetrics.fieldHeight - 4)
                            .clamp(0, DrawingMetrics.fieldHeight - 8),
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white,
                              width: GlassMetrics.sliderThumbBorderWidth,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black54,
                                blurRadius: 2,
                                spreadRadius: 0.5,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: DrawingMetrics.gap),
            SizedBox(
              height: GlassMetrics.minTouchTarget,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Container(
                    height: 6,
                    margin: const EdgeInsets.symmetric(
                      horizontal: GlassMetrics.space8,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      gradient: const LinearGradient(
                        colors: [
                          Color(0xFFFF0000),
                          Color(0xFFFFFF00),
                          Color(0xFF00FF00),
                          Color(0xFF00FFFF),
                          Color(0xFF0000FF),
                          Color(0xFFFF00FF),
                          Color(0xFFFF0000),
                        ],
                      ),
                    ),
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 6,
                      activeTrackColor: Colors.transparent,
                      inactiveTrackColor: Colors.transparent,
                    ),
                    child: Slider(
                      key: const Key('color-hue'),
                      min: 0,
                      max: 360,
                      value: _hsv.hue,
                      semanticFormatterCallback: (v) => '色相 ${v.round()}度',
                      onChanged: (v) => _setColor(_hsv.withHue(v)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: DrawingMetrics.gap),
            if (!_gradient)
              Wrap(
                spacing: DrawingMetrics.gap,
                children: [
                  for (final color in DrawingMetrics.colors)
                    _swatch(
                      key: Key('palette-${_hexString(color)}'),
                      label: '颜色 ${_hexString(color)}',
                      color: color,
                      selected: color == _start.toColor(),
                      onTap: () => _setColor(HSVColor.fromColor(color)),
                    ),
                ],
              )
            else ...[
              Row(
                children: [
                  for (final (direction, icon, label) in const [
                    (GradientDirection.right, LucideIcons.arrowRight, '向右'),
                    (GradientDirection.down, LucideIcons.arrowDown, '向下'),
                    (GradientDirection.downRight, LucideIcons.arrowDownRight, '向右下'),
                    (GradientDirection.upRight, LucideIcons.arrowUpRight, '向右上'),
                  ]) ...[
                    SizedBox.square(
                      dimension: DrawingMetrics.directionButton,
                      child: NativeGlassButtonFeedback(
                        radius: GlassMetrics.controlRadius,
                        enabled: true,
                        child: IconButton(
                          key: Key('gradient-direction-${direction.name}'),
                          tooltip: '渐变$label',
                          padding: EdgeInsets.zero,
                          iconSize: 16,
                          onPressed: () =>
                              setState(() => _direction = direction),
                          icon: LineIcon(icon),
                          style: IconButton.styleFrom(
                            backgroundColor: _direction == direction
                                ? NativeGlassTheme.accentFillOf(context)
                                : Colors.transparent,
                            foregroundColor: _direction == direction
                                ? NativeGlassTheme.onAccentOf(context)
                                : null,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(
                                GlassMetrics.controlRadius,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                ],
              ),
              const SizedBox(height: DrawingMetrics.gap),
              Container(
                key: const Key('gradient-preview'),
                height: DrawingMetrics.previewHeight,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  gradient: LinearGradient(
                    begin: begin,
                    end: end,
                    colors: [_start.toColor(), _end.toColor()],
                  ),
                ),
              ),
            ],
            const SizedBox(height: DrawingMetrics.gap),
            SizedBox(
              height: 32,
              child: TextField(
                key: const Key('color-hex'),
                controller: _hex,
                decoration: const InputDecoration(
                  prefixText: '#',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                ),
                onChanged: (text) {
                  final color = parseDrawingColor(text);
                  setState(() {
                    _invalid = color == null;
                    if (color == null) return;
                    if (_gradient && _editingEnd) {
                      _end = HSVColor.fromColor(color);
                    } else {
                      _start = HSVColor.fromColor(color);
                    }
                  });
                  if (color != null && !_gradient) {
                    widget.onPreview?.call(color);
                  }
                },
              ),
            ),
            if (_invalid)
              Padding(
                padding: const EdgeInsets.only(top: GlassMetrics.space4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LineIcon(
                      LucideIcons.circleAlert,
                      size: 13,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: GlassMetrics.space4),
                    Text(
                      '请输入6位十六进制颜色',
                      style: TextStyle(
                        fontSize: GlassMetrics.captionFont,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ),
              ),
            ?widget.footer,
            const SizedBox(height: DrawingMetrics.gap),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: widget.onCancel, child: const Text('取消')),
                const SizedBox(width: DrawingMetrics.gap),
                FilledButton(
                  key: const Key('apply-color'),
                  onPressed: _invalid ? null : () => widget.onApply(_value),
                  child: const Text('应用'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class StrokeWidthPicker extends StatefulWidget {
  const StrokeWidthPicker({
    super.key,
    required this.initial,
    required this.onApply,
    required this.onCancel,
  });
  final double initial;
  final ValueChanged<double> onApply;
  final VoidCallback onCancel;
  @override
  State<StrokeWidthPicker> createState() => _StrokeWidthPickerState();
}

class _StrokeWidthPickerState extends State<StrokeWidthPicker> {
  late double _value = widget.initial.roundToDouble().clamp(
    DrawingMetrics.minWidth,
    DrawingMetrics.maxWidth,
  );
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(DrawingMetrics.padding),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 200,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(trackHeight: 2),
                child: Slider(
                  key: const Key('stroke-width-slider'),
                  min: DrawingMetrics.minWidth,
                  max: DrawingMetrics.maxWidth,
                  divisions: 19,
                  value: _value,
                  semanticFormatterCallback: (v) => '${v.round()}pt',
                  onChanged: (v) => setState(() => _value = v),
                ),
              ),
            ),
            SizedBox(width: 40, child: Text('${_value.round()}pt')),
          ],
        ),
        const SizedBox(height: GlassMetrics.space12),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(onPressed: widget.onCancel, child: const Text('取消')),
            const SizedBox(width: DrawingMetrics.gap),
            FilledButton(
              key: const Key('apply-stroke-width'),
              onPressed: () => widget.onApply(_value),
              child: const Text('应用'),
            ),
          ],
        ),
      ],
    ),
  );
}
