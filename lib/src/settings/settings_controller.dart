import 'package:flutter/services.dart';

import '../common/constants/error_codes.dart';
import '../common/constants/method_names.dart';
import '../common/constants/preference_keys.dart';
import '../common/constants/system_translation.dart';
import '../common/constants/text_mode.dart';
import '../platform/settings_platform.dart';
import '../translation/providers/api_translation_provider.dart';
import '../translation/providers/apple_translation_provider.dart';
import '../translation/translation_types.dart';
import 'app_settings.dart';
import 'service_config.dart';

class SettingsController {
  SettingsController({
    required AppSettings initial,
    required this.platform,
    required this.onSaved,
  }) : _current = AppSettings.fromMap(initial.toMap());

  final SettingsPlatform platform;
  final void Function(AppSettings) onSaved;
  AppSettings _current;
  int _revision = 0;
  Future<void> _queue = Future.value();
  String? error;

  AppSettings get current => AppSettings.fromMap(_current.toMap());

  Future<Map<String, Object>> _snapshot() async => {
    ..._current.toMap(),
    PreferenceKeys.excludedApps: Map<String, String>.of(_current.excludedApps),
    'revision': _revision,
    MethodNames.credentialIds: await platform.credentialIds(
      _current.services.map((service) => service.id).toList(),
    ),
    'error': ?error,
  };

  Future<Map<String, Object>> _save(
    AppSettings candidate,
    Map<String, Map<String, String>?> drafts,
  ) async {
    candidate.validate();
    final credentials = await prepareCredentialChanges(
      previous: _current.services,
      current: candidate.services,
      drafts: drafts,
      readCredentials: platform.readCredentials,
    );
    await platform.applySettings(candidate.toMap(), credentials: credentials);
    onSaved(AppSettings.fromMap(candidate.toMap()));
    _current = candidate;
    error = null;
    _revision += 1;
    return _snapshot();
  }

  Future<Object?> handle(MethodCall call) {
    final operation = _queue.then<Object?>((_) async {
      switch (call.method) {
        case MethodNames.getSettings:
          return _snapshot();
        case MethodNames.saveSettings:
          final map = Map<Object?, Object?>.from(call.arguments as Map);
          if (map['revision'] != _revision) {
            throw PlatformException(
              code: ErrorCodes.settingsConflict,
              message: '设置已在其他入口更新，请重新加载后再保存。',
            );
          }
          final drafts = (map['credentials'] as Map? ?? {}).map(
            (id, value) => MapEntry(
              id as String,
              value == null ? null : Map<String, String>.from(value as Map),
            ),
          );
          try {
            return await _save(AppSettings.fromMap(map), drafts);
          } on FormatException catch (error) {
            throw PlatformException(
              code: ErrorCodes.invalidSettings,
              message: error.message,
            );
          }
        case MethodNames.saveDrawingPreferences:
          return _save(
            AppSettings.fromMap({
              ..._current.toMap(),
              PreferenceKeys.screenshotDrawing: call.arguments,
            }),
            {},
          );
        case MethodNames.saveRecordingOptions:
          final options = call.arguments as Map;
          return _save(
            AppSettings.fromMap({
              ..._current.toMap(),
              PreferenceKeys.recordingDelay:
                  options[PreferenceKeys.recordingDelay],
              PreferenceKeys.recordingClickEffect:
                  options[PreferenceKeys.recordingClickEffect],
            }),
            {},
          );
        case MethodNames.toggleAutomatic:
          return _save(
            AppSettings.fromMap({
              ..._current.toMap(),
              PreferenceKeys.automatic: !_current.automatic,
            }),
            {},
          );
        case MethodNames.testService:
          return _testService(call.arguments);
        case MethodNames.checkSystemTranslation:
          return _checkSystemTranslation();
        default:
          throw MissingPluginException('未知设置操作：${call.method}');
      }
    });
    _queue = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  Future<String> _testService(Object? arguments) async {
    final map = Map<Object?, Object?>.from(arguments as Map);
    final config = ServiceConfig.fromMap(
      Map<Object?, Object?>.from(map['config'] as Map),
    );
    final credentials = {
      ...await platform.readCredentials(config.id),
      ...Map<String, String>.from(map['credentials'] as Map),
    };
    final provider = ApiTranslationProvider(
      config: config,
      credentials: () async => credentials,
      prompt: _current.prompts[TextMode.translate]!,
      thinking: _current.thinking[TextMode.translate]!,
      semanticPairs: config.semanticPairs,
    );
    final result = StringBuffer();
    var completed = false;
    await for (final event in provider.translate(
      const TranslationRequest(
        sourceText: 'Hello world.',
        detectedLanguage: 'en',
        targetLanguage: 'zh-CN',
      ),
    )) {
      switch (event) {
        case TranslationUpdate(:final addition):
          result.write(addition);
        case TranslationCompleted():
          completed = true;
        case TranslationFailure(:final message):
          throw PlatformException(
            code: ErrorCodes.testFailed,
            message: message,
          );
      }
    }
    if (!completed) {
      throw PlatformException(
        code: ErrorCodes.testFailed,
        message: incompleteTranslationMessage,
      );
    }
    return result.toString();
  }

  Future<String> _checkSystemTranslation() async {
    final direction = _current.direction;
    final primary = direction.primaryCode;
    final secondary = direction.secondaryCode;
    final pairs = [
      if (secondary != null) ...[(primary, secondary), (secondary, primary)],
      if (secondary == null && primary != 'en') ('en', primary),
    ];
    if (pairs.isEmpty) return '主要语言为英文且未设置次要语言，翻译时按原文语言检查语言包。';
    final statuses = await AppleTranslationProvider().statuses(pairs);
    final labels = [
      for (final (source, target) in pairs)
        AppleTranslationProvider.pairLabel(source, target),
    ];
    final unsupported = [
      for (final (index, status) in statuses.indexed)
        if (status == SystemTranslationStatus.unsupported) labels[index],
    ];
    if (unsupported.isNotEmpty) {
      throw PlatformException(
        code: ErrorCodes.testFailed,
        message: 'Apple 系统翻译不支持：${unsupported.join('、')}。',
      );
    }
    final missing = [
      for (final (index, status) in statuses.indexed)
        if (status == SystemTranslationStatus.supported) labels[index],
    ];
    if (missing.isNotEmpty) {
      throw PlatformException(
        code: ErrorCodes.testFailed,
        message:
            '缺少语言包：${missing.join('、')}。${AppleTranslationProvider.downloadHint}',
      );
    }
    return '语言包已安装：${labels.join('、')}';
  }
}
