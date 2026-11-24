import '../constants/shortcut_keys.dart';

/// modifiers 为 Carbon 修饰键掩码，label 为主键显示文字；按 ⌃⌥⇧⌘ 顺序拆分返回独立键帽标签列表。
List<String> shortcutTokens(int modifiers, String label) => [
  if (modifiers & ShortcutKeys.control != 0) '⌃',
  if (modifiers & ShortcutKeys.option != 0) '⌥',
  if (modifiers & ShortcutKeys.shift != 0) '⇧',
  if (modifiers & ShortcutKeys.command != 0) '⌘',
  if (label.isNotEmpty) label,
];
