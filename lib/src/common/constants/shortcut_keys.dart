typedef Shortcut = ({String key, int modifiers, String label});

abstract final class ShortcutModifiers {
  static const control = 1;
  static const alt = 2;
  static const shift = 4;
  static const meta = 8;

  static const required = control | alt | meta;

  static const allowed = required | shift;

  static const names = {
    control: 'control',
    alt: 'alt',
    shift: 'shift',
    meta: 'meta',
  };

  static final _bits = {
    for (final MapEntry(:key, :value) in names.entries) value: key,
  };

  static int parse(List<Object?> list) =>
      list.fold(0, (modifiers, name) => modifiers | _bits[name]!);

  static List<String> encode(int modifiers) => [
    for (final MapEntry(:key, :value) in names.entries)
      if (modifiers & key != 0) value,
  ];
}

abstract final class ShortcutKeys {
  static const escape = 'Escape';

  static const Shortcut translate = (
    key: 'KeyT',
    modifiers: ShortcutModifiers.control | ShortcutModifiers.alt,
    label: 'T',
  );
  static const Shortcut input = (
    key: 'KeyR',
    modifiers: ShortcutModifiers.control | ShortcutModifiers.alt,
    label: 'R',
  );
  static const Shortcut screenshot = (
    key: 'KeyS',
    modifiers: ShortcutModifiers.control | ShortcutModifiers.alt,
    label: 'S',
  );

  static Shortcut? parse(Map<Object?, Object?>? map) => map == null
      ? null
      : (
          key: map['key']! as String,
          modifiers: ShortcutModifiers.parse(map['modifiers']! as List),
          label: map['label']! as String,
        );

  static Map<String, Object> encode(Shortcut shortcut) => {
    'key': shortcut.key,
    'modifiers': ShortcutModifiers.encode(shortcut.modifiers),
    'label': shortcut.label,
  };

  static const invalidMessage =
      '快捷键至少需要 Control、Option 或 Command，并搭配一个非 Esc 按键。';
}
