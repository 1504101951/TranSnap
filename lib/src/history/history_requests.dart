import 'package:flutter/services.dart';

import '../common/constants/method_names.dart';
import 'translation_history.dart';

Object? handleHistoryRequest(TranslationHistoryStore history, MethodCall call) {
  switch (call.method) {
    case MethodNames.historyPage:
      final map = Map<Object?, Object?>.from(call.arguments as Map? ?? {});
      final cursor = map['before'] as Map?;
      return [
        for (final row in history.page(
          query: map['query'] as String?,
          source: map['source'] as String?,
          from: map['from'] as int?,
          to: map['to'] as int?,
          before: cursor == null
              ? null
              : (
                  completedAt: cursor['completedAt'] as int,
                  id: cursor['id'] as int,
                ),
        ))
          {
            'id': row.id,
            'sourceText': row.sourceText,
            'translatedText': row.translatedText,
            'detectedLanguage': row.detectedLanguage,
            'targetLanguage': row.targetLanguage,
            'providerId': row.providerId,
            'model': row.model,
            'completedAt': row.completedAt,
            'sourceLabel': row.sourceLabel,
          },
      ];
    case MethodNames.historySources:
      return history.sources();
    case MethodNames.historyRetention:
      final map = Map<Object?, Object?>.from(call.arguments as Map? ?? {});
      return {
        'days': history.retentionDays,
        'confirmed': history.retentionConfirmed,
        'expiredCount': history.expiredCount(
          map['days'] as int? ?? history.retentionDays,
        ),
      };
    case MethodNames.setHistoryRetention:
      final map = Map<Object?, Object?>.from(call.arguments as Map);
      history.setRetention(map['days'] as int);
      return null;
    case MethodNames.deleteHistory:
      final map = Map<Object?, Object?>.from(call.arguments as Map);
      history.delete(map['id'] as int);
      return null;
    case MethodNames.clearHistory:
      history.clear();
      return null;
    case MethodNames.historyRecording:
      return history.recordingEnabled;
    case MethodNames.setHistoryRecording:
      final map = Map<Object?, Object?>.from(call.arguments as Map);
      history.recordingEnabled = map['enabled'] == true;
      return null;
    default:
      throw MissingPluginException('未知历史操作：${call.method}');
  }
}
