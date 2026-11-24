import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/shortcut_keys.dart';
import 'package:transnap/src/common/utils/shortcut_tokens.dart';

/// 无参数；验证键帽拆分的修饰键顺序与边界输入。
void main() {
  test('按 ⌃⌥⇧⌘ 顺序拆分修饰键并附加非空主键', () {
    // 作用：验证设置页与历史空状态共用的键帽序列生成逻辑。
    // 边界：覆盖全修饰键掩码、无修饰键与空主键。
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
