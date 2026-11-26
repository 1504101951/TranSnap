import '../common/constants/method_names.dart';
import '../common/constants/channel_names.dart';
import '../common/constants/platform_capabilities.dart';

import 'package:flutter/services.dart';

import 'platform_event.dart';
import 'platform_ports.dart';
import 'settings_platform.dart';

class ChannelPlatformBridge
    implements
        SelectionPort,
        OverlayHost,
        SpeechPort,
        TextServices,
        PerformanceMarks,
        AppHost,
        SettingsPlatform {
  ChannelPlatformBridge({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel(ChannelNames.platform),
      _events = events ?? const EventChannel(ChannelNames.platformEvents);

  final MethodChannel _methods;
  final EventChannel _events;

  @override
  Stream<PlatformEvent> get events =>
      _events.receiveBroadcastStream().map((raw) {
        final map = Map<Object?, Object?>.from(raw as Map);
        return PlatformEvent.fromMap(map);
      });

  @override
  Future<void> notifyHistoryChanged() =>
      _methods.invokeMethod<void>(MethodNames.historyChanged);

  @override
  Future<void> publishLiveRegion(Map<String, Object?> state) =>
      _methods.invokeMethod<void>(MethodNames.publishLiveRegion, state);

  @override
  Future<void> publishScreenshotTranslation(Map<String, Object?> state) =>
      _methods.invokeMethod<void>(
        MethodNames.publishScreenshotTranslation,
        state,
      );

  @override
  Future<void> showOverlay({
    required String sessionId,
    required double x,
    required double y,
    double width = 240,
    double height = 140,
  }) {
    return _methods.invokeMethod<void>(MethodNames.showOverlay, {
      'sessionId': sessionId,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
    });
  }

  @override
  Future<void> hideOverlay({required String sessionId}) {
    return _methods.invokeMethod<void>(MethodNames.hideOverlay, {
      'sessionId': sessionId,
    });
  }

  @override
  Future<void> retainOverlay({required String sessionId}) {
    return _methods.invokeMethod<void>(MethodNames.retainOverlay, {
      'sessionId': sessionId,
    });
  }

  @override
  Future<void> setOverlaySize({
    required String sessionId,
    required double width,
    required double height,
  }) {
    return _methods.invokeMethod<void>(MethodNames.setOverlaySize, {
      'sessionId': sessionId,
      'width': width,
      'height': height,
    });
  }

  @override
  Future<void> dragOverlay({required String sessionId}) {
    return _methods.invokeMethod<void>(MethodNames.dragOverlay, {
      'sessionId': sessionId,
    });
  }

  @override
  Future<void> showOverlayTooltip({
    required String sessionId,
    required String message,
    required double x,
    required double y,
    required double width,
    required double height,
    bool preferAbove = true,
  }) => _methods.invokeMethod<void>(MethodNames.showOverlayTooltip, {
    'sessionId': sessionId,
    'message': message,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'preferAbove': preferAbove,
  });

  @override
  Future<void> hideOverlayTooltip() =>
      _methods.invokeMethod<void>(MethodNames.hideOverlayTooltip);

  @override
  Future<String?> readSelectionForTranslation({required String sessionId}) {
    return _methods.invokeMethod<String>(
      MethodNames.readSelectionForTranslation,
      {'sessionId': sessionId},
    );
  }

  @override
  Future<String?> replaceSelection({
    required String sessionId,
    required String text,
  }) => _methods.invokeMethod<String>(MethodNames.replaceSelection, {
    'sessionId': sessionId,
    'text': text,
  });

  @override
  Future<void> showInputFailure({
    required String sessionId,
    required String message,
  }) => _methods.invokeMethod<void>(MethodNames.showInputFailure, {
    'sessionId': sessionId,
    'message': message,
  });

  @override
  Future<bool> toggleSpeech({
    required String text,
    required String language,
  }) async => (await _methods.invokeMethod<bool>(MethodNames.toggleSpeech, {
    'text': text,
    'language': language,
  }))!;

  @override
  Future<void> stopSpeech() =>
      _methods.invokeMethod<void>(MethodNames.stopSpeech);

  @override
  Future<Map<Object?, Object?>> loadSettings() async => (await _methods
      .invokeMapMethod<Object?, Object?>(MethodNames.loadSettings))!;

  @override
  Future<String> applicationSupportPath() async => (await _methods
      .invokeMethod<String>(MethodNames.applicationSupportPath))!;

  @override
  Future<Set<PlatformCapability>> capabilities() async =>
      PlatformCapability.parse(
        (await _methods.invokeListMethod<Object?>(MethodNames.capabilities))!,
      );

  @override
  Future<void> applySettings(
    Map<String, Object> settings, {
    Map<String, Map<String, String>?> credentials = const {},
  }) => _methods.invokeMethod<void>(MethodNames.applySettings, {
    'settings': settings,
    'credentials': credentials,
  });

  @override
  Future<Map<String, String>> readCredentials(String id) async =>
      (await _methods.invokeMapMethod<String, String>(
        MethodNames.readCredentials,
        {'id': id},
      ))!;

  @override
  Future<List<String>> credentialIds(List<String> ids) async => (await _methods
      .invokeListMethod<String>(MethodNames.credentialIds, {'ids': ids}))!;

  @override
  void handleApplicationRequests(
    Future<Object?> Function(MethodCall) handler,
  ) => _methods.setMethodCallHandler(handler);

  @override
  Future<String?> detectLanguage(String text) =>
      _methods.invokeMethod<String>(MethodNames.detectLanguage, {'text': text});

  @override
  Future<String?> lookupDefinition(String text) => _methods
      .invokeMethod<String>(MethodNames.lookupDefinition, {'text': text});

  @override
  Future<void> appReady() => _methods.invokeMethod<void>(MethodNames.appReady);

  @override
  Future<void> perfMark(String stage, Stopwatch watch) =>
      _methods.invokeMethod<void>(MethodNames.perfMark, {
        'stage': stage,
        'ms': watch.elapsedMicroseconds / 1000,
      });

  @override
  Future<void> appStartFailed(String message) => _methods.invokeMethod<void>(
    MethodNames.appStartFailed,
    {'message': message},
  );
}
