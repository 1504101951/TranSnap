import 'package:flutter/services.dart';

import 'shortcut_keys.dart';

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

  /// 截图工具栏每行（竖放为每列）并排的组数，两组之间的最小间距（#67）。
  static const groupsPerLine = 2;
  static const groupGap = 12.0;

  /// 默认列的组合：无、⌘、⌥。
  static const defaultModifiers = [
    0,
    ToolbarModifiers.command,
    ToolbarModifiers.option,
  ];

  /// 格位 1–6 对应的数字行 Carbon/macOS 虚拟键码（kVK_ANSI_1…6），下标 0 为第 1 格。
  static const carbonKeyCodes = [18, 19, 20, 21, 23, 22];

  /// code、carbonModifiers 为全局快捷键的 Carbon 键码与修饰键位（ShortcutKeys）；
  /// 返回它落在的网格格位（修饰键位掩码与数字 1–6），不是数字行 1–6 或带 ⇧ 时为 null。
  static ({int modifiers, int digit})? slotOfCarbon(
    int code,
    int carbonModifiers,
  ) {
    final index = carbonKeyCodes.indexOf(code);
    if (index < 0 || carbonModifiers & ShortcutKeys.shift != 0) return null;
    return (
      modifiers:
          (carbonModifiers & ShortcutKeys.control != 0
              ? ToolbarModifiers.control
              : 0) |
          (carbonModifiers & ShortcutKeys.option != 0
              ? ToolbarModifiers.option
              : 0) |
          (carbonModifiers & ShortcutKeys.command != 0
              ? ToolbarModifiers.command
              : 0),
      digit: index + 1,
    );
  }

  /// code、cocoaFlags 为系统快捷键的虚拟键码与 NSEvent 修饰键标志原始值；
  /// 返回落在的网格格位，不是数字行 1–6 或带 ⇧ 时为 null。
  static ({int modifiers, int digit})? slotOfCocoa(int code, int cocoaFlags) {
    final index = carbonKeyCodes.indexOf(code);
    // NSEvent.ModifierFlags：Shift 1<<17、Control 1<<18、Option 1<<19、Command 1<<20。
    if (index < 0 || cocoaFlags & (1 << 17) != 0) return null;
    return (
      modifiers:
          (cocoaFlags & (1 << 18) != 0 ? ToolbarModifiers.control : 0) |
          (cocoaFlags & (1 << 19) != 0 ? ToolbarModifiers.option : 0) |
          (cocoaFlags & (1 << 20) != 0 ? ToolbarModifiers.command : 0),
      digit: index + 1,
    );
  }

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
