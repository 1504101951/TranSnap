import 'dart:ui';

/// 持久化与跨引擎外观协议；Swift AppearanceMode 保持相同原始值。
abstract final class AppearanceModes {
  static const system = 'system';
  static const light = 'light';
  static const dark = 'dark';
  static const values = [system, light, dark];
  static const labels = {system: '跟随系统', light: '浅色', dark: '深色'};
}

/// 跨引擎外观快照中系统强调色的键；值为 sRGB ARGB 整数，分别在浅色、深色外观下解析，与 Swift AppConstants 同步（#142）。
abstract final class AppearanceKeys {
  static const accentLight = 'accentLight';
  static const accentDark = 'accentDark';
}

/// 强调色选项协议：跟随系统、6 种预设浅/深色阶或自定义 6 位 HEX（如 #2EA3D6）；默认跟随系统，
/// 与 Swift AppConstants.accentSwatches 同步（#144）。
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

  /// 预设色浅色值配白字 ≥ 4.5:1；深色值较亮，用于深色背景上的强调文字与描边，做实底时由 accentColorsFor 压暗以配白字（#144）。
  static const swatches = <String, ({Color light, Color dark})>{
    blue: (light: Color(0xFF2F6FE4), dark: Color(0xFF4C8DFF)),
    purple: (light: Color(0xFF6E56CF), dark: Color(0xFF9B8AFB)),
    pink: (light: Color(0xFFC9356E), dark: Color(0xFFF06A97)),
    orange: (light: Color(0xFFC2560F), dark: Color(0xFFFF8F4D)),
    green: (light: Color(0xFF0B7F72), dark: Color(0xFF2EC4AE)),
    graphite: (light: Color(0xFF57606C), dark: Color(0xFFA3AAB4)),
  };

  /// 自定义色深色外观值由浅色值向白混合的比例，与 Swift NativeGlassFactory.accentPair 一致（#144）。
  static const customDarkLift = 0.35;

  /// value 为偏好值；返回它是否为自定义 6 位 HEX（大写，带 #）。
  static bool isCustom(String value) =>
      RegExp(r'^#[0-9A-F]{6}$').hasMatch(value);

  /// color 为不透明 sRGB 颜色；返回保存用的自定义偏好值（#RRGGBB，大写）。
  static String customValue(Color color) =>
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  /// value 为偏好值；返回预设或自定义色的浅、深两套颜色，跟随系统或无法解析时为 null。
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

/// 强调色实底上的前景（图标线条与文字）偏好：自动、白色、黑色或自定义 #RRGGBB；默认自动，
/// 与 Swift AppConstants.accentForegroundKey 同步（#144）。
abstract final class AccentForegrounds {
  static const auto = 'auto';
  static const white = 'white';
  static const black = 'black';
  static const values = [auto, white, black];
  static const labels = {auto: '自动', white: '白色', black: '黑色'};

  /// 固定前景色：白色 #FFFFFF、黑色 #1C1C1E。
  static const colors = <String, Color>{
    white: Color(0xFFFFFFFF),
    black: Color(0xFF1C1C1E),
  };

  /// value 为偏好值；返回它是否为合法的前景偏好。
  static bool isValid(String value) =>
      values.contains(value) || AccentColors.isCustom(value);

  /// value 为偏好值；返回固定或自定义前景色，「自动」与无法解析时为 null。
  static Color? colorOf(String value) =>
      colors[value] ??
      (AccentColors.isCustom(value)
          ? Color(0xFF000000 | int.parse(value.substring(1), radix: 16))
          : null);
}
