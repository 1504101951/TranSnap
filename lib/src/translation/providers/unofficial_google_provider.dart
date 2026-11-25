import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../settings/service_config.dart';
import '../translation_types.dart';
import '../numbered_batch.dart';
import '../paragraph_translation.dart';

class UnofficialGoogleProvider implements BatchTranslationProvider {
  UnofficialGoogleProvider({
    this.endpoint = ServiceConfig.builtinEndpoint,
    this.requestTimeout = const Duration(seconds: 30),
  });

  @override
  final String id = ServiceConfig.builtinId;
  @override
  bool get usesSlidingContext => false;

  @override
  bool get allowsParallelBatches => false;
  final String endpoint;
  final Duration requestTimeout;

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) {
    return translateParagraphBatches(
      this,
      request,
      maxItems: batchItemLimit,
      maxChars: batchCharLimit,
    );
  }

  @override
  Stream<BatchTranslationEvent> translateBatch(
    BatchTranslationRequest request, {
    required HttpClient client,
  }) {
    final events = StreamController<BatchTranslationEvent>();
    var active = true;
    HttpClientRequest? pending;

    void emit(BatchTranslationEvent event) {
      if (active && !events.isClosed) events.add(event);
    }

    Future<void> run() async {
      final connection = await _open(
        client,
        q: [for (final text in request.texts) singleLineParagraph(text)]
            .join('\n'),
        detected: request.detectedLanguage,
        target: request.targetLanguage,
      );
      pending = connection;
      if (!active) return;
      final response = await connection.close();
      final body = await utf8.decodeStream(response);
      if (!active) return;
      final status = response.statusCode;
      if (status < 200 || status >= 300) {
        emit(
          BatchFailure(
            'Unofficial Google Provider 请求失败（HTTP $status）。',
            status == 429
                ? TranslationFailureKind.rateLimited
                : status >= 500
                ? TranslationFailureKind.transient
                : TranslationFailureKind.service,
            retryAfter: parseRetryAfter(response.headers.value('retry-after')),
          ),
        );
        return;
      }
      final text = parseTranslatedText(body);
      final translations = request.texts.length == 1
          ? [text]
          : text.split('\n');
      if (translations.length == request.texts.length) {
        for (final (index, item) in translations.indexed) {
          emit(BatchItemUpdate(index, item));
        }
      }
      emit(const BatchCompleted());
    }

    events.onListen = () async {
      try {
        await run().timeout(requestTimeout);
      } on TimeoutException {
        emit(
          const BatchFailure(
            translationTimeoutMessage,
            TranslationFailureKind.transient,
          ),
        );
      } on SocketException {
        emit(
          const BatchFailure(
            'Unofficial Google Provider 无法连接，请检查网络。',
            TranslationFailureKind.transient,
          ),
        );
      } on FormatException {
        emit(
          const BatchFailure(
            'Unofficial Google Provider 返回了无法解析的响应。',
            TranslationFailureKind.transient,
          ),
        );
      } catch (_) {
        emit(
          const BatchFailure(
            'Unofficial Google Provider 请求失败。',
            TranslationFailureKind.transient,
          ),
        );
      } finally {
        active = false;
        pending?.abort();
        await events.close();
      }
    };
    events.onCancel = () {
      active = false;
      pending?.abort();
    };
    return events.stream;
  }

  Future<HttpClientRequest> _open(
    HttpClient client, {
    required String q,
    required String? detected,
    required String target,
  }) async {
    final connection = await client.postUrl(Uri.parse(endpoint));
    connection.headers.set(
      'Content-Type',
      'application/x-www-form-urlencoded;charset=UTF-8',
    );
    connection.headers.set('User-Agent', 'Mozilla/5.0');
    connection.write(
      Uri(
        queryParameters: {
          'client': 'gtx',
          'sl': detected ?? 'auto',
          'tl': target,
          'dt': 't',
          'q': q,
        },
      ).query,
    );
    return connection;
  }

  static String parseTranslatedText(String raw) {
    var payload = raw.trim();
    if (payload.startsWith(")]}'")) {
      payload = payload.substring(4);
    }
    final decoded = jsonDecode(payload);
    if (decoded is! List || decoded.isEmpty || decoded.first is! List) {
      throw const FormatException('unreadable');
    }
    final sentences = decoded.first as List;
    final buffer = StringBuffer();
    for (final sentence in sentences) {
      if (sentence is List && sentence.isNotEmpty && sentence.first is String) {
        buffer.write(sentence.first);
      }
    }
    final text = buffer.toString();
    if (text.trim().isEmpty) {
      throw const FormatException('empty');
    }
    return text;
  }
}
