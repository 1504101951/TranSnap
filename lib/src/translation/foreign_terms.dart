import 'language_direction.dart';

typedef ForeignSpan = ({int start, int end, String text});

abstract final class ForeignTerms {
  static const _latinTargets = {
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

  static const _cjkRange =
      r'\u3040-\u30FF\u3400-\u9FFF\uAC00-\uD7AF\uF900-\uFAFF\u{20000}-\u{3134F}';
  static const _latinLetter =
      r'A-Za-z\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u024F\u1E00-\u1EFF';

  static final _cjkRun = RegExp('[$_cjkRange]{2,}', unicode: true);
  static final _chunk = RegExp(
    '[^\\s$_cjkRange\\u3000-\\u303F\\uFF00-\\uFFEF]+',
    unicode: true,
  );
  static final _edges = RegExp(r'^[\p{P}\p{S}]+|[\p{P}\p{S}]+$', unicode: true);
  static final _codeLike = RegExp(r'[0-9_./@]');
  static final _word = RegExp(
    "[$_latinLetter]+(?:['’-][$_latinLetter]+)*",
    unicode: true,
  );
  static final _spaces = RegExp(r'^[ \t]+$');

  static List<ForeignSpan> spans(String text, String target) {
    final language = LanguageDirection.normalize(target);
    if (_latinTargets.contains(language)) {
      return [
        for (final match in _cjkRun.allMatches(text))
          (start: match.start, end: match.end, text: match[0]!),
      ];
    }
    final words = <({int start, int end, bool excluded})>[];
    for (final chunk in _chunk.allMatches(text)) {
      final core = chunk[0]!.replaceAll(_edges, '');
      final excluded = _codeLike.hasMatch(core);
      for (final word in _word.allMatches(chunk[0]!)) {
        words.add((
          start: chunk.start + word.start,
          end: chunk.start + word.end,
          excluded: excluded,
        ));
      }
    }
    final merged = <({int start, int end})>[];
    ({int start, int end, bool excluded})? previous;
    for (final word in words) {
      final joins =
          previous != null &&
          !previous.excluded &&
          !word.excluded &&
          _spaces.hasMatch(text.substring(previous.end, word.start));
      if (joins) {
        merged.last = (start: merged.last.start, end: word.end);
      } else if (!word.excluded) {
        merged.add((start: word.start, end: word.end));
      }
      previous = word;
    }
    return [
      for (final span in merged)
        if (text.substring(span.start, span.end).replaceAll(' ', '').length > 1)
          (
            start: span.start,
            end: span.end,
            text: text.substring(span.start, span.end),
          ),
    ];
  }

  static List<String> of(String text, String target) => [
    ...{for (final span in spans(text, target)) span.text},
  ];
}
