import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/selection/selection_session.dart';
import 'package:transnap/src/translation/providers/unofficial_google_provider.dart';
import 'package:transnap/src/translation/translation_types.dart';

void main() {
  test('dismissing a selection closes its in-flight HTTP connection', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final requested = Completer<void>();
    final disconnected = Completer<void>();
    final sockets = <Socket>[];
    server.listen((socket) {
      sockets.add(socket);
      socket.listen(
        (_) {
          if (!requested.isCompleted) requested.complete();
        },
        onDone: () {
          if (!disconnected.isCompleted) disconnected.complete();
        },
      );
    });
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await server.close();
    });
    final session = SelectionSession(
      detectLanguage: (_) async => "en",
      provider: UnofficialGoogleProvider(
        endpoint: 'http://127.0.0.1:${server.port}/translate',
      ),
    );
    addTearDown(session.dispose);
    session.begin(sessionId: 's1', text: 'Hello');
    final pending = session.activate();
    await requested.future.timeout(const Duration(seconds: 5));
    session.dismiss();
    await disconnected.future.timeout(const Duration(seconds: 5));
    await pending;
    expect(session.snapshot.phase, TranslationPhase.idle);
  });

  test('单篇请求挂起时按时限失败，显示超时文案且不标记完成（#114）', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    server.listen((socket) {
      sockets.add(socket);
      socket.listen((_) {});
    });
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await server.close();
    });
    final provider = UnofficialGoogleProvider(
      endpoint: 'http://127.0.0.1:${server.port}/translate',
      requestTimeout: const Duration(milliseconds: 200),
    );
    final events = await provider
        .translate(
          const TranslationRequest(
            sourceText: 'Hello',
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
        )
        .toList()
        .timeout(const Duration(seconds: 5));
    expect(events, hasLength(1));
    expect(
      (events.single as TranslationFailure).message,
      translationTimeoutMessage,
    );
  });

  test('无法连接时说明检查网络', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    final events =
        await UnofficialGoogleProvider(
              endpoint: 'http://127.0.0.1:$port/translate',
            )
            .translate(
              const TranslationRequest(
                sourceText: 'Hello',
                detectedLanguage: 'en',
                targetLanguage: 'zh-CN',
              ),
            )
            .toList()
            .timeout(const Duration(seconds: 5));
    expect((events.single as TranslationFailure).message, '谷歌翻译无法连接，请检查网络。');
  });

  test('parses single sentence fixture', () {
    const body = r'''[[["你好","Hello",null,null,10]],null,"en"]''';
    expect(UnofficialGoogleProvider.parseTranslatedText(body), '你好');
  });

  test('concatenates multi sentence fixture', () {
    const body =
        r'''[[["第一句。","First.",null,null,3],["第二句。","Second.",null,null,3]],null,"en"]''';
    expect(UnofficialGoogleProvider.parseTranslatedText(body), '第一句。第二句。');
  });

  test('preserves paragraph and line separators in translated sentences', () {
    const body =
        r'''[[["第一段。\n\n","First paragraph.\n\n"],["第二段。\n","Second paragraph.\n"],["同段换行。","Line break."]],null,"en"]''';
    expect(
      UnofficialGoogleProvider.parseTranslatedText(body),
      '第一段。\n\n第二段。\n同段换行。',
    );
  });

  test('http error becomes failure without completed', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = 429;
      request.response.write('rate limit');
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final provider = UnofficialGoogleProvider(
      endpoint: 'http://127.0.0.1:${server.port}/translate',
    );
    final events = await provider
        .translate(
          const TranslationRequest(
            sourceText: 'Hello',
            detectedLanguage: "en",
            targetLanguage: 'zh-CN',
          ),
        )
        .toList();
    expect(events, hasLength(1));
    expect(events.first, isA<TranslationFailure>());
    expect(
      (events.first as TranslationFailure).message.contains('429'),
      isTrue,
    );
  });

  test('unconfigured provider id is unofficial-google', () {
    expect(UnofficialGoogleProvider().id, 'unofficial-google');
  });

  test('批量翻译按换行拆回各段，行数对不上时不给出译文，限流按频率受限重试（#118）', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    var count = 0;
    server.listen((incoming) async {
      final form = Uri.splitQueryString(
        await utf8.decoder.bind(incoming).join(),
      );
      expect(form['q'], 'Hello\nWorld');
      switch (count++) {
        case 0:
          incoming.response.write(
            jsonEncode([
              [
                ['你好\n', 'Hello\n'],
                ['世界', 'World'],
              ],
            ]),
          );
        case 1:
          incoming.response.write(
            jsonEncode([
              [
                ['你好世界', 'Hello World'],
              ],
            ]),
          );
        default:
          incoming.response.statusCode = 429;
          incoming.response.headers.set('retry-after', '5');
      }
      await incoming.response.close();
    });
    final provider = UnofficialGoogleProvider(
      endpoint: 'http://127.0.0.1:${server.port}/translate',
    );
    const batch = BatchTranslationRequest(
      texts: ['Hello', 'World'],
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
    );
    expect(provider.allowsParallelBatches, isFalse);
    final matched = await provider
        .translateBatch(batch, client: client)
        .toList();
    expect(
      matched.whereType<BatchItemUpdate>().map(
        (event) => (event.index, event.addition),
      ),
      [(0, '你好'), (1, '世界')],
    );
    expect(matched.last, isA<BatchCompleted>());
    final mismatched = await provider
        .translateBatch(batch, client: client)
        .toList();
    expect(mismatched.single, isA<BatchCompleted>());
    final limited = await provider
        .translateBatch(batch, client: client)
        .toList();
    final failure = limited.single as BatchFailure;
    expect(failure.kind, TranslationFailureKind.rateLimited);
    expect(failure.retryAfter, const Duration(seconds: 5));
  });

  test('HTTP 302 重定向区分 Google 风控验证与普通拦截，且不再直接暴露英文 Provider 名', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var count = 0;
    server.listen((incoming) async {
      await incoming.drain<void>();
      incoming.response.statusCode = 302;
      incoming.response.headers.set(
        HttpHeaders.locationHeader,
        count++ == 0
            ? 'https://www.google.com/sorry/index?continue=https://translate.googleapis.com'
            : 'https://portal.example.com/login',
      );
      await incoming.response.close();
    });
    final provider = UnofficialGoogleProvider(
      endpoint: 'http://127.0.0.1:${server.port}/translate',
    );
    const request = TranslationRequest(
      sourceText: 'Hello',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
    );

    final sorryEvents = await provider.translate(request).toList();
    final sorryFailure = sorryEvents.single as TranslationFailure;
    expect(sorryFailure.message, contains('触发风控验证（HTTP 302）'));

    final genericEvents = await provider.translate(request).toList();
    final genericFailure = genericEvents.single as TranslationFailure;
    expect(genericFailure.message, contains('被重定向拦截（HTTP 302）'));
  });
}
