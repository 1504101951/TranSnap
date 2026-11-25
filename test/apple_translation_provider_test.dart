import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/channel_names.dart';
import 'package:transnap/src/common/constants/error_codes.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/translation/providers/apple_translation_provider.dart';
import 'package:transnap/src/translation/translation_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel(ChannelNames.platform);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AppleTranslationProvider provider;

  void nativeTranslate(Future<Object?> Function(List<String> texts) handler) {
    messenger.setMockMethodCallHandler(methods, (call) async {
      if (call.method == MethodNames.cancelSystemTranslation) return null;
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      return handler(List<String>.from(arguments['texts'] as List));
    });
  }

  setUp(() => provider = AppleTranslationProvider());
  tearDown(() => messenger.setMockMethodCallHandler(methods, null));

  test('多段原文按下标配对，译文保留原文的空行与首尾空白', () async {
    const source = '  Hello world.\n\nSecond line.  \n';
    nativeTranslate((texts) async => [for (final text in texts) '译:$text']);
    final events = await provider
        .translate(
          const TranslationRequest(
            sourceText: source,
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
        )
        .toList();
    final text = [
      for (final event in events)
        if (event is TranslationUpdate) event.addition,
    ].join();
    final pairs = (events.last as TranslationCompleted).pairs;
    expect(text, '  译:Hello world.\n\n译:Second line.  \n');
    expect(pairs.map((pair) => pair.source).join(), source);
    expect(pairs.map((pair) => pair.translation).join(), text);
    expect(pairs.map((pair) => pair.translation.trim()), [
      '译:Hello world.',
      '译:Second line.',
    ]);
  });

  test('段落分批：首批只含第一段，其后每批累计满 400 字符成批，余下段落成最后一批', () {
    expect(
      AppleTranslationProvider.paragraphBatches([
        'a' * 10,
        'b' * 100,
        'c' * 300,
        'd' * 399,
        'e' * 1,
        'f' * 5,
      ]),
      [
        [0],
        [1, 2],
        [3, 4],
        [5],
      ],
    );
    expect(AppleTranslationProvider.paragraphBatches(const []), isEmpty);
  });

  test('各批并发提交、至多 3 批在途，后面的批先完成时仍按原文顺序逐批输出', () async {
    final source = [
      'P0.',
      'P1 ${'x' * 400}',
      'P2 ${'y' * 400}',
      'P3 ${'z' * 400}',
    ].join('\n');
    final pending = <String, Completer<List<String>>>{};
    nativeTranslate((texts) {
      final completer = Completer<List<String>>();
      pending[texts.first.substring(0, 2)] = completer;
      return completer.future;
    });
    final updates = <String>[];
    final done = Completer<List<TranslationPair>>();
    provider
        .translate(
          TranslationRequest(
            sourceText: source,
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
        )
        .listen((event) {
          if (event is TranslationUpdate) updates.add(event.addition);
          if (event is TranslationCompleted) done.complete(event.pairs);
        });
    await pumpEventQueue();
    expect(pending.keys, unorderedEquals(['P0', 'P1', 'P2']));
    pending['P1']!.complete(['译1']);
    await pumpEventQueue();
    expect(updates, isEmpty);
    expect(pending.keys, contains('P3'));
    pending['P0']!.complete(['译0']);
    await pumpEventQueue();
    expect(updates, ['译0', '\n译1']);
    pending['P3']!.complete(['译3']);
    pending['P2']!.complete(['译2']);
    final pairs = await done.future;
    expect(updates.join(), '译0\n译1\n译2\n译3');
    expect(pairs.map((pair) => pair.source).join(), source);
  });

  test('任一批失败即输出失败、取消其余在途批次且不再输出完成', () async {
    final source = ['P0.', 'P1 ${'x' * 400}', 'P2 ${'y' * 400}'].join('\n');
    final cancelled = <String>[];
    final pending = <String, Completer<List<String>>>{};
    messenger.setMockMethodCallHandler(methods, (call) async {
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      if (call.method == MethodNames.cancelSystemTranslation) {
        cancelled.add(arguments['requestId'] as String);
        return null;
      }
      final texts = List<String>.from(arguments['texts'] as List);
      final completer = Completer<List<String>>();
      pending[texts.first.substring(0, 2)] = completer;
      return completer.future;
    });
    final events = <TranslationEvent>[];
    final closed = Completer<void>();
    provider
        .translate(
          TranslationRequest(
            sourceText: source,
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
        )
        .listen(events.add, onDone: closed.complete);
    await pumpEventQueue();
    pending['P1']!.completeError(
      PlatformException(code: ErrorCodes.translationUnsupported),
    );
    await pumpEventQueue();
    expect(cancelled, hasLength(2));
    pending['P0']!.complete(['译0']);
    pending['P2']!.complete(['译2']);
    await closed.future;
    expect(events.whereType<TranslationCompleted>(), isEmpty);
    expect(events.whereType<TranslationFailure>(), hasLength(1));
  });

  test('原文语言无法识别时直接失败，单篇与批量文案一致且批量按单段放弃', () async {
    nativeTranslate((_) async => throw StateError('原文语言未知时不应进入原生翻译'));
    final single = await provider
        .translate(
          const TranslationRequest(
            sourceText: 'Bonjour',
            targetLanguage: 'zh-CN',
          ),
        )
        .toList();
    expect((single.single as TranslationFailure).message, '无法识别原文语言。');
    final client = HttpClient();
    addTearDown(client.close);
    final batch = await provider
        .translateBatch(
          const BatchTranslationRequest(
            texts: ['Bonjour'],
            targetLanguage: 'zh-CN',
          ),
          client: client,
        )
        .toList();
    final failure = batch.single as BatchFailure;
    expect(failure.message, '无法识别原文语言。');
    expect(failure.kind, TranslationFailureKind.paragraph);
  });

  test('语言包未安装时提示缺少的语言对与下载位置，实时翻译只放弃该段', () async {
    nativeTranslate(
      (_) async =>
          throw PlatformException(code: ErrorCodes.translationNotInstalled),
    );
    const message = '缺少「English → 简体中文」语言包，请到「系统设置 → 通用 → 语言与地区 → 翻译语言」下载。';
    final single = await provider
        .translate(
          const TranslationRequest(
            sourceText: 'Hello',
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
        )
        .toList();
    expect((single.single as TranslationFailure).message, message);
    final client = HttpClient();
    addTearDown(client.close);
    final batch = await provider
        .translateBatch(
          const BatchTranslationRequest(
            texts: ['Hello'],
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
          client: client,
        )
        .toList();
    final failure = batch.single as BatchFailure;
    expect(failure.message, message);
    expect(failure.kind, TranslationFailureKind.paragraph);
  });

  test('不支持的语言对为段落级失败，其余原生错误为可重试的临时失败', () async {
    final client = HttpClient();
    addTearDown(client.close);
    nativeTranslate(
      (_) async =>
          throw PlatformException(code: ErrorCodes.translationUnsupported),
    );
    final unsupported = await provider
        .translateBatch(
          const BatchTranslationRequest(
            texts: ['简体'],
            detectedLanguage: 'zh-CN',
            targetLanguage: 'zh-TW',
          ),
          client: client,
        )
        .toList();
    final rejected = unsupported.single as BatchFailure;
    expect(rejected.message, 'Apple 系统翻译不支持「简体中文 → 繁體中文」。');
    expect(rejected.kind, TranslationFailureKind.paragraph);

    nativeTranslate(
      (_) async => throw PlatformException(code: ErrorCodes.translateFailed),
    );
    final failed = await provider
        .translateBatch(
          const BatchTranslationRequest(
            texts: ['Hello'],
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
          client: client,
        )
        .toList();
    final transient = failed.single as BatchFailure;
    expect(transient.message, 'Apple 系统翻译失败，请重试。');
    expect(transient.kind, TranslationFailureKind.transient);
  });

  test('实时翻译批量按下标发布各段译文后整批完成', () async {
    nativeTranslate((texts) async => [for (final text in texts) '$text!']);
    final client = HttpClient();
    addTearDown(client.close);
    final events = await provider
        .translateBatch(
          const BatchTranslationRequest(
            texts: ['a', 'b', 'c'],
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
          client: client,
        )
        .toList();
    expect(events.last, isA<BatchCompleted>());
    expect(
      [
        for (final event in events.whereType<BatchItemUpdate>())
          (event.index, event.addition),
      ],
      [(0, 'a!'), (1, 'b!'), (2, 'c!')],
    );
  });

  test('取消订阅后迟到的原生译文不再输出', () async {
    final reply = Completer<List<String>>();
    final requested = Completer<void>();
    nativeTranslate((_) {
      requested.complete();
      return reply.future;
    });
    final client = HttpClient();
    addTearDown(client.close);
    final received = <BatchTranslationEvent>[];
    final subscription = provider
        .translateBatch(
          const BatchTranslationRequest(
            texts: ['Hello'],
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
          client: client,
        )
        .listen(received.add);
    await requested.future;
    await subscription.cancel();
    reply.complete(['你好']);
    await pumpEventQueue();
    expect(received, isEmpty);
  });
}
