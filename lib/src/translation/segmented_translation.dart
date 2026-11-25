import 'dart:async';

import 'package:characters/characters.dart';

import 'translation_types.dart';

const translationSegmentTarget = 4000;
const translationSegmentMax = 6000;
const slidingContextChars = 1000;

List<String> splitTranslationSegments(String source) {
  const target = translationSegmentTarget;
  const max = translationSegmentMax;
  if (source.isEmpty) return const [];
  if (source.characters.length <= max) return [source];

  final packed = <String>[];
  final paragraphs = RegExp(r'[^\r\n]+|\r\n|\n|\r')
      .allMatches(source)
      .map((m) => m.group(0)!);
  var buffer = StringBuffer();
  var bufferChars = 0;

  void flush() {
    if (buffer.isEmpty) return;
    packed.add(buffer.toString());
    buffer = StringBuffer();
    bufferChars = 0;
  }

  for (final piece in paragraphs) {
    final pieceChars = piece.characters.length;
    if (piece.trim().isEmpty) {
      if (bufferChars + pieceChars > max) flush();
      if (pieceChars > max) {
        packed.addAll(_splitOversized(piece, max));
        continue;
      }
      buffer.write(piece);
      bufferChars += pieceChars;
      continue;
    }
    if (bufferChars > 0 && bufferChars + pieceChars <= target) {
      buffer.write(piece);
      bufferChars += pieceChars;
      continue;
    }
    if (bufferChars > 0 && bufferChars + pieceChars <= max) {
      buffer.write(piece);
      bufferChars += pieceChars;
      flush();
      continue;
    }
    flush();
    if (pieceChars <= max) {
      buffer.write(piece);
      bufferChars = pieceChars;
      if (bufferChars >= target) flush();
      continue;
    }
    for (final chunk in _splitOversized(piece, max)) {
      packed.add(chunk);
    }
  }
  flush();
  return packed;
}

Iterable<String> _splitOversized(String text, int max) sync* {
  final sentences = RegExp(r'[\s\S]+?(?:[。！？.!?]+|$)')
      .allMatches(text)
      .map((m) => m.group(0)!);
  var buffer = StringBuffer();
  var chars = 0;
  for (final sentence in sentences) {
    final len = sentence.characters.length;
    if (len > max) {
      if (buffer.isNotEmpty) {
        yield buffer.toString();
        buffer = StringBuffer();
        chars = 0;
      }
      final units = sentence.characters.toList();
      for (var i = 0; i < units.length; i += max) {
        yield units.skip(i).take(max).join();
      }
      continue;
    }
    if (chars + len > max && buffer.isNotEmpty) {
      yield buffer.toString();
      buffer = StringBuffer();
      chars = 0;
    }
    buffer.write(sentence);
    chars += len;
  }
  if (buffer.isNotEmpty) yield buffer.toString();
}

class TranslationProgress {
  TranslationProgress(this.request)
    : segments = splitTranslationSegments(request.sourceText);

  final TranslationRequest request;
  final List<String> segments;
  final List<TranslationPair> pairs = [];
  int nextIndex = 0;
  String completedText = '';
  String sourceTail = '';
  String translationTail = '';
}

Stream<TranslationEvent> translateSegmented(
  Stream<TranslationEvent> Function(TranslationRequest request) translate,
  TranslationRequest request, {
  bool usesSlidingContext = false,
  TranslationProgress? progress,
}) {
  final checkpoint = progress ?? TranslationProgress(request);
  if (!identical(checkpoint.request, request)) {
    throw ArgumentError('翻译检查点必须属于同一个请求。');
  }
  StreamIterator<TranslationEvent>? current;
  var cancelled = false;
  late StreamController<TranslationEvent> output;
  output = StreamController<TranslationEvent>(
    onCancel: () {
      cancelled = true;
      return current?.cancel();
    },
    onListen: () async {
      final segments = checkpoint.segments;
      if (segments.isEmpty) {
        output.add(const TranslationCompleted());
        await output.close();
        return;
      }

      try {
        for (var i = checkpoint.nextIndex; i < segments.length; i++) {
          if (cancelled) return;
          final segment = segments[i];
          final sliding = TranslationRequest(
            sourceText: segment,
            detectedLanguage: request.detectedLanguage,
            targetLanguage: request.targetLanguage,
            previousSourceTail: usesSlidingContext
                ? (i > 0 ? checkpoint.sourceTail : request.previousSourceTail)
                : null,
            previousTranslationTail: usesSlidingContext
                ? (i > 0
                      ? checkpoint.translationTail
                      : request.previousTranslationTail)
                : null,
          );
          current = StreamIterator(translate(sliding));
          var translated = '';
          var segmentCompleted = false;
          var segmentPairs = const <TranslationPair>[];
          while (await current!.moveNext()) {
            if (cancelled) return;
            final event = current!.current;
            switch (event) {
              case TranslationUpdate(:final addition):
                translated += addition;
                output.add(event);
              case TranslationCompleted(:final pairs):
                segmentCompleted = true;
                segmentPairs = pairs;
              case TranslationFailure():
                output.add(event);
                return;
            }
          }
          if (cancelled) return;
          if (!segmentCompleted) {
            output.add(const TranslationFailure(incompleteTranslationMessage));
            return;
          }
          if (segmentPairs.isEmpty) {
            segmentPairs = [TranslationPair(segment, translated)];
          }
          if (translated.isEmpty && segmentPairs.isNotEmpty) {
            translated = segmentPairs.map((pair) => pair.translation).join();
            if (translated.isNotEmpty) {
              output.add(TranslationUpdate(translated));
            }
          }
          checkpoint.pairs.addAll(segmentPairs);
          checkpoint.completedText += translated;
          checkpoint.sourceTail = _tail(segment);
          checkpoint.translationTail = _tail(translated);
          checkpoint.nextIndex = i + 1;
        }
        output.add(
          TranslationCompleted(pairs: List.unmodifiable(checkpoint.pairs)),
        );
      } catch (error) {
        if (!cancelled) output.add(TranslationFailure('翻译失败：$error'));
      } finally {
        await current?.cancel();
        await output.close();
      }
    },
  );
  return output.stream;
}

String _tail(String text) {
  final units = text.characters;
  if (units.length <= slidingContextChars) return text;
  return units.skip(units.length - slidingContextChars).join();
}
