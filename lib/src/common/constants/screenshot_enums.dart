import 'package:flutter/painting.dart';

enum ScreenshotTool {
  cursor,
  crop,
  rect,
  arrow,
  step,
  text,
  brush,
  eyedropper,
  ruler,
}

abstract final class ResizeCursorAxes {
  static const northWestSouthEast = 'nwse';
  static const northEastSouthWest = 'nesw';
}

enum AnnotationKind { rectangle, arrow, text, mask, stroke, step, sticker }

enum ShapeMode { solid, mosaic, highlighter }

class ScreenshotDefaults {
  ScreenshotDefaults._();

  static const Color strokeColor = Color(0xFFFF3B30);

  static const double fontSize = 18;

  static const double textBoxWidth = 240;
  static const double textBoxMinWidth = 24;

  static const List<Color> textColors = [
    Color(0xFFFF3B30),
    Color(0xFFFFFFFF),
    Color(0xFF000000),
    Color(0xFFFFCC00),
  ];

  static const List<double> fontSizes = [14, 18, 24, 32, 48];

  static const openableLinkSchemes = {'http', 'https'};
}

enum GradientDirection { right, down, downRight, upRight }

enum ShapeVariant {
  rectangle,
  circle,
  filledRectangle,
  filledCircle;

  bool get filled => this == filledRectangle || this == filledCircle;
  bool get circular => this == circle || this == filledCircle;
}

enum ScreenshotConfirmAction {
  copy,
  copyAndSave;

  static ScreenshotConfirmAction parse(String? wire) =>
      wire == null ? copy : values.byName(wire);
}

enum ScrollCaptureMode {
  manual,
  automatic;

  static ScrollCaptureMode parse(String? wire) =>
      wire == null ? manual : values.byName(wire);
}

enum CaptureTarget { region, application, display }

abstract final class RecordingOptions {
  static const delays = [0, 3, 5, 10];
}

enum RecordingClickEffect {
  off('关闭'),
  optical('光学涟漪'),
  liquid('液态弹波'),
  spotlight('聚光微点'),
  prism('星芒微烁'),
  minimal('极简双对比环'),
  system('系统原生');

  const RecordingClickEffect(this.label);

  final String label;

  static RecordingClickEffect parse(String? wire) {
    if (wire == null) return off;
    for (final value in values) {
      if (value.name == wire) return value;
    }
    throw FormatException('无效的录屏点击特效：$wire');
  }
}
