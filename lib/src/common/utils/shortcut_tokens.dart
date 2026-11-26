import '../constants/shortcut_keys.dart';

List<String> shortcutTokens(Shortcut shortcut) => [
  if (shortcut.modifiers & ShortcutModifiers.control != 0) '⌃',
  if (shortcut.modifiers & ShortcutModifiers.alt != 0) '⌥',
  if (shortcut.modifiers & ShortcutModifiers.shift != 0) '⇧',
  if (shortcut.modifiers & ShortcutModifiers.meta != 0) '⌘',
  if (shortcut.label.isNotEmpty) shortcut.label,
];
