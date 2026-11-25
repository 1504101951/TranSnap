import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/shortcut_keys.dart';
import 'package:transnap/src/common/utils/shortcut_tokens.dart';

void main() {
  test('按 ⌃⌥⇧⌘ 顺序拆分修饰键并附加非空主键', () {
    expect(
      shortcutTokens(
        ShortcutKeys.command |
            ShortcutKeys.shift |
            ShortcutKeys.option |
            ShortcutKeys.control,
        'A',
      ),
      ['⌃', '⌥', '⇧', '⌘', 'A'],
    );
    expect(shortcutTokens(ShortcutKeys.option | ShortcutKeys.control, 'T'), [
      '⌃',
      '⌥',
      'T',
    ]);
    expect(shortcutTokens(0, 'F1'), ['F1']);
    expect(shortcutTokens(ShortcutKeys.command, ''), ['⌘']);
  });
}
