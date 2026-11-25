import 'dart:io';

import '../common/constants/translation_phase.dart';
export '../common/constants/translation_phase.dart';

class TranslationSnapshot {
  const TranslationSnapshot({
    required this.phase,
    required this.sourceText,
    required this.translatedText,
    this.message,
    this.detectedLanguage,
    this.pairs = const [],
  });

  static const idle = TranslationSnapshot(
    phase: TranslationPhase.idle,
    sourceText: '',
    translatedText: '',
  );

  final TranslationPhase phase;
  final String sourceText;
  final String translatedText;
  final String? message;

  final String? detectedLanguage;
  final List<TranslationPair> pairs;

  TranslationSnapshot copyWith({
    TranslationPhase? phase,
    String? sourceText,
    String? translatedText,
    String? message,
    String? detectedLanguage,
    List<TranslationPair>? pairs,
  }) {
    return TranslationSnapshot(
      phase: phase ?? this.phase,
      sourceText: sourceText ?? this.sourceText,
      translatedText: translatedText ?? this.translatedText,
      message: message,
      detectedLanguage: detectedLanguage ?? this.detectedLanguage,
      pairs: pairs ?? this.pairs,
    );
  }
}

class TranslationPair {
  const TranslationPair(this.source, this.translation);
  final String source;
  final String translation;
}

class TranslationRequest {
  const TranslationRequest({
    required this.sourceText,
    required this.targetLanguage,
    this.detectedLanguage,
    this.previousSourceTail,
    this.previousTranslationTail,
  });

  final String sourceText;
  final String? detectedLanguage;
  final String targetLanguage;

  final String? previousSourceTail;

  final String? previousTranslationTail;
}

sealed class TranslationEvent {
  const TranslationEvent();
}

final class TranslationUpdate extends TranslationEvent {
  const TranslationUpdate(this.addition);
  final String addition;
}

final class TranslationCompleted extends TranslationEvent {
  const TranslationCompleted({this.pairs = const []});
  final List<TranslationPair> pairs;
}

const translationTimeoutMessage = '翻译请求超时，请重试。';

const incompleteTranslationMessage = '服务未返回完整译文。';

const paragraphCountMismatchMessage = '服务返回的段落数与原文不一致，请重试。';

const batchItemLimit = 20;
const batchCharLimit = 2000;

final class TranslationFailure extends TranslationEvent {
  const TranslationFailure(this.message);
  final String message;
}

abstract class TranslationProvider {
  String get id;

  bool get usesSlidingContext => false;

  Stream<TranslationEvent> translate(TranslationRequest request);
}

class BatchTranslationRequest {
  const BatchTranslationRequest({
    required this.texts,
    required this.targetLanguage,
    this.detectedLanguage,
    this.previousSourceTail,
    this.previousTranslationTail,
  });
  final List<String> texts;
  final String? detectedLanguage;
  final String targetLanguage;
  final String? previousSourceTail;
  final String? previousTranslationTail;
}

enum TranslationFailureKind {
  service,

  rateLimited,

  paragraph,

  transient,
}

sealed class BatchTranslationEvent {
  const BatchTranslationEvent();
}

final class BatchItemUpdate extends BatchTranslationEvent {
  const BatchItemUpdate(this.index, this.addition);
  final int index;
  final String addition;
}

final class BatchCompleted extends BatchTranslationEvent {
  const BatchCompleted();
}

final class BatchFailure extends BatchTranslationEvent {
  const BatchFailure(this.message, this.kind, {this.retryAfter});
  final String message;
  final TranslationFailureKind kind;
  final Duration? retryAfter;
}

abstract class BatchTranslationProvider implements TranslationProvider {
  bool get allowsParallelBatches;

  Stream<BatchTranslationEvent> translateBatch(
    BatchTranslationRequest request, {
    required HttpClient client,
  });
}

Duration? parseRetryAfter(String? value) {
  final seconds = int.tryParse(value?.trim() ?? '');
  return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
}

typedef ServiceChoice = ({String id, String name, bool isModel, bool isDefault});
