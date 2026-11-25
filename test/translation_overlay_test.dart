import 'package:transnap/src/common/constants/selection_gesture_types.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/text_mode.dart';
import 'package:transnap/src/common/constants/bridge_event_types.dart';

import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:transnap/src/selection/selection_translation_app.dart'
    show TranSnapApp;
import 'package:transnap/src/history/translation_history.dart';
import 'package:transnap/src/history/vocabulary.dart';
import 'package:transnap/src/platform/channel_platform_bridge.dart';
import 'package:transnap/src/translation/language_direction.dart';
import 'package:transnap/src/common/widgets/native_glass.dart';
import 'package:transnap/src/overlay/dictionary_definition.dart';
import 'package:transnap/src/overlay/translation_overlay.dart';
import 'package:transnap/src/selection/selection_session.dart';
import 'package:transnap/src/translation/translation_types.dart';

class _Provider implements TranslationProvider {
  @override
  String get id => 'local-test';
  @override
  bool get usesSlidingContext => false;

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) async* {
    yield const TranslationUpdate('你好');
    yield const TranslationCompleted();
  }
}

void main() {
  testWidgets('加载与结果保留至显式关闭，自动新选区不替换，热键可替换', (tester) async {
    const methods = MethodChannel('test/retained-overlay/methods');
    const events = EventChannel('test/retained-overlay/events');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (_) async => null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('test/retained-overlay/events'),
      (_) async => null,
    );
    final detection = Completer<String?>();
    final session = SelectionSession(
      provider: _Provider(),
      detectLanguage: (_) => detection.future,
      language: LanguageDirection(primaryCode: 'zh-CN'),
    );
    addTearDown(session.dispose);
    addTearDown(() {
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(
        const MethodChannel('test/retained-overlay/events'),
        null,
      );
    });
    final bridge = ChannelPlatformBridge(methods: methods, events: events);
    await tester.pumpWidget(
      TranSnapApp(
        selection: bridge,
        overlay: bridge,
        speech: bridge,
        perf: bridge,
        session: session,
        history: TranslationHistoryStore(sqlite3.openInMemory()),
        vocabulary: VocabularyStore(sqlite3.openInMemory()),
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
      'sessionId': 'first',
      'gesture': SelectionGestureTypes.hotkey,
      'text': 'Hello',
      'x': 0,
      'y': 0,
    });
    expect(session.snapshot.phase, TranslationPhase.translating);
    await send({
      'type': BridgeEventTypes.selectionInvalidated,
      'sessionId': 'first',
    });
    await send({
      'type': BridgeEventTypes.selectionCaptured,
      'sessionId': 'passive',
      'gesture': SelectionGestureTypes.selectAll,
      'text': 'Ignored',
      'x': 0,
      'y': 0,
    });
    expect(session.sessionId, 'first');
    expect(session.snapshot.phase, TranslationPhase.translating);
    detection.complete('en');
    await tester.pumpAndSettle();
    await send({
      'type': BridgeEventTypes.selectionInvalidated,
      'sessionId': 'first',
    });
    expect(session.snapshot.phase, TranslationPhase.completed);
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('你好'), findsOneWidget);
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      expect(
        rich.text.style?.decoration?.contains(TextDecoration.underline) ??
            false,
        isFalse,
      );
    }
    await send({
      'type': BridgeEventTypes.selectionCaptured,
      'sessionId': 'replacement',
      'gesture': SelectionGestureTypes.hotkey,
      'text': 'Next',
      'x': 0,
      'y': 0,
    });
    await tester.pumpAndSettle();
    expect(session.sessionId, 'replacement');
    expect(find.text('Next'), findsOneWidget);
    await send({'type': MethodNames.escapePressed, 'sessionId': 'first'});
    expect(session.isExpanded, isTrue);
    await send({'type': MethodNames.escapePressed, 'sessionId': 'replacement'});
    expect(session.snapshot.phase, TranslationPhase.idle);
    await send({
      'type': BridgeEventTypes.selectionCaptured,
      'sessionId': 'close',
      'gesture': SelectionGestureTypes.hotkey,
      'text': 'Close',
      'x': 0,
      'y': 0,
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(session.snapshot.phase, TranslationPhase.idle);
    expect(find.text('你好'), findsNothing);

    await send({
      'type': BridgeEventTypes.selectionCaptured,
      'sessionId': 'empty-hotkey',
      'gesture': SelectionGestureTypes.hotkey,
      'text': '',
      'x': 0,
      'y': 0,
    });
    await tester.pumpAndSettle();
    expect(session.snapshot.phase, TranslationPhase.failed);
    expect(find.text('未读取到选中文字，请重新选择后使用翻译快捷键。'), findsOneWidget);
    await send({
      'type': BridgeEventTypes.selectionInvalidated,
      'sessionId': 'empty-hotkey',
    });
    expect(session.snapshot.phase, TranslationPhase.failed);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(session.snapshot.phase, TranslationPhase.idle);

    await send({
      'type': BridgeEventTypes.selectionCaptured,
      'sessionId': 'secure-hotkey',
      'gesture': SelectionGestureTypes.hotkey,
      'readFailure': SelectionReadFailures.secureField,
      'text': '',
      'x': 0,
      'y': 0,
    });
    await tester.pumpAndSettle();
    expect(session.snapshot.phase, TranslationPhase.failed);
    expect(find.text('密码框中的文字不会被读取。'), findsOneWidget);
  });

  testWidgets(
    'compact trigger drags without translating and expands on click',
    (tester) async {
      tester.view.physicalSize = TranslationOverlay.triggerWindowSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = SelectionSession(
        detectLanguage: (_) async => 'en',
        provider: _Provider(),
      );
      addTearDown(session.dispose);
      session.begin(sessionId: 's1', text: 'Hello');
      var drags = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: TranslationOverlay(
            session: session,
            onActivate: session.activate,
            onDismiss: session.dismiss,
            onDrag: () => drags += 1,
            onMode: session.switchMode,
            onService: session.switchService,
            onSpeak: (_) {},
            onAddVocabulary: () {},
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('翻译'), findsOneWidget);
      expect(find.byType(IconButton), findsNothing);
      expect(
        tester.getSize(
          find.byWidgetPredicate((widget) => widget is FilledButton),
        ),
        TranslationOverlay.triggerSize,
      );

      await tester.drag(find.text('翻译'), const Offset(30, 0));
      await tester.pumpAndSettle();
      expect(session.snapshot.phase, TranslationPhase.trigger);

      await tester.tap(find.text('翻译'));
      tester.view.physicalSize = const Size(720, 420);
      await tester.pumpAndSettle();
      expect(session.snapshot.phase, TranslationPhase.completed);
      expect(find.text('你好'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('你好')).dy,
        lessThan(tester.getTopLeft(find.text('Hello')).dy),
      );
      expect(
        tester.getTopLeft(find.text('你好')).dx,
        tester.getTopLeft(find.text('Hello')).dx,
      );
      expect(find.byKey(const ValueKey('card-copy-source')), findsOneWidget);
      expect(find.text('复制原文'), findsNothing);
      expect(find.byTooltip('复制原文'), findsOneWidget);
      expect(find.text('复制译文'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('复制译文')).dx,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('card-source-group'))).dx,
        ),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('card-source-group'))).dx,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('card-copy-source'))).dx,
        ),
      );
      final dragArea = find.byKey(const ValueKey('result-drag-area'));
      expect(tester.getSize(dragArea).height, 44);
      await tester.dragFrom(
        tester.getTopLeft(dragArea) + const Offset(180, 40),
        const Offset(40, 0),
      );
      await tester.pumpAndSettle();
      expect(drags, 2);
      expect(session.sessionId, 's1');
      expect(session.snapshot.phase, TranslationPhase.completed);
      expect(find.text('你好'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(session.snapshot.phase, TranslationPhase.idle);
      expect(find.text('你好'), findsNothing);
    },
  );

  testWidgets('底部操作行左侧「朗读译文」朗读译文、右侧原文组朗读图标朗读原文，空内容禁用（#101、#134、#67）', (tester) async {
    final session = SelectionSession(
      provider: _Provider(),
      detectLanguage: (_) async => 'en',
    );
    addTearDown(session.dispose);
    session.snapshot = const TranslationSnapshot(
      phase: TranslationPhase.translating,
      sourceText: 'Hello',
      translatedText: '',
    );
    final spoken = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: TranslationOverlay(
          session: session,
          onActivate: () {},
          onDismiss: () {},
          onDrag: () {},
          onMode: (_) {},
          onService: (_) {},
          onSpeak: spoken.add,
          onAddVocabulary: () {},
        ),
      ),
    );
    TextButton footer(String label) => tester.widget<TextButton>(
      find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((widget) => widget is TextButton),
      ),
    );
    IconButton sourceSpeak() => tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(const ValueKey('card-speak-source')),
        matching: find.byType(IconButton),
      ),
    );
    expect(footer('朗读译文').onPressed, isNull);
    expect(sourceSpeak().onPressed, isNotNull);
    session.snapshot = const TranslationSnapshot(
      phase: TranslationPhase.completed,
      sourceText: 'Hello',
      translatedText: '你好',
    );
    session.notifyListeners();
    await tester.pump();
    await tester.tap(find.text('朗读译文'));
    await tester.tap(find.byKey(const ValueKey('card-speak-source')));
    expect(spoken, [false, true]);
  });

  testWidgets('卡片布局：单栏按内容定高，多段配对、词典或超过 420pt 改为 720×420 对照（#134）', (
    tester,
  ) async {
    final session = SelectionSession(
      provider: _Provider(),
      detectLanguage: (_) async => 'en',
    );
    addTearDown(session.dispose);
    ({bool single, Size size}) layout(TranslationSnapshot snapshot) {
      session.snapshot = snapshot;
      return TranslationOverlay.layoutFor(session, TextScaler.noScaling);
    }

    expect(
      layout(
        const TranslationSnapshot(
          phase: TranslationPhase.completed,
          sourceText: 'Hello',
          translatedText: '你好',
        ),
      ),
      (single: true, size: const Size(560, 148)),
    );
    expect(
      layout(
        const TranslationSnapshot(
          phase: TranslationPhase.translating,
          sourceText: 'Hello',
          translatedText: '',
        ),
      ).size,
      const Size(560, 170),
    );
    expect(
      layout(
        const TranslationSnapshot(
          phase: TranslationPhase.completed,
          sourceText: 'A. B.',
          translatedText: '甲。乙。',
          pairs: [TranslationPair('A.', '甲。'), TranslationPair('B.', '乙。')],
        ),
      ),
      (single: false, size: const Size(720, 420)),
    );
    expect(
      layout(
        TranslationSnapshot(
          phase: TranslationPhase.completed,
          sourceText: 'Hello',
          translatedText: '很长的译文' * 200,
        ),
      ),
      (single: false, size: const Size(720, 420)),
    );
  });

  testWidgets('已验证的语义段落按译文原文成对展示', (tester) async {
    final session = SelectionSession(
      provider: _Provider(),
      detectLanguage: (_) async => 'en',
    );
    addTearDown(session.dispose);
    session.snapshot = const TranslationSnapshot(
      phase: TranslationPhase.completed,
      sourceText: 'First. Second.',
      translatedText: '完整译文',
      pairs: [
        TranslationPair('First.', '第一段。'),
        TranslationPair('Second.', '第二段。'),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: TranslationOverlay(
          session: session,
          onActivate: () {},
          onDismiss: () {},
          onDrag: () {},
          onMode: (_) {},
          onService: (_) {},
          onSpeak: (_) {},
          onAddVocabulary: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('First.'), findsOneWidget);
    expect(find.text('第二段。'), findsOneWidget);
    expect(find.text('完整译文'), findsNothing);
    for (final pair in [('第一段。', 'First.'), ('第二段。', 'Second.')]) {
      final translated = tester.getTopLeft(find.text(pair.$1));
      final source = tester.getTopLeft(find.text(pair.$2));
      expect(translated.dx, lessThan(source.dx));
      expect(translated.dy, source.dy);
    }
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    for (var index = 0; index < 2; index++) {
      await mouse.moveTo(
        tester.getCenter(find.byKey(ValueKey('translated-paragraph-$index'))),
      );
      await tester.pump();
      for (var source = 0; source < 2; source++) {
        final container = tester.widget<Container>(
          find.byKey(ValueKey('source-paragraph-$source')),
        );
        final color = (container.decoration! as BoxDecoration).color;
        expect(
          color,
          source == index ? isNot(Colors.transparent) : Colors.transparent,
        );
      }
    }
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    final source = tester.widget<Container>(
      find.byKey(const ValueKey('source-paragraph-1')),
    );
    expect((source.decoration! as BoxDecoration).color, Colors.transparent);
  });

  Future<void> pumpCard(WidgetTester tester, SelectionSession session) async {
    tester.view.physicalSize = const Size(720, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: TranslationOverlay(
          session: session,
          onActivate: session.activate,
          onDismiss: session.dismiss,
          onDrag: () {},
          onMode: session.switchMode,
          onService: session.switchService,
          onSpeak: (_) {},
          onAddVocabulary: () {},
        ),
      ),
    );
    await session.activate();
    await tester.pumpAndSettle();
  }

  testWidgets('查到词典：左 2/5 上译文下原文 15pt 半粗，右 3/5 词典；生词本在底部，复制词典在悬停词典时出现（#134）', (
    tester,
  ) async {
    final session = SelectionSession(
      provider: _Provider(),
      detectLanguage: (_) async => 'en',
      language: const LanguageDirection(
        primaryCode: 'zh-CN',
        secondaryCode: 'en',
      ),
      lookupDefinition: (_) async => 'pot | BrE pɒt | A. noun ① 锅 guō',
    );
    addTearDown(session.dispose);
    session.begin(sessionId: 'dict', text: 'pot');
    await pumpCard(tester, session);
    final translated = tester.getTopLeft(find.text('你好'));
    final source = tester.getTopLeft(find.text('pot'));
    expect(translated.dx, source.dx);
    expect(translated.dy, lessThan(source.dy));
    final style = tester.widget<Text>(find.text('你好')).textSpan!.style!;
    expect(style.fontSize, 15);
    expect(style.fontWeight, FontWeight.w600);
    expect(
      find.ancestor(of: find.text('你好'), matching: find.byType(SelectionArea)),
      findsOneWidget,
    );
    expect(find.byType(EditableText), findsNothing);
    final dictionaryX = tester.getTopLeft(find.text('词典')).dx;
    expect(dictionaryX, greaterThan(288));
    expect(translated.dx, lessThan(288));
    expect(find.text('加入生词本'), findsOneWidget);
    expect(
      tester.getSize(
        find.descendant(
          of: find
              .ancestor(
                of: find.byTooltip('复制词典'),
                matching: find.byType(SizedBox),
              )
              .first,
          matching: find.byType(IconButton),
        ),
      ),
      const Size(24, 24),
    );
    expect(find.text('A. noun'), findsOneWidget);
  });

  testWidgets('原文已是目标语言时只显示原文一栏，没有译文栏（#134）', (tester) async {
    final session = SelectionSession(
      provider: _Provider(),
      detectLanguage: (_) async => 'zh-CN',
      language: const LanguageDirection(primaryCode: 'zh-CN'),
    );
    addTearDown(session.dispose);
    session.begin(sessionId: 'same', text: '今天天气很好');
    await pumpCard(tester, session);
    expect(session.sourceIsTarget, isTrue);
    expect(find.text('复制原文'), findsOneWidget);
    expect(find.text('复制译文'), findsNothing);
    expect(find.byKey(const ValueKey('card-copy-source')), findsNothing);
    expect(find.byKey(const ValueKey('card-speak-source')), findsNothing);
    expect(find.text('今天天气很好'), findsOneWidget);
  });

  testWidgets('卡片服务菜单：翻译模式列出全部服务，润色模式只列模型服务与当前服务（#100）', (tester) async {
    final session =
        SelectionSession(
            provider: _Provider(),
            detectLanguage: (_) async => 'en',
          )
          ..serviceChoices = () => const [
            (id: 'google', name: '谷歌翻译', isModel: false, isDefault: true),
            (id: 'gpt', name: 'GPT', isModel: true, isDefault: false),
            (id: 'apple', name: 'Apple', isModel: false, isDefault: false),
          ];
    addTearDown(session.dispose);
    session.snapshot = const TranslationSnapshot(
      phase: TranslationPhase.completed,
      sourceText: 'Hello',
      translatedText: '你好',
    );
    final chosen = <String>[];
    tester.view.physicalSize = const Size(720, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: TranslationOverlay(
          session: session,
          onActivate: () {},
          onDismiss: () {},
          onDrag: () {},
          onMode: (_) {},
          onService: chosen.add,
          onSpeak: (_) {},
          onAddVocabulary: () {},
        ),
      ),
    );
    await tester.tap(find.text('谷歌翻译'));
    await tester.pumpAndSettle();
    expect(find.text('Apple'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    session.mode = TextMode.polish;
    session.notifyListeners();
    await tester.pump();
    await tester.tap(find.text('谷歌翻译'));
    await tester.pumpAndSettle();
    expect(find.text('Apple'), findsNothing);
    await tester.tap(find.text('GPT'));
    await tester.pumpAndSettle();
    expect(chosen, ['gpt']);
  });

  testWidgets('已完成卡片的服务选项更新后移除已删服务并保留当前结果', (tester) async {
    final session =
        SelectionSession(
            provider: _Provider(),
            detectLanguage: (_) async => 'en',
            language: const LanguageDirection(primaryCode: 'zh-CN'),
          )
          ..serviceChoices = () => const [
            (id: 'local-test', name: '服务 A', isModel: false, isDefault: true),
            (id: 'service-b', name: '服务 B', isModel: true, isDefault: false),
          ];
    addTearDown(session.dispose);
    session.begin(sessionId: 'retained-service-a', text: 'Hello');
    await pumpCard(tester, session);
    await tester.tap(find.text('服务 A'));
    await tester.pumpAndSettle();
    expect(find.text('服务 B'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    session.serviceChoices = () => const [
      (id: 'local-test', name: '服务 A', isModel: false, isDefault: true),
    ];
    await tester.pumpAndSettle();
    await tester.tap(find.text('服务 A'));
    await tester.pumpAndSettle();
    expect(find.text('服务 B'), findsNothing);
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('你好'), findsOneWidget);
    expect(session.sessionId, 'retained-service-a');
    expect(session.snapshot.phase, TranslationPhase.completed);
    expect(tester.takeException(), isNull);
  });

  testWidgets('译文为空的失败卡片在正文展示 NativeGlassBanner 及单一重试入口（#144）', (tester) async {
    tester.view.physicalSize = const Size(720, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SelectionSession(
      provider: _FailProvider(),
      detectLanguage: (_) async => 'en',
      language: const LanguageDirection(primaryCode: 'zh-CN'),
    );
    addTearDown(session.dispose);
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: TranslationOverlay(
          session: session,
          onActivate: () => retries += 1,
          onDismiss: () {},
          onDrag: () {},
          onMode: (_) {},
          onService: (_) {},
          onSpeak: (_) {},
          onAddVocabulary: () {},
        ),
      ),
    );
    session.begin(sessionId: 'fail-banner', text: 'Hello');
    await session.activate();
    await tester.pumpAndSettle();

    expect(session.canRetry, isTrue);
    expect(find.byType(NativeGlassBanner), findsOneWidget);
    expect(find.text('服务连接超时'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(retries, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('原文组朗读图标与「朗读译文」各自切换，并同步外部 speakingSource 状态（#101、#144、#67）', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(720, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = SelectionSession(
      provider: _Provider(),
      detectLanguage: (_) async => 'en',
      language: const LanguageDirection(
        primaryCode: 'zh-CN',
        secondaryCode: 'en',
      ),
      lookupDefinition: (_) async => 'pot | BrE pɒt | A. noun ① 锅 guō',
    );
    addTearDown(session.dispose);
    session.begin(sessionId: 'dict-speak', text: 'pot');
    final spoken = <bool>[];
    Widget card({bool? speakingSource}) => MaterialApp(
      home: TranslationOverlay(
        session: session,
        speakingSource: speakingSource,
        onActivate: () {},
        onDismiss: () {},
        onDrag: () {},
        onMode: session.switchMode,
        onService: session.switchService,
        onSpeak: spoken.add,
        onAddVocabulary: () {},
      ),
    );
    await tester.pumpWidget(card());
    await session.activate();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('card-speak-source')));
    await tester.pump();
    expect(spoken, [true]);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('card-speak-source')),
        matching: find.byTooltip('停止朗读'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('card-speak')),
        matching: find.text('朗读译文'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('card-speak-source')));
    await tester.pump();
    expect(spoken, [true, true]);
    expect(find.byTooltip('朗读原文'), findsOneWidget);

    await tester.pumpWidget(card(speakingSource: false));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('card-speak')),
        matching: find.text('停止朗读'),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('朗读原文'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('词典释义词条采用 16pt 半粗标题并用纯文本间距替代 WidgetSpan（#144）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DictionaryDefinitionView(
            definition: 'pot | BrE pɒt | A. noun ① 锅 guō',
          ),
        ),
      ),
    );
    await tester.pump();

    final rich = tester.widget<RichText>(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText && widget.text.toPlainText().startsWith('pot'),
      ),
    );
    final root = rich.text as TextSpan;
    final headword = root.text != null
        ? root
        : root.children!.first as TextSpan;
    expect(headword.text, 'pot');
    expect(headword.style?.fontSize, 16);
    expect(headword.style?.fontWeight, FontWeight.w600);
    expect(headword.style?.height, 24 / 16);
    var hasWidgetSpan = false;
    root.visitChildren((span) {
      if (span is WidgetSpan) hasWidgetSpan = true;
      return true;
    });
    expect(hasWidgetSpan, isFalse);
    expect(root.toPlainText(), 'pot  BrE pɒt');
  });
}

class _FailProvider implements TranslationProvider {
  @override
  String get id => 'local-fail';
  @override
  bool get usesSlidingContext => false;

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) async* {
    yield const TranslationFailure('服务连接超时');
  }
}
