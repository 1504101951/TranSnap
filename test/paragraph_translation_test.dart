import 'dart:async';
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/translation/paragraph_translation.dart';
import 'package:transnap/src/translation/segmented_translation.dart';
import 'package:transnap/src/translation/translation_types.dart';

class _Provider implements TranslationProvider {
  _Provider(this.responses);

  final Map<String, Stream<TranslationEvent>> responses;

  @override
  String get id => 'paragraph-test';
  @override
  bool get usesSlidingContext => false;

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) =>
      responses[request.sourceText] ??
      (throw StateError('Unexpected paragraph: ${request.sourceText}'));
}

class _BatchProvider implements BatchTranslationProvider {
  _BatchProvider([this.reply]);

  final List<BatchTranslationEvent> Function(BatchTranslationRequest request)?
  reply;
  final requests = <BatchTranslationRequest>[];

  @override
  String get id => 'batch-test';
  @override
  bool get usesSlidingContext => false;
  @override
  bool get allowsParallelBatches => false;

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) =>
      throw StateError('single request is not expected');

  @override
  Stream<BatchTranslationEvent> translateBatch(
    BatchTranslationRequest request, {
    required HttpClient client,
  }) {
    requests.add(request);
    return Stream.fromIterable(
      reply?.call(request) ??
          [
            for (final (index, text) in request.texts.indexed)
              BatchItemUpdate(index, '译$text'),
            const BatchCompleted(),
          ],
    );
  }
}

