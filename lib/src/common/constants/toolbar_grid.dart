import 'package:flutter/services.dart';

import 'shortcut_keys.dart';

abstract final class ToolbarModifiers {
  static const control = 1;
  static const option = 2;
  static const shift = 4;
  static const command = 8;

  static const allowed = [
    command,
    option,
    control,
    command | option,
    command | control,
    option | control,
    command | option | control,
  ];

  static String label(int modifiers) =>
      '${modifiers & control != 0 ? '⌃' : ''}'
      '${modifiers & option != 0 ? '⌥' : ''}'
      '${modifiers & shift != 0 ? '⇧' : ''}'
      '${modifiers & command != 0 ? '⌘' : ''}';

  static int pressed() =>
      (HardwareKeyboard.instance.isControlPressed ? control : 0) |
      (HardwareKeyboard.instance.isAltPressed ? option : 0) |
      (HardwareKeyboard.instance.isShiftPressed ? shift : 0) |
      (HardwareKeyboard.instance.isMetaPressed ? command : 0);
}

abstract final class ToolbarGrid {
  static const slots = 6;
  static const maxColumns = 8;

  static const groupsPerLine = 2;

  static const blockPadding = 4.0;
  static const blockRadius = 12.0;
  static const blockGap = 8.0;
  static const hintExtent = 24.0;
  static const hintFont = 11.0;
  static const tabKeycapFont = 8.0;
  static const tabKeycapBorder = 1.2;
  static const tabKeycapRadius = 3.0;
  static const blockThickness = 32 + blockPadding * 2;

  static const trayPadding = 2.0;
  static const trayButton = 28.0;
  static const trayButtonRadius = 7.0;
  static const trayRadius = 9.0;
  static const trayThickness = trayButton + trayPadding * 2;
  static const trayCaretHeight = 4.0;
  static const trayCaretWidth = 12.0;
  static const traySeparatorLength = 16.0;
  static const traySeparatorGap = 4.0;

  static const lineGap = 4.0;

  static const defaultModifiers = [
    ToolbarModifiers.command,
    ToolbarModifiers.option,
  ];


  static const carbonKeyCodes = [18, 19, 20, 21, 23, 22];

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

  static ({int modifiers, int digit})? slotOfCocoa(int code, int cocoaFlags) {
    final index = carbonKeyCodes.indexOf(code);
    if (index < 0 || cocoaFlags & (1 << 17) != 0) return null;
    return (
      modifiers:
          (cocoaFlags & (1 << 18) != 0 ? ToolbarModifiers.control : 0) |
          (cocoaFlags & (1 << 19) != 0 ? ToolbarModifiers.option : 0) |
          (cocoaFlags & (1 << 20) != 0 ? ToolbarModifiers.command : 0),
      digit: index + 1,
    );
  }

  static final digits = {
    PhysicalKeyboardKey.digit1: 1,
    PhysicalKeyboardKey.digit2: 2,
    PhysicalKeyboardKey.digit3: 3,
    PhysicalKeyboardKey.digit4: 4,
    PhysicalKeyboardKey.digit5: 5,
    PhysicalKeyboardKey.digit6: 6,
  };
}
