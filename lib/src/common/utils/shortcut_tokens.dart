import '../constants/shortcut_keys.dart';

List<String> shortcutTokens(int modifiers, String label) => [
  if (modifiers & ShortcutKeys.control != 0) '⌃',
  if (modifiers & ShortcutKeys.option != 0) '⌥',
  if (modifiers & ShortcutKeys.shift != 0) '⇧',
  if (modifiers & ShortcutKeys.command != 0) '⌘',
  if (label.isNotEmpty) label,
];
