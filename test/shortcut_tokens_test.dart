import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/shortcut_keys.dart';
import 'package:transnap/src/common/utils/shortcut_tokens.dart';

void main() {
  test('按 ⌃⌥⇧⌘ 顺序拆分修饰键并附加非空主键', () {
    expect(
      shortcutTokens((
        key: 'KeyA',
        modifiers: ShortcutModifiers.allowed,
        label: 'A',
      )),
      ['⌃', '⌥', '⇧', '⌘', 'A'],
    );
    expect(shortcutTokens(ShortcutKeys.translate), ['⌃', '⌥', 'T']);
    expect(shortcutTokens((key: 'F1', modifiers: 0, label: 'F1')), ['F1']);
    expect(
      shortcutTokens((key: 'KeyA', modifiers: ShortcutModifiers.meta, label: '')),
      ['⌘'],
    );
  });

  test('修饰键名称与位互转：按 control、alt、shift、meta 顺序输出，未知名称报错', () {
    expect(
      ShortcutModifiers.encode(ShortcutModifiers.meta | ShortcutModifiers.control),
      ['control', 'meta'],
    );
    expect(ShortcutModifiers.encode(0), isEmpty);
    expect(
      ShortcutModifiers.parse(['meta', 'shift']),
      ShortcutModifiers.meta | ShortcutModifiers.shift,
    );
    expect(() => ShortcutModifiers.parse(['command']), throwsA(isA<TypeError>()));
    expect(ShortcutKeys.parse(null), isNull);
    expect(
      ShortcutKeys.parse(ShortcutKeys.encode(ShortcutKeys.screenshot)),
      ShortcutKeys.screenshot,
    );
  });
}