void main() {
  test('按段落分批：段落数与字符数上限先到为准，超长段自成一批，分隔符与配对保持原文顺序（#113）', () async {
    final lines = [
      for (var i = 0; i < 25; i++) 'line-${i.toString().padLeft(4, '0')}',
    ];
    final source =
        '${lines.take(2).join('\n\n')}\n${lines.skip(2).join('\n')}\n';
    final byCount = _BatchProvider();
    final events = await translateParagraphBatches(
      byCount,
      TranslationRequest(
        sourceText: source,
        detectedLanguage: 'en',
        targetLanguage: 'zh-CN',
        previousSourceTail: '前一片原文',
        previousTranslationTail: '前一片译文',
      ),
      maxItems: 20,
      maxChars: 5000,
    ).toList();
    expect(byCount.requests.map((request) => request.texts.length), [20, 5]);
    expect(
      byCount.requests.map((request) => request.previousSourceTail).toSet(),
      {'前一片原文'},
    );
    final expected =
        '${lines.take(2).map((line) => '译$line').join('\n\n')}\n'
        '${lines.skip(2).map((line) => '译$line').join('\n')}\n';
    expect(
      events
          .whereType<TranslationUpdate>()
          .map((event) => event.addition)
          .join(),
      expected,
    );
    final pairs = (events.last as TranslationCompleted).pairs;
    expect(pairs.map((pair) => pair.source).join(), source);
    expect(pairs.map((pair) => pair.translation).join(), expected);

    final byChars = _BatchProvider();
    await translateParagraphBatches(
      byChars,
      TranslationRequest(
        sourceText:
            'aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc\n${'d' * 30}\neeeeeeeeee',
        detectedLanguage: 'en',
        targetLanguage: 'zh-CN',
      ),
      maxItems: null,
      maxChars: 25,
    ).toList();
    expect(byChars.requests.map((request) => request.texts.length), [
      2,
      1,
      1,
      1,
    ]);
  });

  test('批量有段落没有译文或整批失败时整片失败，后续批次不再请求；同语言不发请求（#113）', () async {
    const request = TranslationRequest(
      sourceText: 'A\nB\nC',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
    );
    final missing = _BatchProvider(
      (_) => [const BatchItemUpdate(0, '甲'), const BatchCompleted()],
    );
    final mismatched = await translateParagraphBatches(
      missing,
      request,
      maxItems: 2,
      maxChars: 100,
    ).toList();
    expect(
      (mismatched.single as TranslationFailure).message,
      '服务返回的段落数与原文不一致，请重试。',
    );
    expect(missing.requests, hasLength(1));
    final failing = _BatchProvider(
      (_) => [const BatchFailure('认证失败', TranslationFailureKind.service)],
    );
    final failed = await translateParagraphBatches(
      failing,
      request,
      maxItems: 2,
      maxChars: 100,
    ).toList();
    expect((failed.single as TranslationFailure).message, '认证失败');
    expect(failing.requests, hasLength(1));
    final same = _BatchProvider();
    final passthrough = await translateParagraphBatches(
      same,
      const TranslationRequest(
        sourceText: '你好\n世界',
        detectedLanguage: 'zh-CN',
        targetLanguage: 'zh-CN',
      ),
      maxItems: 2,
      maxChars: 100,
    ).toList();
    expect(same.requests, isEmpty);
    expect(
      passthrough
          .whereType<TranslationUpdate>()
          .map((event) => event.addition)
          .join(),
      '你好\n世界',
    );
  });

  test(
    'semantic models retain full source context and validated pairs',
    () async {
      const source = 'First.\nSecond.';
      final events = await translateParagraphs(
        _Provider({
          source: Stream.fromIterable([
            const TranslationUpdate('第一段。\n第二段。'),
            const TranslationCompleted(
              pairs: [
                TranslationPair('First.', '第一段。'),
                TranslationPair('\nSecond.', '\n第二段。'),
              ],
            ),
          ]),
        }).translate,
        const TranslationRequest(
          sourceText: source,
          detectedLanguage: 'en',
          targetLanguage: 'zh-CN',
        ),
      ).toList();
      expect(
        (events.last as TranslationCompleted).pairs.map((e) => e.source).join(),
        source,
      );
      expect((events.last as TranslationCompleted).pairs, hasLength(2));
    },
  );
  test('整片请求保留 CRLF、空段与末尾换行，服务未给配对时整片作为一组对照', () async {
    const source = 'First one. First two.\r\n\r\nSecond.\n';
    final events = await translateParagraphs(
      _Provider({
        source: Stream.fromIterable([
          const TranslationUpdate('第一句。第二句。\r\n\r\n'),
          const TranslationUpdate('第二段。\n'),
          const TranslationCompleted(),
        ]),
      }).translate,
      const TranslationRequest(
        sourceText: source,
        detectedLanguage: 'en',
        targetLanguage: 'zh-CN',
      ),
    ).toList();
    expect(
      events.whereType<TranslationUpdate>().map((e) => e.addition).join(),
      '第一句。第二句。\r\n\r\n第二段。\n',
    );
    final pairs = (events.last as TranslationCompleted).pairs;
    expect(pairs.map((e) => (e.source, e.translation)), [
      (source, '第一句。第二句。\r\n\r\n第二段。\n'),
    ]);
  });

  test('整片请求先给出部分译文后失败时以失败结束，不标记完成', () async {
    final events = await translateParagraphs(
      _Provider({
        'First.\nSecond.': Stream.fromIterable([
          const TranslationUpdate('第一段。'),
          const TranslationFailure('服务不可用'),
        ]),
      }).translate,
      const TranslationRequest(
        sourceText: 'First.\nSecond.',
        targetLanguage: 'zh-CN',
      ),
    ).toList();
    expect((events.last as TranslationFailure).message, '服务不可用');
    expect(events.whereType<TranslationCompleted>(), isEmpty);
    expect(
      events.whereType<TranslationUpdate>().map((e) => e.addition).join(),
      '第一段。',
    );
  });

  test('text already in the target language keeps exact content', () async {
    const source = '  第一段。\n\n第二段。\n ';
    final events = await translateParagraphs(
      _Provider({}).translate,
      const TranslationRequest(
        sourceText: source,
        detectedLanguage: 'zh-CN',
        targetLanguage: 'zh-CN',
      ),
    ).toList();
    expect(
      events.whereType<TranslationUpdate>().map((e) => e.addition).join(),
      source,
    );
    expect((events.last as TranslationCompleted).pairs, hasLength(2));
  });

  test(
    'cancellation stops the in-flight request without waiting for it',
    () async {
      final pending = StreamController<TranslationEvent>();
      final received = Completer<void>();
      final output = <TranslationEvent>[];
      final subscription =
          translateParagraphs(
            _Provider({'First.\nSecond.': pending.stream}).translate,
            const TranslationRequest(
              sourceText: 'First.\nSecond.',
              targetLanguage: 'zh-CN',
            ),
          ).listen((event) {
            output.add(event);
            received.complete();
          });
      pending.add(const TranslationUpdate('部分译文'));
      await received.future;
      await subscription.cancel().timeout(const Duration(seconds: 3));
      await pending.close();
      expect(output, hasLength(1));
      expect((output.single as TranslationUpdate).addition, '部分译文');
    },
  );

  test('长文按 4000/6000 分包，超长段先句再硬切', () {
    final short = 'a' * 5000;
    expect(splitTranslationSegments(short), [short]);
    final packed = '${'p' * 3500}\n${'q' * 2000}';
    expect(splitTranslationSegments(packed), [packed]);
    final two = '${'a' * 4000}\n${'b' * 4000}';
    expect(splitTranslationSegments(two).length, 2);
    final hugeSentence = 'word ' * 2000;
    final chunks = splitTranslationSegments(hugeSentence);
    expect(chunks.length, greaterThan(1));
    expect(chunks.every((c) => c.characters.length <= 6000), isTrue);
    expect(chunks.join(), hugeSentence);
  });

  test('分段串行、模型带 1000 字尾部，Google 不带；失败可从失败片续翻', () async {
    final first = 'A' * 4000;
    final second = 'B' * 4000;
    final source = '$first\n$second';
    final seen = <TranslationRequest>[];
    Stream<TranslationEvent> translate(TranslationRequest request) {
      seen.add(request);
      if (request.sourceText.contains('B') && seen.length == 2) {
        return Stream.value(const TranslationFailure('第二片失败'));
      }
      return Stream.fromIterable([
        TranslationUpdate('T-${request.sourceText.trimLeft()[0]}'),
        const TranslationCompleted(),
      ]);
    }

    final request = TranslationRequest(
      sourceText: source,
      targetLanguage: 'zh-CN',
    );
    final progress = TranslationProgress(request);
    final failed = await translateSegmented(
      translate,
      request,
      progress: progress,
      usesSlidingContext: true,
    ).toList();
    expect(failed.last, isA<TranslationFailure>());
    expect(failed.whereType<TranslationUpdate>().map((e) => e.addition), [
      'T-A',
    ]);
    expect(seen, hasLength(2));
    expect(seen.first.previousSourceTail, isNull);
    expect(seen[1].previousSourceTail, first.substring(first.length - 1000));
    expect(seen[1].previousTranslationTail, 'T-A');

    seen.clear();
    Stream<TranslationEvent> google(TranslationRequest request) {
      seen.add(request);
      return Stream.fromIterable([
        TranslationUpdate('G-${request.sourceText[0]}'),
        const TranslationCompleted(),
      ]);
    }

    await translateSegmented(
      google,
      TranslationRequest(sourceText: source, targetLanguage: 'zh-CN'),
    ).toList();
    expect(seen.every((r) => r.previousSourceTail == null), isTrue);

    seen.clear();
    final resumed = await translateSegmented(
      translate,
      request,
      usesSlidingContext: true,
      progress: progress,
    ).toList();
    expect(resumed.last, isA<TranslationCompleted>());
    expect(seen.single.sourceText.contains('B'), isTrue);
    expect(
      seen.single.previousSourceTail,
      first.substring(first.length - 1000),
    );
    expect(seen.single.previousTranslationTail, 'T-A');
    expect(progress.completedText, 'T-AT-B');
    expect(
      (resumed.last as TranslationCompleted).pairs.map((p) => p.source).join(),
      source,
    );
  });
}
