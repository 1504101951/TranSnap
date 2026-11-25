import 'package:flutter/painting.dart';

import '../common/constants/screenshot_enums.dart';
import '../common/constants/drawing_metrics.dart';
import 'drawing_style.dart';

class DrawingPreferences {
  DrawingPreferences({
    Map<ScreenshotTool, DrawingStyle>? styles,
    Map<String, DrawingStyle>? variants,
    this.fillColor = const Color(0xFF000000),
    this.shape = ShapeVariant.rectangle,
    this.brushMode = ShapeMode.solid,
    this.fontSize = ScreenshotDefaults.fontSize,
  }) : variants = Map.unmodifiable(variants ?? {}),
       styles = Map.unmodifiable(
         styles ??
             {
               ScreenshotTool.rect: const DrawingStyle(),
               ScreenshotTool.arrow: const DrawingStyle(),
               ScreenshotTool.step: const DrawingStyle(),
               ScreenshotTool.brush: const DrawingStyle(),
               ScreenshotTool.text: const DrawingStyle(),
             },
       );
  final Map<ScreenshotTool, DrawingStyle> styles;
  final Map<String, DrawingStyle> variants;
  final Color fillColor;
  final ShapeVariant shape;
  final ShapeMode brushMode;
  final double fontSize;

  DrawingStyle styleFor(
    ScreenshotTool tool, {
    ShapeVariant? shape,
    ShapeMode? brushMode,
  }) {
    final variant = _variantKey(
      tool,
      shape ?? this.shape,
      brushMode ?? this.brushMode,
    );
    if (variant != null && variants.containsKey(variant)) {
      return variants[variant]!;
    }
    if (tool == ScreenshotTool.rect && (shape ?? this.shape).filled) {
      return DrawingStyle(color: fillColor);
    }
    if (tool == ScreenshotTool.brush &&
        (brushMode ?? this.brushMode) == ShapeMode.highlighter) {
      return const DrawingStyle(
        color: DrawingMetrics.highlighterColor,
        strokeWidth: DrawingMetrics.highlighterWidth,
      );
    }
    return styles[tool] ?? const DrawingStyle();
  }

  static String? _variantKey(
    ScreenshotTool tool,
    ShapeVariant shape,
    ShapeMode mode,
  ) {
    if (tool == ScreenshotTool.rect) return shape.name;
    if (tool == ScreenshotTool.brush) return mode.name;
    return null;
  }

  factory DrawingPreferences.fromMap(Map<Object?, Object?>? raw) {
    if (raw == null) return DrawingPreferences();
    final defaults = DrawingPreferences();
    final saved = Map<String, Object?>.from(raw['tools'] as Map? ?? {});
    if (saved.keys.any(
      (key) => !defaults.styles.keys.any((tool) => tool.name == key),
    )) {
      throw const FormatException('未知绘图工具。');
    }
    final variants = <String, DrawingStyle>{};
    final rawVariants = Map<String, Object?>.from(
      raw['variants'] as Map? ?? {},
    );
    final allowed = {
      ...ShapeVariant.values.map((v) => v.name),
      ...ShapeMode.values.map((v) => v.name),
    };
    for (final entry in rawVariants.entries) {
      if (!allowed.contains(entry.key)) throw const FormatException('未知绘图子工具。');
      final value = entry.value as Map;
      final argb = value['color'] as int;
      final width = (value['width'] as num).toDouble();
      if (argb < 0xFF000000 ||
          argb > 0xFFFFFFFF ||
          !width.isFinite ||
          width < DrawingMetrics.minWidth ||
          width > DrawingMetrics.maxWidth) {
        throw const FormatException('绘图颜色或线宽无效。');
      }
      variants[entry.key] = DrawingStyle(
        color: Color(argb),
        strokeWidth: width,
        gradient: _gradient(value),
      );
    }
    final styles = {...defaults.styles};
    for (final tool in styles.keys.toList()) {
      final value = saved[tool.name] as Map?;
      if (value == null) continue;
      final argb = value['color'] as int;
      final width = (value['width'] as num).toDouble();
      if (argb < 0xFF000000 ||
          argb > 0xFFFFFFFF ||
          !width.isFinite ||
          width < DrawingMetrics.minWidth ||
          width > DrawingMetrics.maxWidth) {
        throw const FormatException('绘图颜色或线宽无效。');
      }
      styles[tool] = DrawingStyle(
        color: Color(argb),
        strokeWidth: width,
        gradient: _gradient(value),
      );
    }
    final fill = raw['fillColor'] as int? ?? defaults.fillColor.toARGB32();
    final font = (raw['fontSize'] as num?)?.toDouble() ?? defaults.fontSize;
    if (fill < 0xFF000000 ||
        fill > 0xFFFFFFFF ||
        !ScreenshotDefaults.fontSizes.contains(font)) {
      throw const FormatException('填充色或文字字号无效。');
    }
    return DrawingPreferences(
      styles: styles,
      variants: variants,
      fillColor: Color(fill),
      fontSize: font,
      shape: ShapeVariant.values.byName(
        raw['shape'] as String? ?? defaults.shape.name,
      ),
      brushMode: ShapeMode.values.byName(
        raw['brushMode'] as String? ?? defaults.brushMode.name,
      ),
    );
  }

  static FillGradient? _gradient(Map<Object?, Object?> value) =>
      switch (value['gradient']) {
        final Map<Object?, Object?> gradient => FillGradient.fromMap(gradient),
        _ => null,
      };

  Map<String, Object> toMap() => {
    'tools': styles.map(
      (tool, style) => MapEntry(tool.name, {
        'color': style.color.toARGB32(),
        'width': style.strokeWidth,
        'gradient': ?style.gradient?.toMap(),
      }),
    ),
    'variants': variants.map(
      (key, style) => MapEntry(key, {
        'color': style.color.toARGB32(),
        'width': style.strokeWidth,
        'gradient': ?style.gradient?.toMap(),
      }),
    ),
    'fillColor': fillColor.toARGB32(),
    'shape': shape.name,
    'brushMode': brushMode.name,
    'fontSize': fontSize,
  };

  DrawingPreferences copyWith({
    ScreenshotTool? tool,
    DrawingStyle? style,
    Color? fillColor,
    ShapeVariant? shape,
    ShapeMode? brushMode,
    double? fontSize,
  }) => DrawingPreferences(
    styles: {
      ...styles,
      if (tool != null &&
          style != null &&
          tool != ScreenshotTool.rect &&
          tool != ScreenshotTool.brush)
        tool: style,
    },
    variants: {
      ...variants,
      if (tool != null &&
          style != null &&
          _variantKey(tool, shape ?? this.shape, brushMode ?? this.brushMode) !=
              null)
        _variantKey(tool, shape ?? this.shape, brushMode ?? this.brushMode)!:
            style,
    },
    fillColor: fillColor ?? this.fillColor,
    shape: shape ?? this.shape,
    brushMode: brushMode ?? this.brushMode,
    fontSize: fontSize ?? this.fontSize,
  );
}
