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
