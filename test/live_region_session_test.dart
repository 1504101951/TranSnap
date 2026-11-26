import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/channel_names.dart';
import 'package:transnap/src/common/constants/error_codes.dart';
import 'package:transnap/src/common/constants/live_region.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/settings/app_settings.dart';
import 'package:transnap/src/settings/service_config.dart';
import 'package:transnap/src/translation/live_region_session.dart';
import 'package:transnap/src/translation/providers/apple_translation_provider.dart';
import 'package:transnap/src/translation/translation_types.dart';

final class ManualClock implements LiveRegionClock {
  DateTime current = DateTime.utc(2026);
  DateTime? deadline;
  void Function()? callback;

  @override
  DateTime now() => current;

  @override
  void schedule(Duration delay, void Function() fire) {
    deadline = current.add(delay);
    callback = fire;
  }

  @override
  void cancelSchedule() {
    deadline = null;
    callback = null;
  }

  void elapse(Duration step) {
    final target = current.add(step);
    while (deadline != null && !deadline!.isAfter(target)) {
      current = deadline!;
      final fire = callback;
      deadline = null;
      callback = null;
      fire?.call();
    }
    current = target;
  }
}

final class ScriptedProvider implements BatchTranslationProvider {
  ScriptedProvider({this.parallel = true});

  final bool parallel;
  final requests = <BatchTranslationRequest>[];
  final controllers = <StreamController<BatchTranslationEvent>>[];

  final models = <String>[];
  String model = '';

  final cancelled = <int>[];
  final _settled = <int>{};

  @override
  String get id => 'svc';

  @override
  bool get usesSlidingContext => false;

  @override
  bool get allowsParallelBatches => parallel;

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) =>
      throw UnimplementedError();

  @override
  Stream<BatchTranslationEvent> translateBatch(
    BatchTranslationRequest request, {
    required HttpClient client,
  }) {
    final index = requests.length;
    requests.add(request);
    models.add(model);
    final controller = StreamController<BatchTranslationEvent>(
      onCancel: () {
        if (!_settled.contains(index)) cancelled.add(index);
      },
    );
    controllers.add(controller);
    return controller.stream;
  }

  void complete(int index, List<String?> translations) {
    _settled.add(index);
    for (final (item, text) in translations.indexed) {
      if (text != null) controllers[index].add(BatchItemUpdate(item, text));
    }
    controllers[index].add(const BatchCompleted());
  }

  void fail(
    int index,
    TranslationFailureKind kind, [
    String message = '失败',
    Duration? retryAfter,
  ]) {
    _settled.add(index);
    controllers[index].add(BatchFailure(message, kind, retryAfter: retryAfter));
  }

  List<List<String>> get sent => [for (final request in requests) request.texts];
}

Future<void> _delivered(LiveRegionSession session) async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
    await session.settle();
  }
}

List<Object?> _overlayTexts(LiveRegionSession session) => [
  for (final overlay in session.view.overlays) overlay['text'],
];

LiveOcrSample _frame(int generation, List<String> texts) => LiveOcrSample(
  generation: generation,
  blocks: [
    for (final (index, text) in texts.indexed)
      LiveTextBlock(text: text, x: 0, y: index * 20.0, width: 200, height: 20),
  ],
);

AppSettings _settings({
  String model = 'm1',
  String primary = 'zh-CN',
  String? secondary = 'en',
}) => AppSettings(
  primaryLanguage: primary,
  secondaryLanguage: secondary,
  defaultServiceId: 'svc',
  services: [
    ServiceConfig(
      id: 'svc',
      kind: 'openai',
      name: 'Model',
      baseUrl: 'https://example.com/v1',
      model: model,
    ),
  ],
);

LiveRegionSession _session(
  ScriptedProvider provider,
  ManualClock clock, {
  String? detected = 'en',
}) => LiveRegionSession(
  providerFor: (settings) =>
      provider..model = settings.services.single.model,
  detectLanguage: (_) async => detected,
  clock: clock,
);

const _transient = TranslationFailureKind.transient;
const _halfSecond = Duration(milliseconds: 500);

