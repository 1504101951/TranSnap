abstract final class ShortcutKeys {
  static const command = 256;
  static const shift = 512;
  static const option = 2048;
  static const control = 4096;

  static const required = command | option | control;

  static const allowed = required | shift;

  static const escape = 53;

  static const maxKeyCode = 127;

  static const invalidMessage =
      '快捷键至少需要 Control、Option 或 Command，并搭配一个非 Esc 按键。';
}
