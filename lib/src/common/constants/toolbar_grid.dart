import 'package:flutter/services.dart';

import 'shortcut_keys.dart';

abstract final class ToolbarModifiers {
  static const allowed = [
    ShortcutModifiers.meta,
    ShortcutModifiers.alt,
    ShortcutModifiers.control,
    ShortcutModifiers.meta | ShortcutModifiers.alt,
    ShortcutModifiers.meta | ShortcutModifiers.control,
    ShortcutModifiers.alt | ShortcutModifiers.control,
    ShortcutModifiers.meta | ShortcutModifiers.alt | ShortcutModifiers.control,
  ];

  static String label(int modifiers) =>
      '${modifiers & ShortcutModifiers.control != 0 ? '⌃' : ''}'
      '${modifiers & ShortcutModifiers.alt != 0 ? '⌥' : ''}'
      '${modifiers & ShortcutModifiers.shift != 0 ? '⇧' : ''}'
      '${modifiers & ShortcutModifiers.meta != 0 ? '⌘' : ''}';

  static int pressed() =>
      (HardwareKeyboard.instance.isControlPressed
          ? ShortcutModifiers.control
          : 0) |
      (HardwareKeyboard.instance.isAltPressed ? ShortcutModifiers.alt : 0) |
      (HardwareKeyboard.instance.isShiftPressed ? ShortcutModifiers.shift : 0) |
      (HardwareKeyboard.instance.isMetaPressed ? ShortcutModifiers.meta : 0);
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
    ShortcutModifiers.meta,
    ShortcutModifiers.alt,
  ];

  static const digitKeys = [
    'Digit1',
    'Digit2',
    'Digit3',
    'Digit4',
    'Digit5',
    'Digit6',
  ];

  static ({int modifiers, int digit})? slotOf(String key, int modifiers) {
    final index = digitKeys.indexOf(key);
    if (index < 0 || modifiers & ShortcutModifiers.shift != 0) return null;
    return (modifiers: modifiers, digit: index + 1);
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