void main() {
  test('首个非空画面的多个段落块合成一个批次，增量按下标盖到各自的矩形', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['Hello', 'World']));
    expect(provider.sent, [
      ['Hello', 'World'],
    ]);
    expect(provider.requests.single.targetLanguage, 'zh-CN');
    expect(session.view.status, '正在翻译');
    provider.controllers.single.add(const BatchItemUpdate(1, '世'));
    await _delivered(session);
    expect(session.view.overlays, [
      {'text': '世', 'x': 0.0, 'y': 20.0, 'width': 200.0, 'height': 20.0},
    ]);
    provider.complete(0, ['你好', '界']);
    await _delivered(session);
    expect(_overlayTexts(session), ['你好', '世界']);
    expect(session.view.status, '已完成');
    expect(session.view.overlays, hasLength(2));
    await session.onOcr(_frame(1, ['Hello', 'World']));
    expect(provider.requests, hasLength(1));
  });

  test('画面只变化一个段落块时在途批次不取消，新段落块满足等待和间隔后才发送', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A', 'B']));
    clock.elapse(const Duration(milliseconds: 100));
    await session.onOcr(_frame(1, ['A', 'C']));
    expect(provider.cancelled, isEmpty);
    provider.complete(0, ['甲', '乙']);
    await _delivered(session);
    expect(_overlayTexts(session), ['甲']);
    clock.elapse(const Duration(milliseconds: 399));
    await _delivered(session);
    expect(provider.requests, hasLength(1));
    clock.elapse(const Duration(milliseconds: 1));
    await _delivered(session);
    expect(provider.sent.last, ['C']);
  });

  test('段落块全部离开画面后取消批次，迟到事件不绘制', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    await session.onOcr(_frame(1, ['B']));
    expect(provider.cancelled, [0]);
    provider.controllers[0].add(const BatchItemUpdate(0, '甲'));
    provider.controllers[0].add(const BatchCompleted());
    await _delivered(session);
    expect(session.view.overlays, isEmpty);
  });

  test('回到已翻译的画面直接命中缓存，离开画面的在途结果也进入缓存', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A', 'B']));
    await session.onOcr(_frame(1, ['A']));
    provider.complete(0, ['甲', '乙']);
    await _delivered(session);
    await session.onOcr(_frame(1, ['B']));
    expect(_overlayTexts(session), ['乙']);
    expect(session.view.status, '已完成');
    await session.onOcr(_frame(1, ['A', 'B']));
    expect(_overlayTexts(session), ['甲', '乙']);
    clock.elapse(const Duration(seconds: 5));
    await _delivered(session);
    expect(provider.requests, hasLength(1));
  });

  test('非首个画面的新段落块等满 200ms 才发送，原文不变不重置计时', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    provider.complete(0, ['甲']);
    await _delivered(session);
    clock.elapse(const Duration(seconds: 1));
    await session.onOcr(_frame(1, ['A', 'B']));
    clock.elapse(const Duration(milliseconds: 199));
    await session.onOcr(_frame(1, ['A', 'B']));
    expect(provider.requests, hasLength(1));
    clock.elapse(const Duration(milliseconds: 1));
    await _delivered(session);
    expect(provider.sent.last, ['B']);
  });

  test('单批最多 20 个段落块或 2000 字符，先到为准', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    final many = [for (var i = 0; i < 21; i++) 'p$i'];
    await session.onOcr(_frame(1, many));
    expect(provider.sent.single, many.sublist(0, 20));
    clock.elapse(_halfSecond);
    await _delivered(session);
    expect(provider.sent.last, ['p20']);

    final other = ScriptedProvider();
    final byChars = _session(other, ManualClock());
    byChars.start(_settings(), 1);
    await byChars.onOcr(_frame(1, ['a' * 1000, 'b' * 1000, 'c']));
    expect(other.sent.single, ['a' * 1000, 'b' * 1000]);
  });

  test('在途批次最多 3 个，不允许并行的服务只有 1 个', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    final many = [for (var i = 0; i < 61; i++) 'p$i'];
    await session.onOcr(_frame(1, many));
    for (var i = 0; i < 3; i++) {
      clock.elapse(_halfSecond);
      await _delivered(session);
    }
    expect(provider.requests, hasLength(3));
    provider.complete(0, [for (var i = 0; i < 20; i++) '译$i']);
    await _delivered(session);
    expect(provider.sent.last, ['p60']);

    final serialClock = ManualClock();
    final serial = ScriptedProvider(parallel: false);
    final single = _session(serial, serialClock);
    single.start(_settings(), 1);
    await single.onOcr(_frame(1, many.sublist(0, 21)));
    serialClock.elapse(const Duration(seconds: 5));
    await _delivered(single);
    expect(serial.requests, hasLength(1));
    serial.complete(0, [for (var i = 0; i < 20; i++) '译$i']);
    await _delivered(single);
    expect(serial.sent.last, ['p20']);
  });

  test('临时错误按请求间隔重试，同一段落原文最多重试 3 次', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    for (var attempt = 0; attempt < 4; attempt++) {
      expect(provider.requests, hasLength(attempt + 1));
      provider.fail(attempt, _transient, '网络异常');
      await _delivered(session);
      clock.elapse(const Duration(milliseconds: 499));
      await _delivered(session);
      expect(provider.requests, hasLength(attempt + 1));
      clock.elapse(const Duration(milliseconds: 1));
      await _delivered(session);
    }
    expect(provider.requests, hasLength(4));
    expect(session.view.status, '网络异常');
    await session.onOcr(_frame(1, ['B']));
    clock.elapse(const Duration(seconds: 1));
    await _delivered(session);
    await session.onOcr(_frame(1, ['A', 'B']));
    clock.elapse(const Duration(seconds: 5));
    await _delivered(session);
    expect(provider.sent.last, ['B']);
    expect(provider.requests, hasLength(5));
  });

  test('语言识别抛错时批次按临时失败结束，按请求间隔重试并继续调度（#116）', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    var calls = 0;
    final session = LiveRegionSession(
      providerFor: (settings) =>
          provider..model = settings.services.single.model,
      detectLanguage: (_) async {
        calls++;
        if (calls == 1) throw StateError('识别失败');
        return 'en';
      },
      clock: clock,
    );
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    await _delivered(session);
    expect(provider.requests, isEmpty);
    expect(session.view.status, '等待翻译');
    clock.elapse(const Duration(milliseconds: 499));
    await _delivered(session);
    expect(provider.requests, isEmpty);
    clock.elapse(const Duration(milliseconds: 1));
    await _delivered(session);
    expect(provider.sent, [
      ['A'],
    ]);
    expect(session.view.status, '正在翻译');
  });

  test('频率受限按 2/4 秒或 Retry-After 退避后重试，成功一批后退避从 2 秒重新计（#118）', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    const limited = TranslationFailureKind.rateLimited;
    const millisecond = Duration(milliseconds: 1);

    Future<void> limitAndWait(
      int index,
      Duration wait, [
      Duration? retryAfter,
    ]) async {
      provider.fail(index, limited, '请求过于频繁', retryAfter);
      await _delivered(session);
      clock.elapse(wait - millisecond);
      await _delivered(session);
      expect(provider.requests, hasLength(index + 1));
      clock.elapse(millisecond);
      await _delivered(session);
      expect(provider.requests, hasLength(index + 2));
    }

    await limitAndWait(0, const Duration(seconds: 2));
    await limitAndWait(1, const Duration(seconds: 4));
    await limitAndWait(
      2,
      const Duration(seconds: 3),
      const Duration(seconds: 3),
    );
    provider.complete(3, ['甲']);
    await _delivered(session);
    await session.onOcr(_frame(1, ['A', 'B']));
    clock.elapse(const Duration(seconds: 1));
    await _delivered(session);
    expect(provider.sent.last, ['B']);
    await limitAndWait(4, const Duration(seconds: 2));
  });

  test('服务级明确错误后本次会话不再发送，新会话恢复发送', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    provider.fail(0, TranslationFailureKind.service, '认证失败');
    await _delivered(session);
    await session.onOcr(_frame(1, ['A', 'B']));
    clock.elapse(const Duration(seconds: 5));
    await _delivered(session);
    expect(provider.requests, hasLength(1));
    expect(session.view.status, '认证失败');
    session.start(_settings(), 2);
    await session.onOcr(_frame(2, ['A']));
    expect(provider.requests, hasLength(2));
  });

  test('Apple 系统翻译不支持某段的语言对时只放弃该段，其余段落照常翻译', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel(ChannelNames.platform);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.cancelSystemTranslation) return null;
      final arguments = Map<Object?, Object?>.from(call.arguments as Map);
      if (arguments['source'] == 'ro') {
        throw PlatformException(code: ErrorCodes.translationUnsupported);
      }
      return [for (final text in arguments['texts'] as List) '译:$text'];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final clock = ManualClock();
    final session = LiveRegionSession(
      providerFor: (_) => AppleTranslationProvider(),
      detectLanguage: (text) async => text == 'Salut' ? 'ro' : 'en',
      clock: clock,
    );
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['Salut', 'Hello']));
    for (var round = 0; round < 6; round++) {
      clock.elapse(_halfSecond);
      await _delivered(session);
    }
    expect(_overlayTexts(session), ['译:Hello']);
    expect(session.view.status, 'Apple 系统翻译不支持「ro → 简体中文」。');
  });

  test('段落级明确错误：多段批次各自单独补发，单段不再发送', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A', 'B']));
    provider.fail(0, TranslationFailureKind.paragraph, '模型拒绝');
    await _delivered(session);
    clock.elapse(_halfSecond);
    await _delivered(session);
    clock.elapse(_halfSecond);
    await _delivered(session);
    expect(provider.sent.sublist(1), [
      ['A'],
      ['B'],
    ]);
    provider.fail(1, TranslationFailureKind.paragraph, '模型拒绝');
    provider.complete(2, ['乙']);
    await _delivered(session);
    clock.elapse(const Duration(seconds: 5));
    await _delivered(session);
    expect(provider.requests, hasLength(3));
    expect(_overlayTexts(session), ['乙']);
    expect(session.view.status, '模型拒绝');
  });

  test('批次内没有译文的段落块单独补发一次，仍没有译文则不再发送', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A', 'B']));
    provider.complete(0, ['甲', null]);
    await _delivered(session);
    expect(_overlayTexts(session), ['甲']);
    clock.elapse(_halfSecond);
    await _delivered(session);
    expect(provider.sent.last, ['B']);
    provider.complete(1, [null]);
    await _delivered(session);
    clock.elapse(const Duration(seconds: 5));
    await _delivered(session);
    expect(provider.requests, hasLength(2));
    expect(session.view.status, '服务未返回该段译文。');
  });

  test('暂停取消在途批次并撤掉盖层，恢复后命中缓存的段落块不重复发送', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    provider.complete(0, ['甲']);
    await _delivered(session);
    await session.onOcr(_frame(1, ['A', 'C']));
    clock.elapse(_halfSecond);
    await _delivered(session);
    expect(provider.sent.last, ['C']);
    session.pause(2);
    await _delivered(session);
    expect(provider.cancelled, [1]);
    expect(session.view.phase, LiveRegionPhase.paused);
    expect(session.view.overlays, isEmpty);
    await session.onOcr(_frame(2, ['D']));
    expect(provider.requests, hasLength(2));
    session.resume(3);
    await session.onOcr(_frame(3, ['A', 'C']));
    expect(_overlayTexts(session), ['甲']);
    clock.elapse(_halfSecond);
    await _delivered(session);
    expect(provider.sent.sublist(2), [
      ['C'],
    ]);
  });

  test('结束、放弃与采集失效都撤下盖层并清空缓存，采集失效显示原因', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    provider.complete(0, ['甲']);
    await _delivered(session);
    session.end(2);
    expect(session.view.phase, LiveRegionPhase.ended);
    expect(session.view.overlays, isEmpty);
    session.start(_settings(), 3);
    await session.onOcr(_frame(3, ['A']));
    expect(provider.requests, hasLength(2));
    provider.complete(1, ['甲']);
    await _delivered(session);
    session.discard(4);
    expect(session.view.phase, LiveRegionPhase.discarded);
    expect(session.view.overlays, isEmpty);
    session.start(_settings(), 5);
    await session.onOcr(_frame(5, ['A']));
    provider.complete(2, ['甲']);
    await _delivered(session);
    session.captureUnavailable(6, '目标显示器已移除。');
    expect(session.view.phase, LiveRegionPhase.ended);
    expect(session.view.overlays, isEmpty);
    expect(session.view.status, '目标显示器已移除。');
  });

  test('修改设置不重译未变化的段落块，新出现的段落块使用新设置', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    provider.complete(0, ['甲']);
    await _delivered(session);
    session.noteSettings(_settings(model: 'm2'));
    await session.onOcr(_frame(1, ['A']));
    clock.elapse(const Duration(seconds: 1));
    await _delivered(session);
    expect(provider.requests, hasLength(1));
    await session.onOcr(_frame(1, ['A', 'B']));
    clock.elapse(_halfSecond);
    await _delivered(session);
    expect(provider.sent.last, ['B']);
    expect(provider.models, ['m1', 'm2']);
    expect(_overlayTexts(session), ['甲']);
  });

  test('超过 50000 个字符的段落块只在本地提示，刚好 50000 仍发送', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['x' * 50001]));
    expect(provider.requests, isEmpty);
    expect(session.view.status, '文字超过 50,000 个字符，未发送翻译请求。');
    await session.onOcr(_frame(1, ['y' * 50000]));
    clock.elapse(const Duration(milliseconds: 200));
    await _delivered(session);
    expect(provider.requests, hasLength(1));
  });

  test('中文识别失败时按中文处理；已是目标语言不请求；译文与原文相同不盖层', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock, detected: null);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['你好']));
    expect(provider.requests.single.detectedLanguage, 'zh-CN');
    expect(provider.requests.single.targetLanguage, 'en');
    provider.complete(0, ['你好']);
    await _delivered(session);
    expect(session.view.status, '已完成');
    expect(session.view.overlays, isEmpty);

    final other = ScriptedProvider();
    final same = _session(other, ManualClock());
    same.start(_settings(primary: 'en', secondary: null), 1);
    await same.onOcr(_frame(1, ['Hello']));
    expect(other.requests, isEmpty);
    expect(same.view.status, '已完成');
    expect(same.view.overlays, isEmpty);
  });

  test('中文为主的画面里英文段落照常翻译；双向语言时按目标语言分两次请求', () async {
    Future<String?> language(String text) async =>
        RegExp(r'[㐀-鿿]').hasMatch(text) ? 'zh-Hans' : 'en';

    final provider = ScriptedProvider();
    final session = LiveRegionSession(
      providerFor: (_) => provider,
      detectLanguage: language,
      clock: ManualClock(),
    );
    session.start(_settings(secondary: null), 1);
    await session.onOcr(_frame(1, ['第一段中文内容', '第二段中文内容', 'replacing signature']));
    expect(provider.requests, hasLength(1));
    expect(provider.requests.single.texts, ['replacing signature']);
    expect(provider.requests.single.detectedLanguage, 'en');
    expect(provider.requests.single.targetLanguage, 'zh-CN');

    final both = ScriptedProvider();
    final twoWay = LiveRegionSession(
      providerFor: (_) => both,
      detectLanguage: language,
      clock: ManualClock(),
    );
    twoWay.start(_settings(), 1);
    await twoWay.onOcr(_frame(1, ['第一段中文内容', 'replacing signature']));
    expect(
      {for (final request in both.requests) request.targetLanguage: request.texts},
      {
        'en': ['第一段中文内容'],
        'zh-CN': ['replacing signature'],
      },
    );
  });

  test('已是目标语言的段落不整段覆盖，只在夹杂的外文片段位置盖译文盖板；多个分段合并为一块，同一片段跨段落只请求一次，可排除与译文同原词的片段不盖（#24）', () async {
    Future<String?> language(String text) async =>
        RegExp(r'[㐀-鿿]').hasMatch(text) ? 'zh-Hans' : 'en';
    LiveTextSegment segment(int start, int end, double y) => LiveTextSegment(
      start: start,
      end: end,
      rect: Rect.fromLTWH(start * 10.0, y, (end - start) * 10.0, 20),
    );
    LiveTextBlock block(String text, double y, List<(int, int)> words) =>
        LiveTextBlock(
          text: text,
          x: 0,
          y: y,
          width: text.length * 10.0,
          height: 20,
          segments: [for (final (start, end) in words) segment(start, end, y)],
        );
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = LiveRegionSession(
      providerFor: (_) => provider,
      detectLanguage: language,
      clock: clock,
    );
    session.start(_settings(secondary: null), 1);
    final frame = LiveOcrSample(
      generation: 1,
      blocks: [
        block('我们用 cache hit 机制', 0, [(0, 3), (4, 9), (10, 13), (14, 16)]),
        block('缓存叫 cache，经理叫 PM', 20, [
          (0, 3),
          (4, 9),
          (9, 10),
          (10, 13),
          (14, 16),
        ]),
        block('见 v1.2 和 A 方案', 40, [(0, 1), (2, 6), (7, 8), (9, 10), (11, 13)]),
      ],
    );
    await session.onOcr(frame);
    expect(provider.requests, isEmpty);
    clock.elapse(_halfSecond);
    await _delivered(session);
    expect(provider.sent, [
      ['cache hit', 'cache', 'PM'],
    ]);
    expect(provider.requests.single.detectedLanguage, 'en');
    expect(provider.requests.single.targetLanguage, 'zh-CN');
    expect(session.view.overlays, isEmpty);
    provider.complete(0, ['缓存命中', '缓存', 'PM']);
    await _delivered(session);
    expect(session.view.overlays, [
      {'text': '缓存命中', 'x': 40.0, 'y': 0.0, 'width': 90.0, 'height': 20.0},
      {'text': '缓存', 'x': 40.0, 'y': 20.0, 'width': 50.0, 'height': 20.0},
    ]);
    expect(session.view.status, '已完成');

    await session.onOcr(frame);
    clock.elapse(_halfSecond);
    await _delivered(session);
    expect(provider.requests, hasLength(1));
    expect(session.view.overlays, hasLength(2));
  });
  test('同一段落原文出现在两处时只翻译一次，两处都盖上译文', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['OK', 'OK']));
    expect(provider.sent.single, ['OK']);
    provider.complete(0, ['确定']);
    await _delivered(session);
    expect(session.view.overlays.map((item) => item['y']), [0.0, 20.0]);
  });

  test('空白与识别失败分开显示，都撤去译文并取消在途批次', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    await session.onOcr(const LiveOcrSample(generation: 1));
    expect(session.view.status, '未识别到文字');
    expect(provider.requests, isEmpty);
    await session.onOcr(_frame(1, ['A']));
    await session.onOcr(_frame(1, ['   ']));
    await _delivered(session);
    expect(provider.cancelled, [0]);
    expect(session.view.status, '未识别到文字');
    expect(session.view.overlays, isEmpty);
    await session.onOcr(const LiveOcrSample(generation: 1, failure: '识别失败'));
    expect(session.view.status, '识别失败');
  });

  test('批次结束时随快照给出一条计时，之后的快照不再重复', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final views = <LiveRegionView>[];
    final session = LiveRegionSession(
      providerFor: (_) => provider,
      detectLanguage: (_) async => 'en',
      clock: clock,
      onView: views.add,
    );
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['A']));
    provider.complete(0, ['甲']);
    await _delivered(session);
    clock.elapse(const Duration(seconds: 1));
    await session.onOcr(_frame(1, ['A', 'Bcd']));
    clock.elapse(const Duration(milliseconds: 200));
    await _delivered(session);
    views.clear();
    clock.elapse(const Duration(milliseconds: 120));
    provider.controllers[1].add(const BatchItemUpdate(0, '乙'));
    await _delivered(session);
    clock.elapse(const Duration(milliseconds: 180));
    provider.complete(1, []);
    await _delivered(session);
    expect([for (final view in views) ...view.metrics], [
      {
        'blocks': 1,
        'chars': 3,
        'waitMs': 200,
        'firstMs': 120,
        'totalMs': 300,
        'inflight': 1,
        'outcome': 'completed',
      },
    ]);
    await session.onOcr(_frame(1, ['A', 'Bcd']));
    expect(session.view.metrics, isEmpty);
  });

  test('内容不变的画面不重复通知；译文增量在间隔内合并，到点补发最新内容', () async {
    final provider = ScriptedProvider();
    final views = <LiveRegionView>[];
    final session = LiveRegionSession(
      providerFor: (_) => provider,
      detectLanguage: (_) async => 'en',
      clock: ManualClock(),
      onView: views.add,
    );
    session.start(_settings(), 1);
    await session.onOcr(_frame(1, ['Abc']));
    final afterFirst = views.length;
    await session.onOcr(_frame(1, ['Abc']));
    expect(views.length, afterFirst);

    provider.controllers[0].add(const BatchItemUpdate(0, '甲'));
    await _delivered(session);
    final afterToken = views.length;
    expect(views.last.overlays.single['text'], '甲');
    provider.controllers[0].add(const BatchItemUpdate(0, '乙'));
    provider.controllers[0].add(const BatchItemUpdate(0, '丙'));
    await _delivered(session);
    expect(views.length, afterToken);
    expect(session.view.overlays.single['text'], '甲乙丙');
    await Future<void>.delayed(
      LiveRegionSchedule.streamPublishInterval + const Duration(milliseconds: 50),
    );
    expect(views.length, afterToken + 1);
    expect(views.last.overlays.single['text'], '甲乙丙');
    session.end(1);
  });

  test('新会话不接收上一次代次的 OCR', () async {
    final clock = ManualClock();
    final provider = ScriptedProvider();
    final session = _session(provider, clock);
    session.start(_settings(), 1);
    session.start(_settings(), 2);
    await session.onOcr(_frame(1, ['A']));
    expect(provider.requests, isEmpty);
    expect(session.view.status, '正在识别');
  });
}
