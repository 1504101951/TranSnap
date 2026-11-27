import '../common/constants/preference_keys.dart';

typedef LanguageCandidate = ({String code, double? confidence});

typedef LanguageCandidates = ({
  List<LanguageCandidate> candidates,
  Set<String> unchangedScripts,
});

typedef LanguageCandidateSource = Future<LanguageCandidates> Function(
  String text,
  Map<String, double> hints,
);

abstract final class LanguageDetection {
  static const confidence = 0.5;
  static const baseWeight = 1.0;
  static const popularWeight = 3.0;
  static const englishWeight = 20.0;
  static const userWeight = 30.0;

  static const popular = {
    'en',
    'zh-Hans',
    'zh-Hant',
    'ja',
    'ko',
    'fr',
    'de',
    'es',
    'pt',
    'ru',
    'it',
  };

  static const all = {
    'am',
    'ar',
    'hy',
    'bn',
    'bg',
    'my',
    'ca',
    'chr',
    'hr',
    'cs',
    'da',
    'nl',
    'en',
    'fi',
    'fr',
    'ka',
    'de',
    'el',
    'gu',
    'he',
    'hi',
    'hu',
    'is',
    'id',
    'it',
    'ja',
    'kn',
    'kk',
    'km',
    'ko',
    'lo',
    'ms',
    'ml',
    'mr',
    'mn-Mong',
    'nb',
    'or',
    'fa',
    'pl',
    'pt',
    'pa-Guru',
    'ro',
    'ru',
    'zh-Hans',
    'si',
    'sk',
    'es',
    'sv',
    'ta',
    'te',
    'th',
    'bo',
    'zh-Hant',
    'tr',
    'uk',
    'ur',
    'vi',
  };

  static const latinLanguages = {
    'en',
    'fr',
    'de',
    'es',
    'pt',
    'it',
    'vi',
    'id',
    'nl',
    'tr',
  };

  static const userLanguageKeys = [
    PreferenceKeys.primaryLanguage,
    PreferenceKeys.secondaryLanguage,
    PreferenceKeys.inputPrimaryLanguage,
    PreferenceKeys.inputSecondaryLanguage,
  ];

  static List<String> preferred(Map<Object?, Object?> preferences) => [
    for (final key in userLanguageKeys)
      if (preferences[key] case final String code) code,
  ];

  static Future<String?> detect(
    String text,
    List<String> preferred,
    LanguageCandidateSource source,
  ) async => resolve(await source(text, hints(preferred)), text, preferred);

  static Map<String, double> hints(List<String> preferred) => {
    for (final code in all) code: baseWeight,
    for (final code in popular) code: popularWeight,
    'en': englishWeight,
    for (final code in preferred)
      if (all.contains(_hintCode(code))) _hintCode(code): userWeight,
  };

  static String? resolve(
    LanguageCandidates result,
    String text,
    List<String> preferred,
  ) {
    final ranked = result.candidates;
    if (ranked.isEmpty) return null;
    final top = ranked.first;
    final bases = {for (final code in preferred) _base(code)};
    final chosen = (top.confidence ?? confidence) >= confidence
        ? top.code
        : ranked
                  .where((candidate) => bases.contains(_base(candidate.code)))
                  .firstOrNull
                  ?.code ??
              _latinFallback(text, preferred) ??
              (popular.contains(top.code) ? top.code : null);
    if (chosen == null || _base(chosen) != 'zh') return chosen;
    final script = preferred.map(_chineseScript).nonNulls.firstOrNull;
    if (script == null) return chosen;
    return result.unchangedScripts.contains(script) ? 'zh-$script' : chosen;
  }

  static String? _latinFallback(String text, List<String> preferred) {
    if (text.codeUnits.any((unit) => unit > 0x7F) ||
        !_asciiLetter.hasMatch(text)) {
      return null;
    }
    final latin = {
      for (final code in preferred)
        if (latinLanguages.contains(_base(code))) _base(code),
    };
    return latin.length == 1 ? latin.single : null;
  }

  static final _asciiLetter = RegExp('[A-Za-z]');

  static String _base(String code) =>
      code.replaceAll('_', '-').split('-').first.toLowerCase();

  static String _hintCode(String code) {
    final script = _chineseScript(code);
    return script == null ? _base(code) : 'zh-$script';
  }

  static String? _chineseScript(String code) {
    if (_base(code) != 'zh') return null;
    final parts = code.replaceAll('_', '-').toLowerCase().split('-');
    return parts.any({'hant', 'tw', 'hk', 'mo'}.contains) ? 'Hant' : 'Hans';
  }
}
