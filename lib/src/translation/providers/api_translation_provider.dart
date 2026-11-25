import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../common/constants/network_limits.dart';
import '../../common/constants/text_mode.dart';
import '../../settings/service_config.dart';
import '../glossary.dart';
import '../model_result.dart';
import '../numbered_batch.dart';
import '../paragraph_translation.dart';
import '../translation_http.dart';
import '../translation_types.dart';

class ApiTranslationProvider implements BatchTranslationProvider {
  ApiTranslationProvider({
    required this.config,
    required this.credentials,
    required this.prompt,
    required this.thinking,
    required this.semanticPairs,
    this.mode = TextMode.translate,
    this.glossary = const [],
  });
  final ServiceConfig config;
  final Future<Map<String, String>> Function() credentials;
  final TextMode mode;

  final bool semanticPairs;

  final String prompt;

  final bool thinking;

  final List<GlossaryEntry> glossary;
  @override
  String get id => config.id;

  @override
  bool get usesSlidingContext => config.isModel && mode == TextMode.translate;
  @override
  bool get allowsParallelBatches => true;

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) {
    if (mode != TextMode.translate) return _translate(request);
    if (config.isModel && semanticPairs) {
      return translateParagraphs(_translate, request);
    }
    final (:items, :chars) = switch (config.kind) {
      'google' => _googleBatchLimits,
      'baidu' => _baiduBatchLimits,
      _ => _modelBatchLimits,
    };
    return translateParagraphBatches(
      this,
      request,
      maxItems: items,
      maxChars: chars,
    );
  }

  static const _googleBatchLimits = (items: 128, chars: 5000);
  static const _baiduBatchLimits = (items: null, chars: 2000);

  static const _baiduLongQueryRetryAfter = Duration(seconds: 3);
  static const _modelBatchLimits = (
    items: batchItemLimit,
    chars: batchCharLimit,
  );

  static const _connectMessage = '无法连接翻译服务，请检查网络与 API 地址。';
  static const _unknownMessage = '翻译失败，请检查服务配置；返回内容可能不符合接口格式。';

  static _ApiFailure _failureOf(Object error) => switch (error) {
    _ApiFailure() => error,
    TimeoutException() => const _ApiFailure(translationTimeoutMessage),
    SocketException() => const _ApiFailure(_connectMessage),
    _ => const _ApiFailure(_unknownMessage),
  };
  static const _requestTimeout = Duration(seconds: 90);

  static const _glossaryInstruction =
      '\n用户消息中的 glossary 是术语表：原文出现 term 时，译文必须使用对应的 translation；'
      'translation 与 term 相同表示保留原文不译。';
  static const _batchInstruction =
      '\n输入 paragraphs 是若干互相独立的段落，每行一段，行首为“[编号]”。'
      '逐段完整翻译，不合并、不拆分、不遗漏、不调整顺序。'
      '每段译文单独占一行，行首保留原编号，格式为“[编号] 译文”，译文内不换行。'
      '只输出这些行，不附加解释。';

  Stream<TranslationEvent> _translate(TranslationRequest request) {
    final semantic = semanticPairs && mode == TextMode.translate;
    final output = StreamController<TranslationEvent>();
    var active = true;
    HttpClientRequest? pending;
    StreamIterator<String>? additions;

    Future<String> readBody(HttpClientResponse response) async {
      final body = StringBuffer();
      final stream = StreamIterator(utf8.decoder.bind(response));
      additions = stream;
      while (await stream.moveNext()) {
        body.write(stream.current);
      }
      return body.toString();
    }

    void emit(TranslationEvent event) {
      if (active && !output.isClosed) output.add(event);
    }

    Future<void> run() async {
      final secret = await _readSecret();
      if (!active) return;
      final http = await _open(translationHttpClient);
      pending = http;
      if (!active) return;
      switch (config.kind) {
        case 'baidu':
          _writeBaidu(
            http,
            secret,
            q: request.sourceText,
            detected: request.detectedLanguage,
            target: request.targetLanguage,
          );
        case 'google':
          _writeGoogle(
            http,
            secret,
            q: request.sourceText,
            detected: request.detectedLanguage,
            target: request.targetLanguage,
          );
        default:
          final assist = mode == TextMode.translate ? null : prompt;
          final terms = glossaryHits(glossary, [
            request.sourceText,
          ], request.targetLanguage);
          final system =
              assist ??
              prompt +
                  (terms.isEmpty ? '' : _glossaryInstruction) +
                  (semantic
                      ? '\n本次启用双语段落对照，以下格式要求优先于“只输出译文”：'
                            '输入 paragraphs 按原文段落编号，结合全文语义逐段完整翻译，不概括、不合并、不遗漏。'
                            '只输出一个合法 JSON 对象：{"segments":[{"id":0,"translation":"该段完整译文"}]}。'
                            '每个输入编号必须按原顺序出现且仅出现一次，译文不能为空；保留段内格式。'
                            '原文由应用按编号显示，不必重复输出原文或整篇译文。不要输出思考过程、Markdown 围栏或解释。'
                      : '\n只输出完整译文，不附加解释。');
          final input = jsonEncode({
            'source_language': request.detectedLanguage,
            'target_language': request.targetLanguage,
            if (terms.isNotEmpty) 'glossary': terms,
            if (semantic)
              'paragraphs': [
                for (final (index, text) in modelSourceParagraphs(
                  request.sourceText,
                ).indexed)
                  {'id': index, 'text': text},
              ]
            else
              'text': request.sourceText,
            if (request.previousSourceTail != null ||
                request.previousTranslationTail != null)
              'previous_context': {
                'source_tail': request.previousSourceTail,
                'translation_tail': request.previousTranslationTail,
              },
          });
          _writeModel(
            http,
            secret,
            system: system,
            input: input,
            jsonObject: semantic,
          );
      }
      final response = await http.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _statusFailure(
          response.statusCode,
          await readBody(response),
          response.headers.value('retry-after'),
        );
      }
      if (!config.isModel) {
        final data = jsonDecode(await readBody(response)) as Map;
        final text =
            (config.kind == 'baidu'
                    ? _baiduTranslations(data)
                    : _googleTranslations(data))
                .join('\n');
        if (text.trim().isEmpty) throw const _ApiFailure('服务未返回译文。');
        emit(TranslationUpdate(text));
        emit(const TranslationCompleted());
        return;
      }

      final buffer = StringBuffer();
      final stream = StreamIterator(_modelAdditions(response));
      additions = stream;
      while (await stream.moveNext()) {
        if (!active) return;
        final addition = stream.current;
        buffer.write(addition);
        if (!semantic && addition.isNotEmpty) {
          emit(TranslationUpdate(addition));
        }
      }
      if (buffer.toString().trim().isEmpty) {
        throw const _ApiFailure('模型未完整结束翻译，请重试。');
      }
      if (semantic) {
        final parsed = parseModelResult(buffer.toString(), request.sourceText);
        emit(TranslationUpdate(parsed.translation));
        emit(TranslationCompleted(pairs: parsed.pairs));
      } else {
        emit(const TranslationCompleted());
      }
    }

    output.onListen = () async {
      try {
        await run().timeout(_requestTimeout);
      } catch (error) {
        emit(TranslationFailure(_failureOf(error).message));
      } finally {
        active = false;
        pending?.abort();
        await additions?.cancel();
        await output.close();
      }
    };
    output.onCancel = () {
      active = false;
      pending?.abort();
      return additions?.cancel();
    };
    return output.stream;
  }

  @override
  Stream<BatchTranslationEvent> translateBatch(
    BatchTranslationRequest request, {
    required HttpClient client,
  }) {
    final output = StreamController<BatchTranslationEvent>();
    var active = true;
    HttpClientRequest? pending;
    StreamIterator<String>? additions;

    void emit(BatchTranslationEvent event) {
      if (active && !output.isClosed) output.add(event);
    }

    void emitItems(List<String> translations) {
      if (translations.length != request.texts.length) return;
      for (final (index, text) in translations.indexed) {
        emit(BatchItemUpdate(index, text));
      }
    }

    Future<void> run() async {
      final secret = await _readSecret();
      if (!active) return;
      final http = await _open(client);
      pending = http;
      if (!active) return;
      final lines = [
        for (final text in request.texts) singleLineParagraph(text),
      ];
      switch (config.kind) {
        case 'baidu':
          _writeBaidu(
            http,
            secret,
            q: lines.join('\n'),
            detected: request.detectedLanguage,
            target: request.targetLanguage,
          );
        case 'google':
          _writeGoogle(
            http,
            secret,
            q: lines,
            detected: request.detectedLanguage,
            target: request.targetLanguage,
          );
        default:
          final terms = glossaryHits(
            glossary,
            request.texts,
            request.targetLanguage,
          );
          _writeModel(
            http,
            secret,
            system:
                prompt +
                (terms.isEmpty ? '' : _glossaryInstruction) +
                _batchInstruction,
            input: jsonEncode({
              'source_language': request.detectedLanguage,
              'target_language': request.targetLanguage,
              if (terms.isNotEmpty) 'glossary': terms,
              'paragraphs': numberedBatchText(request.texts),
              if (request.previousSourceTail != null ||
                  request.previousTranslationTail != null)
                'previous_context': {
                  'source_tail': request.previousSourceTail,
                  'translation_tail': request.previousTranslationTail,
                },
            }),
            jsonObject: false,
          );
      }
      final response = await http.close();
      if (!active) {
        unawaited(response.listen((_) {}).cancel());
        return;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _statusFailure(
          response.statusCode,
          await utf8.decoder.bind(response).join(),
          response.headers.value('retry-after'),
        );
      }
      if (!config.isModel) {
        final data =
            jsonDecode(await utf8.decoder.bind(response).join()) as Map;
        emitItems(
          config.kind == 'baidu'
              ? _baiduTranslations(data)
              : _googleTranslations(data),
        );
        emit(const BatchCompleted());
        return;
      }
      final parser = NumberedBatchParser(request.texts.length);
      final stream = StreamIterator(_modelAdditions(response));
      additions = stream;
      while (await stream.moveNext()) {
        if (!active) return;
        parser.add(stream.current).forEach(emit);
      }
      parser.finish().forEach(emit);
      emit(const BatchCompleted());
    }

    output.onListen = () async {
      try {
        await run().timeout(_requestTimeout);
      } catch (error) {
        final failure = _failureOf(error);
        emit(
          BatchFailure(
            failure.message,
            failure.kind,
            retryAfter: failure.retryAfter,
          ),
        );
      } finally {
        active = false;
        pending?.abort();
        await additions?.cancel();
        await output.close();
      }
    };
    output.onCancel = () {
      active = false;
      pending?.abort();
      return additions?.cancel();
    };
    return output.stream;
  }

  Future<Map<String, String>> _readSecret() async {
    try {
      _validateRequest();
      final secret = await credentials();
      config.validateCredentials(secret);
      return secret;
    } on FormatException catch (error) {
      throw _ApiFailure(error.message, kind: TranslationFailureKind.service);
    }
  }

  Future<HttpClientRequest> _open(HttpClient client) async {
    final http = await client.postUrl(_endpoint());
    http.followRedirects = false;
    return http;
  }

  Uri _endpoint() {
    final base = config.baseUrl.replaceFirst(RegExp(r'/+$'), '');
    final path = switch (config.kind) {
      'baidu' => '/api/trans/vip/translate',
      'google' => '/language/translate/v2',
      'openai' || 'deepseek' => '/chat/completions',
      'anthropic' => '/messages',
      _ => throw const _ApiFailure(
        '不支持的翻译服务。',
        kind: TranslationFailureKind.service,
      ),
    };
    return Uri.parse('$base$path');
  }

  void _writeBaidu(
    HttpClientRequest http,
    Map<String, String> secret, {
    required String q,
    required String? detected,
    required String target,
  }) {
    const languageCodes = {
      'zh-CN': 'zh',
      'zh-TW': 'cht',
      'ja': 'jp',
      'ko': 'kor',
      'fr': 'fra',
      'es': 'spa',
      'ar': 'ara',
      'vi': 'vie',
    };
    final salt = DateTime.now().microsecondsSinceEpoch.toString();
    final appId = secret['appId']!;
    final signature = md5
        .convert(utf8.encode('$appId$q$salt${secret['apiKey']}'))
        .toString();
    final body = {
      'q': q,
      'from': languageCodes[detected] ?? detected ?? 'auto',
      'to': languageCodes[target] ?? target,
      'appid': appId,
      'salt': salt,
      'sign': signature,
    };
    http.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
      charset: 'utf-8',
    );
    http.add(utf8.encode(Uri(queryParameters: body).query));
  }

  void _writeGoogle(
    HttpClientRequest http,
    Map<String, String> secret, {
    required Object q,
    required String? detected,
    required String target,
  }) {
    http.headers.set('x-goog-api-key', secret['apiKey']!);
    http.headers.contentType = ContentType.json;
    http.add(
      utf8.encode(
        jsonEncode({
          'q': q,
          'target': target,
          'format': 'text',
          'source': ?detected,
        }),
      ),
    );
  }

  void _validateRequest() {
    config.validate();
    const budget = NetworkLimits.anthropicThinkingBudget;
    if (thinking &&
        config.kind == 'anthropic' &&
        config.maxOutputTokens <= budget) {
      throw const FormatException('开启思考时，最大输出须大于思考预算 $budget tokens。');
    }
  }

  void _writeModel(
    HttpClientRequest http,
    Map<String, String> secret, {
    required String system,
    required String input,
    required bool jsonObject,
  }) {
    final Object body;
    final apiKey = secret['apiKey'] ?? '';
    if (config.kind != 'anthropic') {
      if (apiKey.isNotEmpty) {
        http.headers.set('Authorization', 'Bearer $apiKey');
      }
      final isDeepSeek =
          config.kind == 'deepseek' ||
          Uri.parse(config.baseUrl).host == 'api.deepseek.com';
      body = {
        'model': config.model,
        'stream': true,
        if (isDeepSeek) 'thinking': {'type': thinking ? 'enabled' : 'disabled'},
        if (jsonObject && isDeepSeek)
          'response_format': {'type': 'json_object'},
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': input},
        ],
      };
    } else {
      if (apiKey.isNotEmpty) http.headers.set('x-api-key', apiKey);
      http.headers.set('anthropic-version', '2023-06-01');
      const budget = NetworkLimits.anthropicThinkingBudget;
      body = {
        'model': config.model,
        'stream': true,
        'max_tokens': config.maxOutputTokens,
        if (thinking) 'thinking': {'type': 'enabled', 'budget_tokens': budget},
        'system': system,
        'messages': [
          {'role': 'user', 'content': input},
        ],
      };
    }
    http.headers.contentType = ContentType.json;
    http.add(utf8.encode(jsonEncode(body)));
  }

  static const _quotaCodes = {
    'insufficient_quota',
    'dailyLimitExceeded',
    'quotaExceeded',
  };

  static const _rateLimitCodes = {
    'rate_limit_exceeded',
    'rate_limit_error',
    'userRateLimitExceeded',
    'rateLimitExceeded',
  };
  static const _quotaMessage = '额度或余额不足，请检查服务账户。';
  static const _rateLimitMessage = '请求过于频繁，请稍后重试。';

  _ApiFailure _statusFailure(int status, String body, String? retryAfter) {
    final codes = _errorCodes(body);
    if (status == 402 || codes.any(_quotaCodes.contains)) {
      return const _ApiFailure(
        _quotaMessage,
        kind: TranslationFailureKind.service,
      );
    }
    if (status == 429 || codes.any(_rateLimitCodes.contains)) {
      return _ApiFailure(
        _rateLimitMessage,
        kind: TranslationFailureKind.rateLimited,
        retryAfter: parseRetryAfter(retryAfter),
      );
    }
    return _ApiFailure(
      switch (status) {
        401 || 403 => '认证失败，请检查 API 凭据和服务权限。',
        400 => '服务拒绝请求，请检查模型名称、语言与配置。',
        _ => '翻译服务请求失败（HTTP $status）。',
      },
      kind: status >= 500
          ? TranslationFailureKind.transient
          : TranslationFailureKind.service,
    );
  }

  static Set<String> _errorCodes(String body) {
    final Object? data;
    try {
      data = jsonDecode(body);
    } on FormatException {
      return const {};
    }
    final error = data is Map ? data['error'] : null;
    if (error is! Map) return const {};
    final errors = error['errors'];
    return {
      for (final key in ['code', 'type'])
        if (error[key] is String) error[key] as String,
      if (errors is List)
        for (final item in errors)
          if (item is Map && item['reason'] is String) item['reason'] as String,
    };
  }

  List<String> _baiduTranslations(Map data) {
    final code = data['error_code']?.toString();
    if (code != null && code != '52000') {
      throw switch (code) {
        '52001' || '52002' => const _ApiFailure(
          '百度翻译请求失败，请稍后重试。',
          kind: TranslationFailureKind.transient,
        ),
        '54003' => const _ApiFailure(
          _rateLimitMessage,
          kind: TranslationFailureKind.rateLimited,
        ),
        '54005' => const _ApiFailure(
          _rateLimitMessage,
          kind: TranslationFailureKind.rateLimited,
          retryAfter: _baiduLongQueryRetryAfter,
        ),
        '54004' => const _ApiFailure(
          _quotaMessage,
          kind: TranslationFailureKind.service,
        ),
        _ => const _ApiFailure(
          '百度翻译请求失败，请检查凭据、语种权限、额度和选区长度。',
          kind: TranslationFailureKind.service,
        ),
      };
    }
    return [
      for (final item in data['trans_result'] as List) item['dst'] as String,
    ];
  }

  List<String> _googleTranslations(Map data) => [
    for (final item in data['data']['translations'] as List)
      (item['translatedText'] as String).replaceAllMapped(
        RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);'),
        (match) {
          const names = {
            'amp': '&',
            'lt': '<',
            'gt': '>',
            'quot': '"',
            'apos': "'",
          };
          final code = match[1]!;
          if (names.containsKey(code)) return names[code]!;
          final rune = int.parse(
            code.substring(code.startsWith('#x') ? 2 : 1),
            radix: code.startsWith('#x') ? 16 : 10,
          );
          return String.fromCharCode(rune);
        },
      ),
  ];

  Stream<String> _modelAdditions(HttpClientResponse response) async* {
    var finished = false;
    String? stopReason;
    var dataLines = <String>[];
    await for (final line
        in response.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isNotEmpty) {
        if (line.startsWith('data:')) {
          dataLines.add(line.substring(5).replaceFirst(RegExp(r'^ '), ''));
        }
        continue;
      }
      if (dataLines.isEmpty) continue;
      final data = dataLines.join('\n');
      dataLines = [];
      if (data == '[DONE]') break;
      final chunk = jsonDecode(data) as Map;
      if (chunk['error'] != null || chunk['type'] == 'error') {
        throw const _ApiFailure('模型服务在生成过程中返回错误。');
      }
      var addition = '';
      if (config.kind != 'anthropic') {
        for (final choice in chunk['choices'] as List? ?? []) {
          if (choice['index'] != 0) continue;
          final delta = choice['delta'] as Map? ?? {};
          if (delta['refusal'] != null) {
            throw const _ApiFailure(
              '模型拒绝了本次翻译。',
              kind: TranslationFailureKind.paragraph,
            );
          }
          addition += delta['content'] as String? ?? '';
          stopReason = choice['finish_reason'] as String? ?? stopReason;
        }
        finished = stopReason != null;
      } else {
        switch (chunk['type']) {
          case 'content_block_start':
            if (chunk['content_block']['type'] == 'text') {
              addition = chunk['content_block']['text'] as String? ?? '';
            }
          case 'content_block_delta':
            if (chunk['delta']['type'] == 'text_delta') {
              addition = chunk['delta']['text'] as String;
            }
          case 'message_delta':
            stopReason = chunk['delta']['stop_reason'] as String? ?? stopReason;
          case 'message_stop':
            finished = true;
        }
      }
      yield addition;
      if (finished) break;
    }
    if (stopReason == 'length' || stopReason == 'max_tokens') {
      throw const _ApiFailure(
        '模型输出达到长度上限，译文不完整。请缩小选区或调整服务输出上限。',
        kind: TranslationFailureKind.paragraph,
      );
    }
    if (!finished || !['stop', 'end_turn'].contains(stopReason)) {
      throw const _ApiFailure('模型未完整结束翻译，请重试。');
    }
  }
}

class _ApiFailure implements Exception {
  const _ApiFailure(
    this.message, {
    this.kind = TranslationFailureKind.transient,
    this.retryAfter,
  });
  final String message;
  final TranslationFailureKind kind;
  final Duration? retryAfter;
}
