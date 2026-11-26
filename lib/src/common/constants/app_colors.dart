import 'dart:ui';

abstract final class SystemHues {
  static const blue = Color(0xFF007AFF);
  static const blueDark = Color(0xFF0A84FF);
  static const purple = Color(0xFFAF52DE);
  static const orange = Color(0xFFFF9500);
  static const green = Color(0xFF34C759);
}

abstract final class AppColors {
  static const ink = Color(0xFF1C1C1E);

  static Color panel(bool dark) =>
      dark ? const Color(0xFF2A2A2D) : const Color(0xFFFBFBFC);

  static Color tray(bool dark) =>
      dark ? const Color(0xFF1D1D1F) : const Color(0xFFECECED);

  static Color card(bool dark) =>
      dark ? const Color(0xFF232326) : const Color(0xFFFFFFFF);

  static Color error(bool dark) =>
      dark ? const Color(0xFFFF6961) : const Color(0xFFB3261E);

  static Color warning(bool dark) =>
      dark ? const Color(0xFFFF9F0A) : const Color(0xFF8A4A00);
}
