import 'dart:convert';

import 'translation_types.dart';

List<String> modelSourceParagraphs(String source) {
  final paragraphs = <String>[];
  var end = 0;
  for (final match in RegExp(r'\S[^\r\n]*').allMatches(source)) {
    paragraphs.add(source.substring(end, match.end));
    end = match.end;
  }
  if (paragraphs.isNotEmpty) {
    paragraphs[paragraphs.length - 1] += source.substring(end);
  }
  return paragraphs;
}

({String translation, List<TranslationPair> pairs}) parseModelResult(
  String text,
  String source,
) {
  var raw = text.trim();
  if (raw.startsWith('```') && raw.endsWith('```')) {
    final newline = raw.indexOf('\n');
    if (newline >= 0) raw = raw.substring(newline + 1, raw.length - 3).trim();
  }
  final decoded = jsonDecode(raw);
  final paragraphs = modelSourceParagraphs(source);
  final segments = decoded is Map ? decoded['segments'] : null;
  if (paragraphs.isEmpty ||
      segments is! List ||
      segments.length != paragraphs.length) {
    throw const FormatException('模型未返回完整的逐段译文，请重试。');
  }
  final pairs = <TranslationPair>[];
  for (var index = 0; index < paragraphs.length; index++) {
    final segment = segments[index];
    if (segment is! Map ||
        segment['id'] is! int ||
        segment['id'] != index ||
        segment['translation'] is! String ||
        (segment['translation'] as String).trim().isEmpty) {
      throw const FormatException('模型段落编号缺失、重复或顺序错误，请重试。');
    }
    pairs.add(
      pairParagraph(paragraphs[index], segment['translation'] as String),
    );
  }
  return (
    translation: pairs.map((pair) => pair.translation).join(),
    pairs: pairs,
  );
}

TranslationPair pairParagraph(String original, String translation) {
  final prefix = RegExp(r'^\s*').stringMatch(original)!;
  final suffix = RegExp(r'\s*$').stringMatch(original)!;
  return TranslationPair(original, prefix + translation.trim() + suffix);
}
