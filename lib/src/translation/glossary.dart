import 'language_direction.dart';

class GlossaryEntry {
  const GlossaryEntry({
    required this.term,
    required this.translation,
    required this.language,
  });

  factory GlossaryEntry.fromMap(Map<Object?, Object?> map) => GlossaryEntry(
    term: map['term'] as String,
    translation: map['translation'] as String,
    language: map['language'] as String,
  );

  final String term;
  final String translation;
  final String language;

  static final _wordCharacter = RegExp('[A-Za-z0-9]');

  Map<String, String> toMap() => {
    'term': term,
    'translation': translation,
    'language': language,
  };

  (String, String) get key =>
      (term.toLowerCase(), LanguageDirection.normalize(language));

  bool occursIn(String text) {
    final before = _wordCharacter.hasMatch(term[0]) ? '(?<![A-Za-z0-9])' : '';
    final after = _wordCharacter.hasMatch(term[term.length - 1])
        ? '(?![A-Za-z0-9])'
        : '';
    return RegExp(
      '$before${RegExp.escape(term)}$after',
      caseSensitive: false,
    ).hasMatch(text);
  }
}

List<Map<String, String>> glossaryHits(
  List<GlossaryEntry> entries,
  Iterable<String> texts,
  String targetLanguage,
) {
  final target = LanguageDirection.normalize(targetLanguage);
  return [
    for (final entry in entries)
      if (LanguageDirection.normalize(entry.language) == target &&
          texts.any(entry.occursIn))
        {
          'term': entry.term,
          'translation': entry.translation.isEmpty
              ? entry.term
              : entry.translation,
        },
  ];
}
