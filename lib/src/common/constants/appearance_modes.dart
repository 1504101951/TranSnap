import 'dart:ui';

abstract final class AppearanceModes {
  static const system = 'system';
  static const light = 'light';
  static const dark = 'dark';
  static const values = [system, light, dark];
  static const labels = {system: '跟随系统', light: '浅色', dark: '深色'};
}

abstract final class AppearanceKeys {
  static const accentLight = 'accentLight';
  static const accentDark = 'accentDark';
}

abstract final class AccentColors {
  static const system = 'system';
  static const blue = 'blue';
  static const purple = 'purple';
  static const pink = 'pink';
  static const orange = 'orange';
  static const green = 'green';
  static const graphite = 'graphite';
  static const values = [system, blue, purple, pink, orange, green, graphite];
  static const labels = {
    system: '跟随系统',
    blue: '晴空蓝',
    purple: '鸢尾紫',
    pink: '玫瑰',
    orange: '琥珀',
    green: '松石绿',
    graphite: '石墨',
  };

  static const swatches = <String, ({Color light, Color dark})>{
    blue: (light: Color(0xFF2F6FE4), dark: Color(0xFF4C8DFF)),
    purple: (light: Color(0xFF6E56CF), dark: Color(0xFF9B8AFB)),
    pink: (light: Color(0xFFC9356E), dark: Color(0xFFF06A97)),
    orange: (light: Color(0xFFC2560F), dark: Color(0xFFFF8F4D)),
    green: (light: Color(0xFF0B7F72), dark: Color(0xFF2EC4AE)),
    graphite: (light: Color(0xFF57606C), dark: Color(0xFFA3AAB4)),
  };

  static const customDarkLift = 0.35;

  static bool isCustom(String value) =>
      RegExp(r'^#[0-9A-F]{6}$').hasMatch(value);

  static String customValue(Color color) =>
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  static ({Color light, Color dark})? pairOf(String value) {
    final preset = swatches[value];
    if (preset != null) return preset;
    if (!isCustom(value)) return null;
    final light = Color(0xFF000000 | int.parse(value.substring(1), radix: 16));
    return (
      light: light,
      dark: Color.lerp(light, const Color(0xFFFFFFFF), customDarkLift)!,
    );
  }
}

abstract final class AccentForegrounds {
  static const auto = 'auto';
  static const white = 'white';
  static const black = 'black';
  static const values = [auto, white, black];
  static const labels = {auto: '自动', white: '白色', black: '黑色'};

  static const colors = <String, Color>{
    white: Color(0xFFFFFFFF),
    black: Color(0xFF1C1C1E),
  };

  static bool isValid(String value) =>
      values.contains(value) || AccentColors.isCustom(value);

  static Color? colorOf(String value) =>
      colors[value] ??
      (AccentColors.isCustom(value)
          ? Color(0xFF000000 | int.parse(value.substring(1), radix: 16))
          : null);
}
