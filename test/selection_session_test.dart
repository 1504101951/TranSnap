import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/selection_gesture_types.dart';
import 'package:transnap/src/common/constants/text_mode.dart';
import 'package:transnap/src/selection/selection_session.dart';
import 'package:transnap/src/translation/language_direction.dart';
import 'package:transnap/src/translation/translation_types.dart';

class _StreamingProvider extends TranslationProvider {
  _StreamingProvider(this.id, this.events);

  @override
  final String id;
  final Stream<TranslationEvent> events;

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) => events;
}

class RecordingProvider implements TranslationProvider {
  RecordingProvider({
    this.id = 'recording',
    this.events = const [TranslationUpdate('你好'), TranslationCompleted()],
  });

  @override
  final String id;
  @override
  bool get usesSlidingContext => false;
  final List<TranslationEvent> events;
  final requests = <TranslationRequest>[];

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) async* {
    requests.add(request);
    for (final event in events) {
      yield event;
    }
  }
}

void main() {
  final language = LanguageDirection(primaryCode: 'zh-CN', secondaryCode: 'en');

  for (final override in [false, true]) {
    test(
      '删除${override ? '卡片选中' : '当前激活'}服务取消展开会话，删除其他服务保留卡片，新请求使用已提交默认服务',
      () async {
        final started = Completer<void>();
        final released = Completer<void>();
        final visible = Completer<void>();
        final events = StreamController<TranslationEvent>(
          onListen: started.complete,
          onCancel: released.complete,
        );
        addTearDown(events.close);
        final active = _StreamingProvider('selected-service', events.stream);
        final next = RecordingProvider(
          id: 'next-default',
          events: const [TranslationUpdate('新的默认译文'), TranslationCompleted()],
        );
        final session = SelectionSession(
          detectLanguage: (_) async => 'en',
          provider: override ? RecordingProvider(id: 'old-default') : active,
          language: language,
        )..serviceProviderFor = (_, _) => active;
        addTearDown(session.dispose);
        session.addListener(() {
          if (session.snapshot.translatedText == '部分译文' &&
              !visible.isCompleted) {
            visible.complete();
          }
        });
        session.begin(sessionId: 'removed-service-card', text: 'Selected text');
        final Future<void> pending;
        if (override) {
          await session.activate();
          pending = session.switchService('selected-service');
        } else {
          pending = session.activate();
        }
        await started.future.timeout(const Duration(seconds: 1));
        expect(
          session.dismissIfServiceRemoved({'old-default', 'selected-service'}),
          isNull,
        );
        events.add(const TranslationUpdate('部分译文'));
        await visible.future.timeout(const Duration(seconds: 1));
        expect(session.sessionId, 'removed-service-card');
        expect(session.snapshot.phase, TranslationPhase.translating);
        expect(session.isExpanded, isTrue);

        session.provider = next;
        expect(
          session.dismissIfServiceRemoved({'next-default'}),
          'removed-service-card',
        );
        await pending.timeout(const Duration(seconds: 1));
        await released.future.timeout(const Duration(seconds: 1));
        expect(events.hasListener, isFalse);
        expect(session.sessionId, isNull);
        expect(session.serviceOverride, isNull);
        expect(session.snapshot.phase, TranslationPhase.idle);
        expect(session.snapshot.sourceText, isEmpty);
        expect(session.snapshot.translatedText, isEmpty);
        expect(session.isExpanded, isFalse);
        expect(session.canRetry, isFalse);

        events.add(const TranslationUpdate('旧译文'));
        events.add(const TranslationCompleted());
        session.begin(sessionId: 'next-default-card', text: 'New selection');
        await session.activate();
        expect(session.sessionId, 'next-default-card');
        expect(session.snapshot.phase, TranslationPhase.completed);
        expect(session.snapshot.translatedText, '新的默认译文');
        expect(session.activeProvider.id, 'next-default');
        expect(session.serviceOverride, isNull);
      },
    );
  }

  test('输入翻译使用独立语言方向，其余入口使用全局方向（#99）', () async {
    final provider = RecordingProvider();
    final session = SelectionSession(
      detectLanguage: (_) async => 'en',
      provider: provider,
      language: const LanguageDirection(
        primaryCode: 'zh-CN',
        secondaryCode: 'en',
      ),
      inputLanguage: const LanguageDirection(
        primaryCode: 'en',
        secondaryCode: 'ja',
      ),
    );
    addTearDown(session.dispose);
    session.begin(sessionId: 'global', text: 'Hello');
    await session.activate();
    expect(provider.requests.last.targetLanguage, 'zh-CN');
    session.begin(sessionId: 'input', text: 'Hello', input: true);
    await session.activate();
    expect(provider.requests.last.targetLanguage, 'ja');
  });

  test('卡片服务菜单：切换服务只影响本卡片，润色时非模型服务明确失败，新选区回到默认服务（#100）', () async {
    final model = RecordingProvider(
      events: const [TranslationUpdate('模型'), TranslationCompleted()],
    );
    final session =
        SelectionSession(
            detectLanguage: (_) async => 'en',
            provider: RecordingProvider(
              events: const [TranslationUpdate('默认'), TranslationCompleted()],
            ),
            language: language,
          )
          ..serviceProviderFor = (serviceId, mode) => serviceId == 'model'
              ? model
              : mode == TextMode.translate
              ? RecordingProvider()
              : null;
    addTearDown(session.dispose);
    session.begin(sessionId: 's1', text: 'Hello');
    await session.activate();
    expect(session.snapshot.translatedText, '默认');

    await session.switchService('model');
    expect(session.serviceOverride, 'model');
    expect(session.snapshot.translatedText, '模型');
    expect(session.activeProvider, same(model));

    await session.switchMode(TextMode.polish);
    expect(model.requests.last.targetLanguage, 'en');
    await session.switchService('plain');
    expect(session.snapshot.phase, TranslationPhase.failed);
    expect(session.snapshot.message, SelectionSession.assistUnavailable);

    session.begin(sessionId: 's2', text: 'Hi');
    expect(session.serviceOverride, isNull);
    await session.activate();
    expect(session.snapshot.translatedText, '默认');
  });

  test('切换模式对同一原文重新处理：解释用主要语言，润色保持原文语言，无模型服务时明确失败', () async {
    final assist = RecordingProvider(
      events: const [TranslationUpdate('结果'), TranslationCompleted()],
    );
    var available = true;
    final session = SelectionSession(
      detectLanguage: (_) async => 'en',
      provider: RecordingProvider(),
      language: language,
    )..assistProviderFor = (_) => available ? assist : null;
    addTearDown(session.dispose);
    session.begin(sessionId: 's1', text: 'Hello');
    await session.activate();
    expect(session.snapshot.phase, TranslationPhase.completed);

    expect(session.outputLanguage, 'zh-CN');
    await session.switchMode(TextMode.explain);
    expect(session.mode, TextMode.explain);
    expect(session.outputLanguage, 'zh-CN');
    expect(session.snapshot.sourceText, 'Hello');
    expect(session.snapshot.translatedText, '结果');
    expect(assist.requests.last.targetLanguage, 'zh-CN');

    await session.switchMode(TextMode.polish);
    expect(assist.requests.last.targetLanguage, 'en');
    expect(session.outputLanguage, 'en');

    available = false;
    final sent = assist.requests.length;
    await session.switchMode(TextMode.correct);
    expect(session.snapshot.phase, TranslationPhase.failed);
    expect(session.snapshot.message, SelectionSession.assistUnavailable);
    expect(assist.requests, hasLength(sent));

    session.begin(sessionId: 's2', text: 'World');
    expect(session.mode, TextMode.translate);
  });

  test('展开后的请求保留激活时服务和语言，设置变更只影响下一次翻译', () async {
    final detection = Completer<String?>();
    final first = RecordingProvider();
    final next = RecordingProvider();
    final session = SelectionSession(
      detectLanguage: (_) => detection.future,
      provider: first,
      language: language,
    );
    addTearDown(session.dispose);
    session.begin(sessionId: 'first', text: 'Hello');
    final active = session.activate();
    session.provider = next;
    session.language = LanguageDirection(primaryCode: 'fr');
    detection.complete('en');
    await active;
    expect(first.requests.single.targetLanguage, 'zh-CN');
    expect(session.snapshot.detectedLanguage, 'en');
    expect(next.requests, isEmpty);
    expect(session.isExpanded, isTrue);
    session.begin(sessionId: 'next', text: 'Next');
    await session.activate();
    expect(next.requests.single.targetLanguage, 'fr');
  });

  test('键盘无 AX 文本时可显示按钮，只有显式补读的有效文字会被翻译', () async {
    final provider = RecordingProvider();
    final session = SelectionSession(
      detectLanguage: (_) async => 'en',
      provider: provider,
      language: language,
    );
    addTearDown(session.dispose);
    session.begin(sessionId: 'keyboard', text: '', awaitSelection: true);
    expect(session.snapshot.phase, TranslationPhase.trigger);
    expect(provider.requests, isEmpty);
    await session.activate(readSelection: () async => 'First.\n\nSecond.');
    expect(provider.requests.single.sourceText, 'First.\n\nSecond.');
    expect(session.snapshot.phase, TranslationPhase.completed);
    session.begin(sessionId: 'empty', text: '', awaitSelection: true);
    await session.activate();
    expect(session.snapshot.phase, TranslationPhase.failed);
    expect(provider.requests, hasLength(1));
  });

  test(
    'explicit activation preserves prepared paragraphs in request and card',
    () async {
      final provider = RecordingProvider();
      final session = SelectionSession(
        provider: provider,
        detectLanguage: (_) async => 'en',
      );
      final read = Completer<String?>();
      session.begin(sessionId: 'formatted', text: 'First.Second.');
      final pending = session.activate(readSelection: () => read.future);
      expect(session.snapshot.phase, TranslationPhase.translating);
      expect(provider.requests, isEmpty);
      read.complete('First.\n\nSecond.');
      await pending;
      expect(provider.requests.single.sourceText, 'First.\n\nSecond.');
      expect(session.snapshot.sourceText, 'First.\n\nSecond.');
      expect(session.snapshot.phase, TranslationPhase.completed);
    },
  );

  test(
    'late source read cannot translate or replace a newer selection',
    () async {
      final provider = RecordingProvider();
      final session = SelectionSession(
        provider: provider,
        detectLanguage: (_) async => 'en',
      );
      final read = Completer<String?>();
      session.begin(sessionId: 'old', text: 'Old');
      final pending = session.activate(readSelection: () => read.future);
      session.begin(sessionId: 'new', text: 'New');
      read.complete('Old formatted');
      await pending;
      expect(session.sessionId, 'new');
      expect(session.snapshot.sourceText, 'New');
      expect(session.snapshot.phase, TranslationPhase.trigger);
      expect(provider.requests, isEmpty);
    },
  );

  test(
    'missing or oversized prepared text never reaches the provider',
    () async {
      for (final text in [null, 'x' * (SelectionSession.selectionLimit + 1)]) {
        final provider = RecordingProvider();
        final session = SelectionSession(
          provider: provider,
          detectLanguage: (_) async => 'en',
        );
        session.begin(sessionId: 'source', text: 'Captured');
        await session.activate(readSelection: () async => text);
        expect(
          session.snapshot.phase,
          text == null ? TranslationPhase.failed : TranslationPhase.sizeLimited,
        );
        expect(provider.requests, isEmpty);
      }
    },
  );

  test('gesture with text shows trigger without calling provider', () {
    final provider = RecordingProvider();
    final session = SelectionSession(
      detectLanguage: (_) async => 'en',
      provider: provider,
      language: language,
    );
    session.begin(sessionId: 's1', text: 'Hello');
    expect(session.snapshot.phase, TranslationPhase.trigger);
    expect(session.snapshot.sourceText, 'Hello');
    expect(provider.requests, isEmpty);
  });

  test('blank text stays idle', () {
    final session = SelectionSession(
      detectLanguage: (_) async => 'en',
      provider: RecordingProvider(),
      language: language,
    );
    session.begin(sessionId: 's1', text: '  \n');
    expect(session.snapshot.phase, TranslationPhase.idle);
  });

  test(
    'late translation cannot reopen a dismissed or replaced selection',
    () async {
      final session = SelectionSession(
        detectLanguage: (_) async => 'en',
        provider: RecordingProvider(),
        language: language,
      );
      session.begin(sessionId: 's1', text: 'Hello');
      final pending = session.activate();
      session.dismiss();
      session.begin(sessionId: 's2', text: 'New selection');
      await pending;
      expect(session.sessionId, 's2');
      expect(session.snapshot.phase, TranslationPhase.trigger);
      expect(session.snapshot.sourceText, 'New selection');
      expect(session.snapshot.translatedText, isEmpty);
    },
  );

  test('activate translates and assembles updates', () async {
    final provider = RecordingProvider(
      events: const [
        TranslationUpdate('你'),
        TranslationUpdate('好'),
        TranslationCompleted(),
      ],
    );
    final session = SelectionSession(
      detectLanguage: (_) async => 'en',
      provider: provider,
      language: language,
    );
    session.begin(sessionId: 's1', text: 'Hello');
    await session.activate();
    expect(session.snapshot.phase, TranslationPhase.completed);
    expect(session.snapshot.translatedText, '你好');
    expect(provider.requests.single.sourceText, 'Hello');
  });

  test('oversize selection stays local', () async {
    final provider = RecordingProvider();
    final session = SelectionSession(
      detectLanguage: (_) async => 'en',
      provider: provider,
      language: language,
    );
    session.begin(
      sessionId: 's1',
      text: 'a' * (SelectionSession.selectionLimit + 1),
    );
    await session.activate();
    expect(session.snapshot.phase, TranslationPhase.sizeLimited);
    expect(provider.requests, isEmpty);
  });

  test('limit inclusive still translates', () async {
    final provider = RecordingProvider();
    final session = SelectionSession(
      detectLanguage: (_) async => 'en',
      provider: provider,
      language: language,
    );
    session.begin(sessionId: 's1', text: 'a' * SelectionSession.selectionLimit);
    await session.activate();
    expect(session.snapshot.phase, TranslationPhase.completed);
    expect(provider.requests, isNotEmpty);
    expect(
      provider.requests.map((r) => r.sourceText).join().length,
      SelectionSession.selectionLimit,
    );
  });

  test('先唤起面板后异步读取选区完成翻译，密码框错误码返回明确失败提示', () async {
    final provider = RecordingProvider(
      events: const [TranslationUpdate('你好'), TranslationCompleted()],
    );
    final session = SelectionSession(
      detectLanguage: (_) async => 'en',
      provider: provider,
      language: language,
    );
    session.begin(sessionId: 'hotkey-1', text: '', awaitSelection: true);
    expect(session.snapshot.phase, TranslationPhase.trigger);

    final pendingRead = Completer<String?>();
    final activation = session.activate(readSelection: () => pendingRead.future);
    expect(session.snapshot.phase, TranslationPhase.translating);
    expect(session.snapshot.sourceText, isEmpty);

    pendingRead.complete('Hello');
    await activation;
    expect(session.snapshot.phase, TranslationPhase.completed);
    expect(session.snapshot.sourceText, 'Hello');
    expect(session.snapshot.translatedText, '你好');

    final secureProvider = RecordingProvider();
    final secureSession = SelectionSession(
      detectLanguage: (_) async => 'en',
      provider: secureProvider,
      language: language,
    );
    secureSession.begin(sessionId: 'hotkey-2', text: '', awaitSelection: true);
    await secureSession.activate(
      readSelection: () => Future<String?>.error(
        PlatformException(
          code: SelectionReadFailures.secureField,
          message: '密码框中的文字不会被读取。',
        ),
      ),
    );
    expect(secureSession.snapshot.phase, TranslationPhase.failed);
    expect(secureSession.snapshot.message, '密码框中的文字不会被读取。');
    expect(secureProvider.requests, isEmpty);
  });
}
