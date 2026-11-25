import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../common/constants/channel_names.dart';
import '../../common/constants/error_codes.dart';
import '../../common/constants/method_names.dart';
import '../../common/constants/system_translation.dart';
import '../../settings/app_settings.dart';
import '../../settings/service_config.dart';
import '../model_result.dart';
import '../paragraph_translation.dart';
import '../translation_types.dart';

class AppleTranslationProvider implements BatchTranslationProvider {
  AppleTranslationProvider({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(ChannelNames.platform);

  final MethodChannel _channel;

  static var _nextRequest = 0;

  static const downloadHint = '请到「系统设置 → 通用 → 语言与地区 → 翻译语言」下载。';

  @override
  String get id => ServiceConfig.systemId;

  @override
  bool get usesSlidingContext => false;

  @override
  bool get allowsParallelBatches => false;

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) {
    return translateParagraphs(_translateSegment, request);
  }

  static const batchMinChars = 400;
  static const batchesInFlight = 3;

  static List<List<int>> paragraphBatches(List<String> paragraphs) {
    final batches = <List<int>>[];
    var current = <int>[];
    var chars = 0;
    for (final (index, paragraph) in paragraphs.indexed) {
      current.add(index);
      chars += paragraph.trim().length;
      if (batches.isEmpty || chars >= batchMinChars) {
        batches.add(current);
        current = <int>[];
        chars = 0;
      }
    }
    if (current.isNotEmpty) batches.add(current);
    return batches;
  }

  Stream<TranslationEvent> _translateSegment(TranslationRequest request) {
    final paragraphs = modelSourceParagraphs(request.sourceText);
    final batches = paragraphBatches(paragraphs);
    final inFlight = <String>{};
    final events = StreamController<TranslationEvent>();
    var active = true;
    events.onListen = () async {
      final results = List<List<String>?>.filled(batches.length, null);
      final pairs = <TranslationPair>[];
      var next = 0;
      var published = 0;
      _SystemFailure? failure;

      void publishReady() {
        while (published < batches.length && results[published] != null) {
          final batch = batches[published];
          final translations = results[published]!;
          final batchPairs = [
            for (final (offset, index) in batch.indexed)
              pairParagraph(paragraphs[index], translations[offset]),
          ];
          pairs.addAll(batchPairs);
          events.add(
            TranslationUpdate(
              batchPairs.map((pair) => pair.translation).join(),
            ),
          );
          published++;
        }
      }

      Future<void> worker() async {
        while (active && failure == null && next < batches.length) {
          final batch = next++;
          final requestId = 'apple-${_nextRequest++}';
          inFlight.add(requestId);
          try {
            results[batch] = await _translateTexts(
              requestId,
              [for (final index in batches[batch]) paragraphs[index].trim()],
              source: request.detectedLanguage,
              target: request.targetLanguage,
              strategy: SystemTranslationStrategy.highFidelity,
            );
          } on _SystemFailure catch (error) {
            failure ??= error;
            for (final other in inFlight.where((id) => id != requestId)) {
              _cancelNative(other);
            }
          } finally {
            inFlight.remove(requestId);
          }
          if (!active || failure != null) return;
          publishReady();
        }
      }

      try {
        await Future.wait([
          for (var i = 0; i < batchesInFlight && i < batches.length; i++)
            worker(),
        ]);
        if (!active) return;
        final error = failure;
        if (error != null) {
          events.add(TranslationFailure(error.message));
          return;
        }
        events.add(TranslationCompleted(pairs: pairs));
      } finally {
        active = false;
        await events.close();
      }
    };
    events.onCancel = () {
      if (!active) return;
      active = false;
      for (final requestId in inFlight) {
        _cancelNative(requestId);
      }
    };
    return events.stream;
  }

  @override
  Stream<BatchTranslationEvent> translateBatch(
    BatchTranslationRequest request, {
    required HttpClient client,
  }) {
    final requestId = 'apple-${_nextRequest++}';
    final events = StreamController<BatchTranslationEvent>();
    var active = true;
    events.onListen = () async {
      try {
        final translations = await _translateTexts(
          requestId,
          request.texts,
          source: request.detectedLanguage,
          target: request.targetLanguage,
          strategy: SystemTranslationStrategy.lowLatency,
        );
        if (!active) return;
        for (final (index, translation) in translations.indexed) {
          events.add(BatchItemUpdate(index, translation));
        }
        events.add(const BatchCompleted());
      } on _SystemFailure catch (failure) {
        if (active) events.add(BatchFailure(failure.message, failure.kind));
      } finally {
        active = false;
        await events.close();
      }
    };
    events.onCancel = () {
      if (!active) return;
      active = false;
      _cancelNative(requestId);
    };
    return events.stream;
  }

  Future<List<SystemTranslationStatus>> statuses(
    List<(String, String)> pairs,
  ) async {
    final raw = await _channel.invokeListMethod<String>(
      MethodNames.systemTranslationStatus,
      {
        'pairs': [
          for (final (source, target) in pairs) [source, target],
        ],
      },
    );
    return [
      for (final name in raw!) SystemTranslationStatus.values.byName(name),
    ];
  }

  static String pairLabel(String source, String target) =>
      '${AppSettings.languages[source] ?? source} → '
      '${AppSettings.languages[target] ?? target}';

  Future<List<String>> _translateTexts(
    String requestId,
    List<String> texts, {
    required String? source,
    required String target,
    required SystemTranslationStrategy strategy,
  }) async {
    if (source == null) {
      throw const _SystemFailure('无法识别原文语言。', TranslationFailureKind.paragraph);
    }
    try {
      final translations = await _channel.invokeListMethod<String>(
        MethodNames.systemTranslate,
        {
          'requestId': requestId,
          'texts': texts,
          'source': source,
          'target': target,
          'strategy': strategy.name,
        },
      );
      return translations!;
    } on PlatformException catch (error) {
      final label = pairLabel(source, target);
      throw switch (error.code) {
        ErrorCodes.translationNotInstalled => _SystemFailure(
          '缺少「$label」语言包，$downloadHint',
          TranslationFailureKind.paragraph,
        ),
        ErrorCodes.translationUnsupported => _SystemFailure(
          'Apple 系统翻译不支持「$label」。',
          TranslationFailureKind.paragraph,
        ),
        _ => const _SystemFailure(
          'Apple 系统翻译失败，请重试。',
          TranslationFailureKind.transient,
        ),
      };
    }
  }

  void _cancelNative(String requestId) {
    unawaited(
      _channel.invokeMethod<void>(MethodNames.cancelSystemTranslation, {
        'requestId': requestId,
      }),
    );
  }
}

class _SystemFailure implements Exception {
  const _SystemFailure(this.message, this.kind);
  final String message;
  final TranslationFailureKind kind;
}
