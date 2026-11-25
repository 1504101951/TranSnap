import 'dart:async';

import 'language_direction.dart';
import 'translation_http.dart';
import 'translation_types.dart';

Stream<TranslationEvent> translateParagraphs(
  Stream<TranslationEvent> Function(TranslationRequest request) translate,
  TranslationRequest request,
) {
  StreamIterator<TranslationEvent>? current;
  var cancelled = false;
  late StreamController<TranslationEvent> output;
  output = StreamController<TranslationEvent>(
    onCancel: () {
      cancelled = true;
      return current?.cancel();
    },
    onListen: () async {
      final source = request.sourceText;
      final pairs = <TranslationPair>[];
      final sameLanguage = LanguageDirection.isTarget(
        request.detectedLanguage,
        request.targetLanguage,
      );
      var end = 0;
      try {
        final pattern = sameLanguage ? r'[^\r\n]+' : r'[\s\S]+';
        for (final match in RegExp(pattern).allMatches(source)) {
          if (cancelled) return;
          final paragraph = match.group(0)!;
          if (paragraph.trim().isEmpty) continue;
          final gap = source.substring(end, match.start);
          if (gap.isNotEmpty) output.add(TranslationUpdate(gap));
          var translated = '';
          var semanticPairs = const <TranslationPair>[];
          var completed = sameLanguage;
          if (sameLanguage) {
            translated = paragraph;
            output.add(TranslationUpdate(paragraph));
          } else {
            current = StreamIterator(
              translate(
                TranslationRequest(
                  sourceText: paragraph,
                  detectedLanguage: request.detectedLanguage,
                  targetLanguage: request.targetLanguage,
                  previousSourceTail: request.previousSourceTail,
                  previousTranslationTail: request.previousTranslationTail,
                ),
              ),
            );
            while (await current!.moveNext()) {
              if (cancelled) return;
              final event = current!.current;
              switch (event) {
                case TranslationUpdate(:final addition):
                  translated += addition;
                  output.add(event);
                case TranslationCompleted(:final pairs):
                  completed = true;
                  semanticPairs = pairs;
                case TranslationFailure():
                  output.add(event);
                  return;
              }
            }
            if (cancelled) return;
            if (!completed) {
              output.add(
                const TranslationFailure(incompleteTranslationMessage),
              );
              return;
            }
          }
          final paragraphPairs = semanticPairs.isEmpty
              ? [TranslationPair(paragraph, translated)]
              : semanticPairs;
          final first = paragraphPairs.first;
          pairs.add(
            TranslationPair(gap + first.source, gap + first.translation),
          );
          pairs.addAll(paragraphPairs.skip(1));
          end = match.end;
        }
        final tail = source.substring(end);
        if (tail.isNotEmpty) {
          output.add(TranslationUpdate(tail));
          if (pairs.isNotEmpty) {
            final last = pairs.removeLast();
            pairs.add(
              TranslationPair(last.source + tail, last.translation + tail),
            );
          }
        }
        output.add(TranslationCompleted(pairs: pairs));
      } catch (error, stack) {
        if (!cancelled) output.addError(error, stack);
      } finally {
        await current?.cancel();
        await output.close();
      }
    },
  );
  return output.stream;
}

Stream<TranslationEvent> translateParagraphBatches(
  BatchTranslationProvider provider,
  TranslationRequest request, {
  required int? maxItems,
  required int maxChars,
}) {
  StreamSubscription<BatchTranslationEvent>? current;
  var cancelled = false;
  late StreamController<TranslationEvent> output;
  output = StreamController<TranslationEvent>(
    onCancel: () {
      cancelled = true;
      return current?.cancel();
    },
    onListen: () async {
      final source = request.sourceText;
      final sameLanguage = LanguageDirection.isTarget(
        request.detectedLanguage,
        request.targetLanguage,
      );
      final paragraphs = [
        for (final match in RegExp(r'[^\r\n]+').allMatches(source))
          if (match.group(0)!.trim().isNotEmpty) match,
      ];
      final pairs = <TranslationPair>[];
      var end = 0;

      void publish(int index, String translation) {
        final match = paragraphs[index];
        final gap = source.substring(end, match.start);
        if (gap.isNotEmpty) output.add(TranslationUpdate(gap));
        output.add(TranslationUpdate(translation));
        pairs.add(TranslationPair(gap + match.group(0)!, gap + translation));
        end = match.end;
      }

      try {
        if (sameLanguage) {
          for (final (index, match) in paragraphs.indexed) {
            publish(index, match.group(0)!);
          }
        } else {
          var start = 0;
          while (start < paragraphs.length) {
            var stop = start;
            var chars = 0;
            while (stop < paragraphs.length &&
                (maxItems == null || stop - start < maxItems)) {
              final length = paragraphs[stop].group(0)!.length;
              if (stop > start && chars + length > maxChars) break;
              chars += length;
              stop++;
            }
            final texts = [
              for (final match in paragraphs.sublist(start, stop))
                match.group(0)!,
            ];
            final buffers = [for (final _ in texts) StringBuffer()];
            final done = Completer<String?>();

            void settle(String? message) {
              if (!done.isCompleted) done.complete(message);
            }

            current = provider
                .translateBatch(
                  BatchTranslationRequest(
                    texts: texts,
                    detectedLanguage: request.detectedLanguage,
                    targetLanguage: request.targetLanguage,
                    previousSourceTail: request.previousSourceTail,
                    previousTranslationTail: request.previousTranslationTail,
                  ),
                  client: translationHttpClient,
                )
                .listen(
                  (event) {
                    switch (event) {
                      case BatchItemUpdate(:final index, :final addition):
                        buffers[index].write(addition);
                      case BatchCompleted():
                        settle(null);
                      case BatchFailure(:final message):
                        settle(message);
                    }
                  },
                  onError: (Object _) => settle('翻译失败，请重试。'),
                  onDone: () => settle(incompleteTranslationMessage),
                );
            final failure = await done.future;
            await current?.cancel();
            current = null;
            if (cancelled) return;
            if (failure != null) {
              output.add(TranslationFailure(failure));
              return;
            }
            if (buffers.any((buffer) => buffer.toString().trim().isEmpty)) {
              output.add(
                const TranslationFailure(paragraphCountMismatchMessage),
              );
              return;
            }
            for (final (offset, buffer) in buffers.indexed) {
              publish(start + offset, buffer.toString());
            }
            start = stop;
          }
        }
        final tail = source.substring(end);
        if (tail.isNotEmpty) {
          output.add(TranslationUpdate(tail));
          if (pairs.isNotEmpty) {
            final last = pairs.removeLast();
            pairs.add(
              TranslationPair(last.source + tail, last.translation + tail),
            );
          }
        }
        output.add(TranslationCompleted(pairs: pairs));
      } catch (error, stack) {
        if (!cancelled) output.addError(error, stack);
      } finally {
        await current?.cancel();
        await output.close();
      }
    },
  );
  return output.stream;
}
