import 'package:flutter/painting.dart';

/// 编辑工具；与工具栏一一对应，不含设置里的目录选择。eyedropper 为取色、ruler 为标尺，二者不产生标注（#111）。
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

/// 截图对角缩放光标的原生协议轴；与 Swift AppConstants.resizeNorthWestSouthEast / resizeNorthEastSouthWest 一致（#124）。
abstract final class ResizeCursorAxes {
  static const northWestSouthEast = 'nwse';
  static const northEastSouthWest = 'nesw';
}

/// 标注种类；裁剪不进入此枚举，撤销只覆盖这些标注。step 为步骤编号标记（#107）。
enum AnnotationKind { rectangle, arrow, text, mask, stroke, step, sticker }

/// 画笔绘制模式：普通颜色轨迹、原图像素马赛克或半透明荧光笔（#107）。
enum ShapeMode { solid, mosaic, highlighter }

/// 截图标注的默认样式；工具栏未改前使用这些值。
class ScreenshotDefaults {
  /// 无参数构造；禁止实例化。
  ScreenshotDefaults._();

  /// 矩形/箭头/文字默认红色，接近常见标注色。
  static const Color strokeColor = Color(0xFFFF3B30);

  /// 文字默认字号，适合视网膜截图像素。
  static const double fontSize = 18;

  /// 点击落字时的默认文本框；拖拽创建时用实际矩形。
  /// 点击创建文字框时的默认宽度与最小宽度，单位为屏幕点；高度随文字内容决定。
  static const double textBoxWidth = 240;
  static const double textBoxMinWidth = 24;

  /// 可选文字颜色，顺序即工具栏色点顺序。
  static const List<Color> textColors = [
    Color(0xFFFF3B30),
    Color(0xFFFFFFFF),
    Color(0xFF000000),
    Color(0xFFFFCC00),
  ];

  /// 字号档位；减/加在此列表内移动。
  static const List<double> fontSizes = [14, 18, 24, 32, 48];

  /// 识别结果中允许打开的链接协议；其他协议只可复制（#108），与 Swift 常量同步。
  static const openableLinkSchemes = {'http', 'https'};
}

/// 渐变方向：→、↓、↘、↗；名称用于绘图偏好持久化（#103）。
enum GradientDirection { right, down, downRight, upRight }

/// 图形工具的四种模式；名称用于偏好持久化。
enum ShapeVariant {
  rectangle,
  circle,
  filledRectangle,
  filledCircle;

  bool get filled => this == filledRectangle || this == filledCircle;
  bool get circular => this == circle || this == filledCircle;
}

/// 确认截图（回车或双击）时执行的动作；name 为偏好值，缺省为复制图片（#111）。
enum ScreenshotConfirmAction {
  copy,
  copyAndSave;

  /// wire为偏好原文；返回对应动作，缺省按复制图片处理，未知值直接抛错。
  static ScreenshotConfirmAction parse(String? wire) =>
      wire == null ? copy : values.byName(wire);
}

/// 长截图滚动方式；name 为偏好值，与原生 ScrollCaptureMode 逐项对应，缺省为手动滚动（#112）。
enum ScrollCaptureMode {
  manual,
  automatic;

  /// wire为偏好原文；返回对应方式，缺省按手动滚动处理，未知值直接抛错。
  static ScrollCaptureMode parse(String? wire) =>
      wire == null ? manual : values.byName(wire);
}

/// 录制目标协议；name与原生CaptureTarget逐项对应，应用包含全部可见窗口。
enum CaptureTarget { region, application, display }

/// 录制选项的取值。
abstract final class RecordingOptions {
  /// 开始录制前可选的倒计时秒数，0 为不延时；与 Swift AppConstants.recordingDelays 同步（#129）。
  static const delays = [0, 3, 5, 10];
}

/// 区域与显示器录制的鼠标点击特效样式；name 为偏好协议值，与原生 RecordingClickEffect 一致，缺省为关闭（#143）。
enum RecordingClickEffect {
  off('关闭'),
  optical('光学涟漪'),
  liquid('液态弹波'),
  spotlight('聚光微点'),
  prism('星芒微烁'),
  minimal('极简双对比环'),
  system('系统原生');

  const RecordingClickEffect(this.label);

  /// 设置与录制选项菜单展示的中文名称。
  final String label;

  /// wire 为偏好原文；返回对应特效枚举，缺省为 off，未知值抛出 FormatException。
  static RecordingClickEffect parse(String? wire) {
    if (wire == null) return off;
    for (final value in values) {
      if (value.name == wire) return value;
    }
    throw FormatException('无效的录屏点击特效：$wire');
  }
}
