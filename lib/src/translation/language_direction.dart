class LanguageDirection {
  const LanguageDirection({required this.primaryCode, this.secondaryCode});
  final String primaryCode;
  final String? secondaryCode;

  factory LanguageDirection.systemDefault({String? languageCode}) {
    final primary = normalize(languageCode ?? 'en');
    return LanguageDirection(
      primaryCode: primary,
      secondaryCode: primary == 'en' ? 'zh-CN' : 'en',
    );
  }

  ({String? detectedLanguage, String targetLanguage}) resolve(
    String? detected,
  ) {
    final code = detected == null ? null : normalize(detected);
    return (
      detectedLanguage: code,
      targetLanguage: code == normalize(primaryCode)
          ? secondaryCode ?? primaryCode
          : primaryCode,
    );
  }

  static bool isTarget(String? detected, String target) =>
      detected == normalize(target);

  static String normalize(String raw) {
    final parts = raw.replaceAll('_', '-').toLowerCase().split('-');
    if (parts.first != 'zh') return parts.first;
    return parts.contains('hant') ||
            parts.contains('tw') ||
            parts.contains('hk')
        ? 'zh-TW'
        : 'zh-CN';
  }
}
