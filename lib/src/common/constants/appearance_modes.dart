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

/// 强调色选项协议与 6 种经典 macOS 浅/深色阶；默认跟随系统，与 Swift AppConstants 同步（#144）。
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
    blue: '蓝色',
    purple: '紫色',
    pink: '粉色',
    orange: '橙色',
    green: '绿色',
    graphite: '石墨色',
  };
  static const swatches = <String, ({Color light, Color dark})>{
    blue: (light: Color(0xFF007AFF), dark: Color(0xFF0A84FF)),
    purple: (light: Color(0xFF953D96), dark: Color(0xFFA550A7)),
    pink: (light: Color(0xFFF74F9E), dark: Color(0xFFFF5CA8)),
    orange: (light: Color(0xFFF7821B), dark: Color(0xFFFF8F24)),
    green: (light: Color(0xFF28A745), dark: Color(0xFF30D158)),
    graphite: (light: Color(0xFF8E8E93), dark: Color(0xFF98989D)),
  };
}
