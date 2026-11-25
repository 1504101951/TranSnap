import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/text_mode.dart';
import 'package:transnap/src/platform/settings_platform.dart';
import 'package:transnap/src/settings/app_settings.dart';
import 'package:transnap/src/settings/service_config.dart';
import 'package:transnap/src/translation/glossary.dart';
import 'package:transnap/src/translation/model_result.dart';
import 'package:transnap/src/translation/provider_selection.dart';
import 'package:transnap/src/translation/providers/api_translation_provider.dart';
import 'package:transnap/src/translation/providers/apple_translation_provider.dart';
import 'package:transnap/src/translation/translation_types.dart';

void main() {
  const request = TranslationRequest(
    sourceText: 'Hello 世界 & +',
    detectedLanguage: 'en',
    targetLanguage: 'zh-CN',
  );
  const secrets = {'apiKey': 'test-secret', 'appId': 'test-app'};

  ApiTranslationProvider provider(
    String kind,
    HttpServer server, {
    bool semantic = false,
    List<GlossaryEntry> glossary = const [],
  }) => ApiTranslationProvider(
    config: ServiceConfig(
      id: 'test',
      kind: kind,
      name: 'Test',
      baseUrl: 'http://127.0.0.1:${server.port}',
      model: 'test-model',
      semanticPairs: semantic,
    ),
    credentials: () async => secrets,
    semanticPairs: semantic,
    glossary: glossary,
    prompt: defaultPrompts[TextMode.translate]!,
    thinking: false,
  );

  test('百度表单正确编码原文与签名，Google 解码文本实体且携带 API 凭据', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final serving = () async {
      var count = 0;
      await for (final incoming in server) {
        final body = await utf8.decoder.bind(incoming).join();
        if (count++ == 0) {
          expect(incoming.method, 'POST');
          expect(incoming.uri.path, '/api/trans/vip/translate');
          final fields = Uri.splitQueryString(body);
          expect(fields['q'], request.sourceText);
          expect(fields['to'], 'zh');
          expect(
            fields['sign'],
            md5
                .convert(
                  utf8.encode(
                    '${secrets['appId']}${request.sourceText}${fields['salt']}${secrets['apiKey']}',
                  ),
                )
                .toString(),
          );
          incoming.response.write(
            jsonEncode({
              'trans_result': [
                {'src': request.sourceText, 'dst': '你好，世界'},
              ],
            }),
          );
        } else {
          expect(incoming.uri.path, '/language/translate/v2');
          expect(incoming.headers.value('x-goog-api-key'), secrets['apiKey']);
          expect(jsonDecode(body), {
            'q': [request.sourceText],
            'target': 'zh-CN',
            'source': 'en',
            'format': 'text',
          });
          incoming.response.write(
            jsonEncode({
              'data': {
                'translations': [
                  {'translatedText': '你好 &amp; &#x4E16;&#30028; &amp;lt;'},
                ],
              },
            }),
          );
        }
        await incoming.response.close();
        if (count == 2) break;
      }
    }();
    final baidu = await provider('baidu', server).translate(request).toList();
    expect((baidu.first as TranslationUpdate).addition, '你好，世界');
    expect(baidu.last, isA<TranslationCompleted>());
    final google = await provider('google', server).translate(request).toList();
    expect((google.first as TranslationUpdate).addition, '你好 & 世界 &lt;');
    expect(google.last, isA<TranslationCompleted>());
    await serving;
  });

  test('两种模型协议保留 Unicode 增量，按 SSE 事件边界读取多行 data', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final serving = () async {
      var count = 0;
      await for (final incoming in server) {
        final body =
            jsonDecode(await utf8.decoder.bind(incoming).join()) as Map;
        expect(body['model'], 'test-model');
        expect(body['stream'], true);
        incoming.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        if (count++ == 0) {
          expect(incoming.uri.path, '/chat/completions');
          expect(incoming.headers.value('authorization'), 'Bearer test-secret');
          expect(
            jsonDecode(body['messages'][1]['content'])['paragraphs'],
            '[1] ${request.sourceText}',
          );
          incoming.response.write(
            'data: {"choices":\ndata: [{"index":0,"delta":{"content":"[1] 你好🌍"},"finish_reason":null}]}\n\n',
          );
          await incoming.response.flush();
          incoming.response.write(
            'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
          );
        } else {
          expect(incoming.uri.path, '/messages');
          expect(incoming.headers.value('x-api-key'), 'test-secret');
          expect(incoming.headers.value('anthropic-version'), '2023-06-01');
          expect(body['max_tokens'], 4096);
          incoming.response.write(
            'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"[1] 你好🌍"}}\n\n',
          );
          incoming.response.write(
            'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\ndata: {"type":"message_stop"}\n\n',
          );
        }
        await incoming.response.close();
        if (count == 2) break;
      }
    }();
    for (final kind in ['openai', 'anthropic']) {
      final events = await provider(kind, server).translate(request).toList();
      expect(
        events.whereType<TranslationUpdate>().map((e) => e.addition).join(),
        '你好🌍',
      );
      expect(events.last, isA<TranslationCompleted>());
    }
    await serving;
  });

  test('模型服务未填 API Key 时不发送认证头，Google 缺凭据时显示校验提示（#123）', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final serving = () async {
      var count = 0;
      await for (final incoming in server) {
        await utf8.decoder.bind(incoming).join();
        expect(incoming.headers.value('authorization'), isNull);
        expect(incoming.headers.value('x-api-key'), isNull);
        incoming.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        if (count++ == 0) {
          incoming.response.write(
            'data: {"choices":[{"index":0,"delta":{"content":"[1] 你好"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
          );
        } else {
          incoming.response.write(
            'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"[1] 你好"}}\n\n',
          );
          incoming.response.write(
            'data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\ndata: {"type":"message_stop"}\n\n',
          );
        }
        await incoming.response.close();
        if (count == 2) break;
      }
    }();
    final baseUrl = 'http://127.0.0.1:${server.port}';
    for (final kind in ['openai', 'anthropic', 'google']) {
      final events = await ApiTranslationProvider(
        config: ServiceConfig(
          id: 'keyless',
          kind: kind,
          name: 'Keyless',
          baseUrl: baseUrl,
          model: 'local-model',
        ),
        credentials: () async => const {},
        prompt: defaultPrompts[TextMode.translate]!,
        thinking: false,
        semanticPairs: false,
      ).translate(request).toList();
      if (kind == 'google') {
        expect(
          (events.single as TranslationFailure).message,
          '请填写 API Key／密钥，百度翻译还需要 App ID。',
        );
      } else {
        expect(events.last, isA<TranslationCompleted>());
      }
    }
    await serving;
  });

  test('截断、缺少完成标记和响应错误都不被标记完成，也不回显服务正文', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    const cases = [
      (
        'openai',
        'data: {"choices":[{"index":0,"delta":{"content":"部分"},"finish_reason":"length"}]}\n\n',
      ),
      (
        'openai',
        'data: {"choices":[{"index":0,"delta":{"content":"部分"}}]}\n\ndata: [DONE]\n\n',
      ),
      (
        'anthropic',
        'data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}\n\ndata: {"type":"message_stop"}\n\n',
      ),
      (
        'openai',
        'data: {"error":{"message":"test-secret sensitive source"}}\n\n',
      ),
    ];
    final serving = () async {
      var index = 0;
      await for (final incoming in server) {
        await incoming.drain<void>();
        incoming.response.write(cases[index++].$2);
        await incoming.response.close();
        if (index == cases.length) break;
      }
    }();
    for (final item in cases) {
      final events = await provider(
        item.$1,
        server,
      ).translate(request).toList();
      expect(events.whereType<TranslationCompleted>(), isEmpty);
      expect(events.last, isA<TranslationFailure>());
      expect(
        (events.last as TranslationFailure).message,
        isNot(contains('test-secret')),
      );
    }
    await serving;
  });

  test('取消订阅关闭真实 socket，凭据未读完时取消不发出请求', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close());
    final connected = Completer<Socket>();
    final disconnected = Completer<void>();
    server.listen((socket) {
      connected.complete(socket);
      socket.listen(
        (_) {},
        onDone: () {
          disconnected.complete();
          socket.destroy();
        },
      );
    });
    final config = ServiceConfig(
      id: 'cancel',
      kind: 'openai',
      name: 'Test',
      baseUrl: 'http://127.0.0.1:${server.port}',
      model: 'test-model',
    );
    final active = ApiTranslationProvider(
      config: config,
      credentials: () async => secrets,
      prompt: defaultPrompts[TextMode.translate]!,
      thinking: false,
      semanticPairs: false,
    );
    final events = <TranslationEvent>[];
    final subscription = active.translate(request).listen(events.add);
    await connected.future.timeout(const Duration(seconds: 5));
    await subscription.cancel();
    await disconnected.future.timeout(const Duration(seconds: 5));
    expect(events, isEmpty);
    final secret = Completer<Map<String, String>>();
    final pending = ApiTranslationProvider(
      config: config,
      credentials: () => secret.future,
      prompt: defaultPrompts[TextMode.translate]!,
      thinking: false,
      semanticPairs: false,
    ).translate(request).listen(events.add);
    await pending.cancel();
    secret.complete(secrets);
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
  });

  test('模型段落编号必须完整有序，原文及分隔空白只取本地内容', () {
    const source = ' Hello.\r\n\r\n世界🌍! \n';
    final parsed = parseModelResult(
      jsonEncode({
        'segments': [
          {'id': 0, 'translation': '你好。'},
          {'id': 1, 'translation': '世界！'},
        ],
      }),
      source,
    );
    expect(parsed.translation, ' 你好。\r\n\r\n世界！ \n');
    expect(parsed.pairs.map((e) => e.source).join(), source);
    expect(parsed.pairs, hasLength(2));
    for (final segments in [
      [
        {'id': 0, 'translation': '整篇'},
      ],
      [
        {'id': 1, 'translation': '世界'},
        {'id': 0, 'translation': '你好'},
      ],
      [
        {'id': 0, 'translation': '你好'},
        {'id': 0, 'translation': '世界'},
      ],
      [
        {'id': 0, 'translation': '你好'},
        {'id': '1', 'translation': '世界'},
      ],
      [
        {'id': 0, 'translation': '你好'},
        {'id': 1, 'translation': ' '},
      ],
    ]) {
      expect(
        () => parseModelResult(jsonEncode({'segments': segments}), source),
        throwsFormatException,
      );
    }
    expect(() => parseModelResult('普通译文', source), throwsFormatException);
    expect(
      () => parseModelResult('{"segments":[', source),
      throwsFormatException,
    );
  });

  test('润色模式使用设置中的处理提示词整段发送纯文本，忽略段落对照，原文与目标同语言也发出请求', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    const source = 'helo world.\n\nsecond line';
    final serving = () async {
      final incoming = await server.first;
      final body = jsonDecode(await utf8.decoder.bind(incoming).join()) as Map;
      final system = body['messages'][0]['content'] as String;
      expect(system, '自定义润色提示词');
      expect(system, isNot(contains(defaultPrompts[TextMode.translate]!)));
      expect(body.containsKey('response_format'), isFalse);
      final input = jsonDecode(body['messages'][1]['content'] as String) as Map;
      expect(input['text'], source);
      expect(input.containsKey('paragraphs'), isFalse);
      incoming.response.write(
        'data: {"choices":[{"index":0,"delta":{"content":"Hello world.\\n\\nSecond line."},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
      );
      await incoming.response.close();
    }();
    final events =
        await ApiTranslationProvider(
              config: ServiceConfig(
                id: 'test',
                kind: 'openai',
                name: 'Test',
                baseUrl: 'http://127.0.0.1:${server.port}',
                model: 'test-model',
                semanticPairs: true,
              ),
              credentials: () async => secrets,
              mode: TextMode.polish,
              prompt: '自定义润色提示词',
              thinking: false,
              semanticPairs: true,
            )
            .translate(
              const TranslationRequest(
                sourceText: source,
                detectedLanguage: 'en',
                targetLanguage: 'en',
              ),
            )
            .toList();
    expect(
      events.whereType<TranslationUpdate>().map((e) => e.addition).join(),
      'Hello world.\n\nSecond line.',
    );
    expect(events.last, isA<TranslationCompleted>());
    await serving;
  });

  test('DeepSeek 禁用思考并按输入编号返回完整对照，不显示协议 JSON', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    const source = 'First.\n\nSecond.';
    final serving = () async {
      final incoming = await server.first;
      final body = jsonDecode(await utf8.decoder.bind(incoming).join()) as Map;
      expect(incoming.uri.path, '/chat/completions');
      expect(body['thinking'], {'type': 'disabled'});
      expect(body['response_format'], {'type': 'json_object'});
      final input = jsonDecode(body['messages'][1]['content'] as String) as Map;
      expect(input['paragraphs'], [
        {'id': 0, 'text': 'First.'},
        {'id': 1, 'text': '\n\nSecond.'},
      ]);
      final content = jsonEncode({
        'segments': [
          {'id': 0, 'translation': '第一段。'},
          {'id': 1, 'translation': '第二段。'},
        ],
      });
      incoming.response.write(
        'data: {"choices":[{"index":0,"delta":{"reasoning_content":"internal"},"finish_reason":null}]}\n\n',
      );
      incoming.response.write(
        'data: ${jsonEncode({
          'choices': [
            {
              'index': 0,
              'delta': {'content': content},
              'finish_reason': 'stop',
            },
          ],
        })}\n\ndata: [DONE]\n\n',
      );
      await incoming.response.close();
    }();
    final events = await provider('deepseek', server, semantic: true)
        .translate(
          const TranslationRequest(
            sourceText: source,
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
        )
        .toList();
    expect(
      events.whereType<TranslationUpdate>().single.addition,
      '第一段。\n\n第二段。',
    );
    final pairs = (events.last as TranslationCompleted).pairs;
    expect(pairs.map((pair) => pair.source).join(), source);
    expect(pairs.map((pair) => pair.translation), ['第一段。', '\n\n第二段。']);
    await serving;
  });

  test('输入翻译的 Provider 不使用双语段落对照，默认翻译 Provider 仍使用', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final bodies = <Map<String, Object?>>[];
    final serving = server.listen((incoming) async {
      bodies.add(
        jsonDecode(await utf8.decoder.bind(incoming).join())
            as Map<String, Object?>,
      );
      incoming.response.write(
        'data: {"choices":[{"index":0,"delta":{"content":"你好"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
      );
      await incoming.response.close();
    });
    addTearDown(serving.cancel);
    final settings = AppSettings(
      primaryLanguage: 'zh-CN',
      defaultServiceId: 'semantic',
      services: [
        ServiceConfig(
          id: 'semantic',
          kind: 'openai',
          name: 'Semantic',
          baseUrl: 'http://127.0.0.1:${server.port}',
          model: 'test-model',
          semanticPairs: true,
        ),
      ],
    );
    const single = TranslationRequest(
      sourceText: 'Hello',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
    );
    final platform = _SecretPlatform();
    await providerForSettings(settings, platform).translate(single).toList();
    await providerForInput(settings, platform).translate(single).toList();
    final defaultBody = jsonEncode(bodies[0]);
    final inputBody = jsonEncode(bodies[1]);
    expect(defaultBody, contains('segments'));
    expect(defaultBody, contains(r'{\"id\":0'));
    expect(inputBody, isNot(contains('segments')));
    expect(inputBody, contains('[1] Hello'));
  });

  Future<(Map<String, Object?>?, List<TranslationEvent>)> sendOnce(
    String kind,
    HttpServer server, {
    required bool thinking,
    int maxOutputTokens = 4096,
    String? host,
  }) async {
    Map<String, Object?>? received;
    final sub = server.listen((incoming) async {
      received = jsonDecode(
        await utf8.decoder.bind(incoming).join(),
      ) as Map<String, Object?>;
      incoming.response.write(
        kind == 'anthropic'
            ? 'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"你好"}}\n\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}\n\ndata: {"type":"message_stop"}\n\n'
            : 'data: {"choices":[{"index":0,"delta":{"content":"你好"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
      );
      await incoming.response.close();
    });
    addTearDown(sub.cancel);
    final events = await ApiTranslationProvider(
      config: ServiceConfig(
        id: 'test',
        kind: kind,
        name: 'Test',
        baseUrl: host ?? 'http://127.0.0.1:${server.port}',
        model: 'test-model',
        maxOutputTokens: maxOutputTokens,
      ),
      credentials: () async => secrets,
      prompt: defaultPrompts[TextMode.polish]!,
      mode: TextMode.polish,
      thinking: thinking,
      semanticPairs: false,
    ).translate(request).toList();
    return (received, events);
  }

  test('DeepSeek 按思考开关发送 thinking.type 为 enabled 或 disabled', () async {
    for (final thinking in [true, false]) {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final (body, events) = await sendOnce(
        'deepseek',
        server,
        thinking: thinking,
      );
      expect(events.last, isA<TranslationCompleted>());
      expect(body!['thinking'], {'type': thinking ? 'enabled' : 'disabled'});
    }
  });

  test('Anthropic 开启思考发送 2048 预算，关闭不发送，最大输出不大于预算时连接前失败', () async {
    final on = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => on.close(force: true));
    final (onBody, onEvents) = await sendOnce('anthropic', on, thinking: true);
    expect(onEvents.last, isA<TranslationCompleted>());
    expect(onBody!['thinking'], {'type': 'enabled', 'budget_tokens': 2048});

    final off = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => off.close(force: true));
    final (offBody, offEvents) = await sendOnce(
      'anthropic',
      off,
      thinking: false,
    );
    expect(offEvents.last, isA<TranslationCompleted>());
    expect(offBody!.containsKey('thinking'), isFalse);

    final small = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => small.close(force: true));
    final (smallBody, smallEvents) = await sendOnce(
      'anthropic',
      small,
      thinking: true,
      maxOutputTokens: 2048,
    );
    expect(smallBody, isNull);
    expect(
      (smallEvents.single as TranslationFailure).message,
      contains('开启思考时，最大输出须大于思考预算 2048 tokens。'),
    );
  });

  test('OpenAI 官方端点即使开启思考也不发送思考参数', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final (body, events) = await sendOnce('openai', server, thinking: true);
    expect(events.last, isA<TranslationCompleted>());
    expect(body!.containsKey('thinking'), isFalse);
    expect(body.containsKey('reasoning_effort'), isFalse);
  });

  Map<int, String> batchItems(List<BatchTranslationEvent> events) {
    final items = <int, String>{};
    for (final event in events.whereType<BatchItemUpdate>()) {
      items[event.index] = (items[event.index] ?? '') + event.addition;
    }
    return items;
  }

  const batch = BatchTranslationRequest(
    texts: ['Hello', 'World'],
    detectedLanguage: 'en',
    targetLanguage: 'zh-CN',
  );

  test('批量翻译：模型按编号流式归属到段落，Google 一次请求携带多个原文', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final serving = () async {
      var count = 0;
      await for (final incoming in server) {
        final body =
            jsonDecode(await utf8.decoder.bind(incoming).join()) as Map;
        if (count++ == 0) {
          expect(incoming.uri.path, '/chat/completions');
          expect(
            jsonDecode(body['messages'][1]['content'])['paragraphs'],
            '[1] Hello\n[2] World',
          );
          incoming.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          for (final content in [r'[2] 世界\n[1] 你', '好']) {
            incoming.response.write(
              'data: {"choices":[{"index":0,"delta":{"content":"$content"},"finish_reason":null}]}\n\n',
            );
            await incoming.response.flush();
          }
          incoming.response.write(
            'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
          );
        } else {
          expect(incoming.uri.path, '/language/translate/v2');
          expect(body['q'], ['Hello', 'World']);
          incoming.response.headers.contentType = ContentType.json;
          incoming.response.write(
            '{"data":{"translations":[{"translatedText":"你好"},{"translatedText":"A &amp;amp; B"}]}}',
          );
        }
        await incoming.response.close();
        if (count == 2) break;
      }
    }();
    final model = await provider(
      'openai',
      server,
    ).translateBatch(batch, client: client).toList();
    expect(batchItems(model), {0: '你好', 1: '世界'});
    expect(model.last, isA<BatchCompleted>());
    final google = await provider(
      'google',
      server,
    ).translateBatch(batch, client: client).toList();
    expect(batchItems(google), {0: '你好', 1: 'A &amp; B'});
    expect(google.last, isA<BatchCompleted>());
    await serving;
  });

  test('批量失败带错误类别：认证、额度与配置拒绝为服务级，频率受限可重试，服务端错误为临时，输出截断为段落级（#118）', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    const responses = <(int, String, String?)>[
      (401, 'secret upstream body', null),
      (429, 'secret upstream body', '7'),
      (
        429,
        '{"error":{"type":"insufficient_quota","code":"insufficient_quota","message":"secret"}}',
        null,
      ),
      (402, '{"error":{"message":"secret"}}', null),
      (403, '{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}', null),
      (403, '{"error":{"errors":[{"reason":"dailyLimitExceeded"}]}}', null),
      (499, 'secret upstream body', null),
      (500, 'secret upstream body', null),
    ];
    final serving = () async {
      var count = 0;
      await for (final incoming in server) {
        await incoming.drain<void>();
        if (count < responses.length) {
          final (status, body, retryAfter) = responses[count];
          incoming.response.statusCode = status;
          if (retryAfter != null) {
            incoming.response.headers.set('retry-after', retryAfter);
          }
          incoming.response.write(body);
        } else {
          incoming.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          incoming.response.write(
            'data: {"choices":[{"index":0,"delta":{"content":"[1] 你"},"finish_reason":"length"}]}\n\n',
          );
        }
        await incoming.response.close();
        if (++count == responses.length + 1) break;
      }
    }();
    final failures = <BatchFailure>[];
    for (var i = 0; i < responses.length + 1; i++) {
      final events = await provider(
        'openai',
        server,
      ).translateBatch(batch, client: client).toList();
      final failure = events.last as BatchFailure;
      expect(failure.message.contains('secret'), isFalse);
      expect(events.whereType<BatchCompleted>(), isEmpty);
      failures.add(failure);
    }
    expect(failures.map((failure) => failure.kind), [
      TranslationFailureKind.service,
      TranslationFailureKind.rateLimited,
      TranslationFailureKind.service,
      TranslationFailureKind.service,
      TranslationFailureKind.rateLimited,
      TranslationFailureKind.service,
      TranslationFailureKind.service,
      TranslationFailureKind.transient,
      TranslationFailureKind.paragraph,
    ]);
    expect(failures[1].retryAfter, const Duration(seconds: 7));
    expect(failures[1].message, '请求过于频繁，请稍后重试。');
    expect(failures[2].message, '额度或余额不足，请检查服务账户。');
    expect(failures[3].message, '额度或余额不足，请检查服务账户。');
    expect(failures[4].retryAfter, isNull);
    await serving;
  });

  test('百度错误码：54003、54005 频率受限可重试，54004 余额不足停止（#118）', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    const codes = ['54003', '54005', '54004'];
    final serving = () async {
      var count = 0;
      await for (final incoming in server) {
        await incoming.drain<void>();
        incoming.response.headers.contentType = ContentType.json;
        incoming.response.write(
          '{"error_code":"${codes[count]}","error_msg":"secret"}',
        );
        await incoming.response.close();
        if (++count == codes.length) break;
      }
    }();
    final failures = [
      for (var i = 0; i < codes.length; i++)
        (await provider(
              'baidu',
              server,
            ).translateBatch(batch, client: client).toList()).last
            as BatchFailure,
    ];
    expect(
      failures.map(
        (failure) => (failure.kind, failure.message, failure.retryAfter),
      ),
      [
        (TranslationFailureKind.rateLimited, '请求过于频繁，请稍后重试。', null),
        (
          TranslationFailureKind.rateLimited,
          '请求过于频繁，请稍后重试。',
          const Duration(seconds: 3),
        ),
        (TranslationFailureKind.service, '额度或余额不足，请检查服务账户。', null),
      ],
    );
    await serving;
  });

  test('术语表：模型请求只携带命中且目标语言一致的术语，未命中时请求与无术语表完全一致', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final bodies = <String>[];
    final serving = () async {
      await for (final incoming in server) {
        bodies.add(await utf8.decoder.bind(incoming).join());
        final content = bodies.length == 5 ? '[1] 译文' : '译文';
        incoming.response.write(
          'data: {"choices":[{"index":0,"delta":{"content":"$content"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
        );
        await incoming.response.close();
        if (bodies.length == 5) break;
      }
    }();
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    const glossary = [
      GlossaryEntry(term: 'API', translation: '应用接口', language: 'zh-CN'),
      GlossaryEntry(term: 'Kubernetes', translation: '', language: 'zh-CN'),
      GlossaryEntry(term: 'API', translation: 'interface', language: 'fr'),
    ];
    const hit = TranslationRequest(
      sourceText: 'Deploy the API on Kubernetes.',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
    );
    const miss = TranslationRequest(
      sourceText: 'The capital city.',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
    );
    for (final (request, terms) in [
      (hit, const <GlossaryEntry>[]),
      (hit, glossary),
      (miss, glossary),
      (miss, const <GlossaryEntry>[]),
    ]) {
      await provider(
        'openai',
        server,
        glossary: terms,
      ).translate(request).toList();
    }
    await provider('openai', server, glossary: glossary)
        .translateBatch(
          const BatchTranslationRequest(
            texts: ['Kubernetes cluster'],
            detectedLanguage: 'en',
            targetLanguage: 'zh-CN',
          ),
          client: client,
        )
        .toList();
    await serving;

    (String, Map) parts(int index) {
      final messages = (jsonDecode(bodies[index]) as Map)['messages'] as List;
      return (
        messages[0]['content'] as String,
        jsonDecode(messages[1]['content'] as String) as Map,
      );
    }

    final (plainSystem, plainInput) = parts(0);
    final (system, input) = parts(1);
    expect(plainInput.containsKey('glossary'), isFalse);
    expect(input['glossary'], [
      {'term': 'API', 'translation': '应用接口'},
      {'term': 'Kubernetes', 'translation': 'Kubernetes'},
    ]);
    expect(system, isNot(plainSystem));
    expect(system, contains('glossary'));
    expect(Map.of(input)..remove('glossary'), plainInput);
    expect(bodies[2], bodies[3]);
    final (batchSystem, batchInput) = parts(4);
    expect(batchSystem, contains('glossary'));
    expect(batchInput['glossary'], [
      {'term': 'Kubernetes', 'translation': 'Kubernetes'},
    ]);
  });

  test('内置服务：菜单先列谷歌翻译与 Apple 系统翻译，Apple 对应本机 Provider 且不是模型服务', () {
    const openai = ServiceConfig(
      id: 'saved',
      kind: 'openai',
      name: 'OpenAI',
      baseUrl: 'https://api.openai.com',
      model: 'gpt-test',
    );
    final settings = AppSettings(
      primaryLanguage: 'zh-CN',
      services: [openai],
      defaultServiceId: ServiceConfig.systemId,
    );
    final platform = _SecretPlatform();
    expect(serviceChoices(settings), [
      (
        id: ServiceConfig.builtinId,
        name: '谷歌翻译',
        isModel: false,
        isDefault: false,
      ),
      (
        id: ServiceConfig.systemId,
        name: 'Apple 系统翻译',
        isModel: false,
        isDefault: true,
      ),
      (id: 'saved', name: 'OpenAI', isModel: true, isDefault: false),
    ]);
    final provider = providerForService(
      settings,
      platform,
      ServiceConfig.systemId,
    );
    expect(provider, isA<AppleTranslationProvider>());
    expect(provider.id, ServiceConfig.systemId);
    expect(
      providerForSettings(settings, platform),
      isA<AppleTranslationProvider>(),
    );
    for (final mode in [TextMode.polish, TextMode.correct, TextMode.explain]) {
      expect(
        assistProviderForService(
          settings,
          platform,
          mode,
          ServiceConfig.systemId,
        ),
        isNull,
      );
    }
  });

  test('预热地址跟随默认服务：内置谷歌为接口地址，配置型服务为 API 地址，Apple 不预热（#68）', () {
    final service = ServiceConfig(
      id: 'deepseek',
      kind: 'openai',
      name: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com',
      model: 'deepseek-chat',
    );
    AppSettings withDefault(String id) => AppSettings(
      primaryLanguage: 'zh-CN',
      defaultServiceId: id,
      services: [service],
    );
    expect(
      translationOrigin(withDefault(ServiceConfig.builtinId)),
      Uri.parse(ServiceConfig.builtinEndpoint),
    );
    expect(
      translationOrigin(withDefault('deepseek')),
      Uri.parse('https://api.deepseek.com'),
    );
    expect(translationOrigin(withDefault(ServiceConfig.systemId)), isNull);
  });
}

class _SecretPlatform implements SettingsPlatform {
  @override
  Future<void> applySettings(
    Map<String, Object> settings, {
    Map<String, Map<String, String>?> credentials = const {},
  }) async {}

  @override
  Future<Map<String, String>> readCredentials(String id) async => const {
    'apiKey': 'test-secret',
  };

  @override
  Future<List<String>> credentialIds(List<String> ids) async => const [];
}
