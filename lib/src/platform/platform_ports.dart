import 'package:flutter/services.dart';

import '../common/constants/platform_capabilities.dart';

import 'platform_event.dart';

abstract interface class SelectionPort {
  Stream<PlatformEvent> get events;

  Future<String?> readSelectionForTranslation({required String sessionId});

  Future<String?> replaceSelection({
    required String sessionId,
    required String text,
  });

  Future<void> showInputFailure({
    required String sessionId,
    required String message,
  });
}

abstract interface class OverlayHost {
  Future<void> showOverlay({
    required String sessionId,
    required double x,
    required double y,
    double width,
    double height,
  });

  Future<void> hideOverlay({required String sessionId});

  Future<void> retainOverlay({required String sessionId});

  Future<void> setOverlaySize({
    required String sessionId,
    required double width,
    required double height,
  });

  Future<void> dragOverlay({required String sessionId});

  Future<void> showOverlayTooltip({
    required String sessionId,
    required String message,
    required double x,
    required double y,
    required double width,
    required double height,
    bool preferAbove = true,
  });

  Future<void> hideOverlayTooltip();

  Future<void> publishLiveRegion(Map<String, Object?> state);

  Future<void> publishScreenshotTranslation(Map<String, Object?> state);
}

abstract interface class SpeechPort {
  Future<bool> toggleSpeech({required String text, required String language});

  Future<void> stopSpeech();
}

abstract interface class TextServices {
  Future<String?> detectLanguage(String text);

  Future<String?> lookupDefinition(String text);
}

abstract interface class PerformanceMarks {
  Future<void> perfMark(String stage, Stopwatch watch);
}

abstract interface class AppHost {
  Future<Map<Object?, Object?>> loadSettings();

  Future<String> applicationSupportPath();

  Future<Set<PlatformCapability>> capabilities();

  Future<void> appReady();

  Future<void> appStartFailed(String message);

  void handleApplicationRequests(Future<Object?> Function(MethodCall) handler);

  Future<void> notifyHistoryChanged();
}
