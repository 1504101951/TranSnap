import 'package:flutter/services.dart';

/// 截图工具栏网格的修饰键位掩码（#141）：Control=1、Option=2、Shift=4、Command=8；工具栏不允许 Shift。
abstract final class ToolbarModifiers {
  static const control = 1;
  static const option = 2;
  static const shift = 4;
  static const command = 8;

  /// 允许的列组合，按设置下拉顺序：无、⌘、⌥、⌃、⌘⌥、⌘⌃、⌥⌃、⌘⌥⌃。
  static const allowed = [
    0,
    command,
    option,
    control,
    command | option,
    command | control,
    option | control,
    command | option | control,
  ];

  /// modifiers 为位掩码；返回按 macOS 惯例 ⌃⌥⇧⌘ 顺序排列的符号，无修饰为空字符串。
  static String label(int modifiers) =>
      '${modifiers & control != 0 ? '⌃' : ''}'
      '${modifiers & option != 0 ? '⌥' : ''}'
      '${modifiers & shift != 0 ? '⇧' : ''}'
      '${modifiers & command != 0 ? '⌘' : ''}';

  /// 无参数；返回当前按下的修饰键位掩码，从框架键盘状态读取。
  static int pressed() =>
      (HardwareKeyboard.instance.isControlPressed ? control : 0) |
      (HardwareKeyboard.instance.isAltPressed ? option : 0) |
      (HardwareKeyboard.instance.isShiftPressed ? shift : 0) |
      (HardwareKeyboard.instance.isMetaPressed ? command : 0);
}

/// 截图工具栏网格的尺寸规则（#141）：每列 6 格，最多 8 列；格位对应数字行 1–6 的物理键。
abstract final class ToolbarGrid {
  static const slots = 6;
  static const maxColumns = 8;

  /// 默认列的组合：无、⌘、⌥。
  static const defaultModifiers = [
    0,
    ToolbarModifiers.command,
    ToolbarModifiers.option,
  ];

  /// 数字行物理键到格位数字；按物理位置匹配，不受键盘布局与修饰键产生的字符影响。
  static final digits = {
    PhysicalKeyboardKey.digit1: 1,
    PhysicalKeyboardKey.digit2: 2,
    PhysicalKeyboardKey.digit3: 3,
    PhysicalKeyboardKey.digit4: 4,
    PhysicalKeyboardKey.digit5: 5,
    PhysicalKeyboardKey.digit6: 6,
  };
}
