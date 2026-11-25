import 'package:transnap/src/common/constants/selection_gesture_types.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/bridge_event_types.dart';

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:transnap/src/common/constants/text_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/widgets/app_tooltip.dart';
import 'package:transnap/src/overlay/translation_overlay.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:transnap/src/selection/selection_translation_app.dart'
    show TranSnapApp;
import 'package:transnap/src/history/translation_history.dart';
import 'package:transnap/src/history/vocabulary.dart';
import 'package:transnap/src/platform/channel_platform_bridge.dart';
import 'package:transnap/src/selection/selection_session.dart';
import 'package:transnap/src/translation/language_direction.dart';
import 'package:transnap/src/translation/translation_types.dart';

class _Provider extends TranslationProvider {
  _Provider(this.id, this.events);
  @override
  final String id;
  final Stream<TranslationEvent> events;

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) => events;
}

void main() {
  testWidgets('选区历史保留来源和激活配置，失败、未完成与关闭不写记录', (tester) async {
    const methods = MethodChannel('test/selection-history/methods');
    const events = EventChannel('test/selection-history/events');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (_) async => null);
    messenger.setMockMethodCallHandler(
      MethodChannel(events.name),
      (_) async => null,
    );
    final database = sqlite3.openInMemory();
    final history = TranslationHistoryStore(database);
    final detection = Completer<String?>();
    final session = SelectionSession(
      provider: _Provider(
        'original',
        Stream.fromIterable([
          const TranslationUpdate('Hello'),
          const TranslationCompleted(),
        ]),
      ),
      detectLanguage: (_) => detection.future,
      language: const LanguageDirection(
        primaryCode: 'zh-CN',
        secondaryCode: 'en',
      ),
    );
    addTearDown(() {
      session.dispose();
      database.close();
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(MethodChannel(events.name), null);
    });
    final bridge = ChannelPlatformBridge(methods: methods, events: events);
    await tester.pumpWidget(
      TranSnapApp(
        selection: bridge,
        overlay: bridge,
        speech: bridge,
        perf: bridge,
        session: session,
        history: history,
        vocabulary: VocabularyStore(database),
      ),
    );
    await tester.pump();

    Future<void> send(Map<String, Object> payload) async {
      await messenger.handlePlatformMessage(
        events.name,
        codec.encodeSuccessEnvelope(payload),
        (_) {},
      );
      await tester.pump();
    }

    await send({
      'type': BridgeEventTypes.selectionCaptured,
      'sessionId': 'success',
      'gesture': SelectionGestureTypes.hotkey,
      'text': '你好',
      'sourceAppName': 'Safari',
      'x': 0,
      'y': 0,
    });
    expect(session.snapshot.phase, TranslationPhase.translating);
    session.provider = _Provider('changed', const Stream.empty());
    session.language = const LanguageDirection(primaryCode: 'fr');
    detection.complete('zh-Hans');
    await tester.pumpAndSettle();
    expect(
      session.snapshot.phase,
      TranslationPhase.completed,
      reason: session.snapshot.message,
    );
    expect(history.page(), hasLength(1));
    final row = history.page().single;
    expect(row.sourceLabel, 'Safari');
    expect(row.targetLanguage, 'en');
    expect(row.providerId, 'original');
    expect(row.translatedText, 'Hello');
    for (final ending in ['failed', 'incomplete', 'cancelled']) {
      final stream = StreamController<TranslationEvent>();
      session.provider = _Provider(ending, stream.stream);
      await send({
        'type': BridgeEventTypes.selectionCaptured,
        'sessionId': ending,
        'gesture': SelectionGestureTypes.hotkey,
        'text': 'Other',
        'sourceAppName': 'Notes',
        'x': 0,
        'y': 0,
      });
      stream.add(const TranslationUpdate('部分'));
      if (ending == 'failed') stream.add(const TranslationFailure('翻译失败'));
      if (ending == 'cancelled') {
        await send({'type': MethodNames.escapePressed, 'sessionId': ending});
      }
      unawaited(stream.close());
      await tester.pumpAndSettle();
      expect(
        session.snapshot.phase,
        ending == 'cancelled' ? TranslationPhase.idle : TranslationPhase.failed,
      );
      expect(history.page(), hasLength(1));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入翻译全程不显示卡片：成功替换后结束会话，未替换时把原因交给失败气泡（#99）', (tester) async {
    const methods = MethodChannel('test/input-translation/methods');
    const events = EventChannel('test/input-translation/events');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? replaceFailure;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return call.method == MethodNames.replaceSelection
          ? replaceFailure
          : null;
    });
    messenger.setMockMethodCallHandler(
      MethodChannel(events.name),
      (_) async => null,
    );
    final database = sqlite3.openInMemory();
    final history = TranslationHistoryStore(database);
    final session = SelectionSession(
      provider: _Provider(
        'input',
        Stream.fromIterable([
          const TranslationUpdate('Hello'),
          const TranslationCompleted(),
        ]),
      ),
      detectLanguage: (_) async => 'zh-Hans',
      language: const LanguageDirection(
        primaryCode: 'zh-CN',
        secondaryCode: 'en',
      ),
    );
    addTearDown(() {
      session.dispose();
      database.close();
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(MethodChannel(events.name), null);
    });
    final bridge = ChannelPlatformBridge(methods: methods, events: events);
    await tester.pumpWidget(
      TranSnapApp(
        selection: bridge,
        overlay: bridge,
        speech: bridge,
        perf: bridge,
        session: session,
        history: history,
        vocabulary: VocabularyStore(database),
      ),
    );
    await tester.pump();

    Future<void> sendInput(String sessionId) async {
      await messenger.handlePlatformMessage(
        events.name,
        codec.encodeSuccessEnvelope({
          'type': BridgeEventTypes.selectionCaptured,
          'sessionId': sessionId,
          'gesture': SelectionGestureTypes.inputHotkey,
          'text': '你好',
          'sourceAppName': 'Notes',
          'x': 0,
          'y': 0,
        }),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    Set<String> methodNames() => calls.map((call) => call.method).toSet();

    await sendInput('replaced');
    expect(session.snapshot.phase, TranslationPhase.idle);
    expect(history.page(), hasLength(1));
    expect(
      methodNames(),
      isNot(
        anyOf(
          contains(MethodNames.showOverlay),
          contains(MethodNames.setOverlaySize),
          contains(MethodNames.showInputFailure),
        ),
      ),
    );

    calls.clear();
    replaceFailure = '来源应用已切换，未替换原文。';
    await sendInput('kept');
    expect(session.snapshot.phase, TranslationPhase.idle);
    expect(history.page(), hasLength(2));
    expect(methodNames(), isNot(contains(MethodNames.showOverlay)));
    final failure = calls.singleWhere(
      (call) => call.method == MethodNames.showInputFailure,
    );
    expect(failure.arguments, {
      'sessionId': 'kept',
      'message': '来源应用已切换，未替换原文。',
    });
    expect(tester.takeException(), isNull);
  });
  testWidgets('卡片切换为润色只显示结果不写历史，切回翻译成功后再记录一条', (tester) async {
    const methods = MethodChannel('test/mode-history/methods');
    const events = EventChannel('test/mode-history/events');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (_) async => null);
    messenger.setMockMethodCallHandler(
      MethodChannel(events.name),
      (_) async => null,
    );
    final database = sqlite3.openInMemory();
    final history = TranslationHistoryStore(database);
    final session =
        SelectionSession(
            provider: _Provider(
              'translate',
              Stream.fromIterable([
                const TranslationUpdate('你好'),
                const TranslationCompleted(),
              ]),
            ),
            detectLanguage: (_) async => 'en',
            language: const LanguageDirection(primaryCode: 'zh-CN'),
          )
          ..assistProviderFor = (_) => _Provider(
            'polish',
            Stream.fromIterable([
              const TranslationUpdate('Hello.'),
              const TranslationCompleted(),
            ]),
          );
    addTearDown(() {
      session.dispose();
      database.close();
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(MethodChannel(events.name), null);
    });
    final bridge = ChannelPlatformBridge(methods: methods, events: events);
    await tester.pumpWidget(
      TranSnapApp(
        selection: bridge,
        overlay: bridge,
        speech: bridge,
        perf: bridge,
        session: session,
        history: history,
        vocabulary: VocabularyStore(database),
      ),
    );
    await tester.pump();
    await messenger.handlePlatformMessage(
      events.name,
      codec.encodeSuccessEnvelope({
        'type': BridgeEventTypes.selectionCaptured,
        'sessionId': 'mode',
        'gesture': SelectionGestureTypes.hotkey,
        'text': 'hello',
        'sourceAppName': 'Notes',
        'x': 0,
        'y': 0,
      }),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(history.page(), hasLength(1));

    Future<void> choose(TextMode mode) async {
      await tester.tap(find.byKey(const ValueKey('card-mode-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(TranslationOverlay.modeLabels[mode]!).last);
      await tester.pumpAndSettle();
    }

    await choose(TextMode.polish);
    expect(session.snapshot.translatedText, 'Hello.');
    expect(
      find.byWidgetPredicate((w) => w is AppTooltip && w.message == '复制润色'),
      findsOneWidget,
    );
    expect(history.page(), hasLength(1));
    await choose(TextMode.translate);
    expect(session.snapshot.translatedText, '你好');
    expect(history.page(), hasLength(2));
    expect(tester.takeException(), isNull);
  });
  testWidgets('单词查到释义时右栏为词典并可加入生词本，长句只翻译不查词典', (tester) async {
    const methods = MethodChannel('test/dictionary/methods');
    const events = EventChannel('test/dictionary/events');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (_) async => null);
    messenger.setMockMethodCallHandler(
      MethodChannel(events.name),
      (_) async => null,
    );
    final database = sqlite3.openInMemory();
    final vocabulary = VocabularyStore(database);
    final looked = <String>[];
    final session = SelectionSession(
      provider: _Provider(
        'translate',
        Stream.fromIterable([
          const TranslationUpdate('机缘凑巧'),
          const TranslationCompleted(),
        ]),
      ),
      detectLanguage: (_) async => 'en',
      language: const LanguageDirection(primaryCode: 'zh-CN'),
      lookupDefinition: (text) async {
        looked.add(text);
        return 'serendipity | noun 机缘凑巧';
      },
    );
    addTearDown(() {
      session.dispose();
      database.close();
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(MethodChannel(events.name), null);
    });
    final bridge = ChannelPlatformBridge(methods: methods, events: events);
    await tester.pumpWidget(
      TranSnapApp(
        selection: bridge,
        overlay: bridge,
        speech: bridge,
        perf: bridge,
        session: session,
        history: TranslationHistoryStore(database),
        vocabulary: vocabulary,
      ),
    );
    await tester.pump();

    Future<void> translate(String sessionId, String text) async {
      await messenger.handlePlatformMessage(
        events.name,
        codec.encodeSuccessEnvelope({
          'type': BridgeEventTypes.selectionCaptured,
          'sessionId': sessionId,
          'gesture': SelectionGestureTypes.hotkey,
          'text': text,
          'sourceAppName': 'Notes',
          'x': 0,
          'y': 0,
        }),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    await translate('word', ' serendipity ');
    expect(looked, ['serendipity']);
    expect(find.text('词典'), findsOneWidget);
    expect(find.text('serendipity | noun 机缘凑巧'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('card-vocabulary')));
    await tester.pump();
    expect(
      find.byWidgetPredicate((w) => w is AppTooltip && w.message == '已加入生词本'),
      findsOneWidget,
    );
    expect(
      [for (final e in vocabulary.list()) (e.word, e.translation)],
      [('serendipity', '机缘凑巧')],
    );

    await translate('sentence', 'this is a long sentence');
    expect(looked, ['serendipity']);
    expect(find.text('词典'), findsNothing);
    expect(find.byKey(const ValueKey('card-vocabulary')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
