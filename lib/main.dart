import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';

import 'src/capture/capture_app.dart';
import 'src/common/constants/channel_names.dart';
import 'src/common/constants/live_region.dart';
import 'src/common/constants/method_names.dart';
import 'src/history/history_app.dart';
import 'src/history/history_requests.dart';
import 'src/history/screenshot_history.dart';
import 'src/history/translation_history.dart';
import 'src/history/vocabulary.dart';
import 'src/platform/channel_platform_bridge.dart';
import 'src/screenshot/screenshot_app.dart';
import 'src/selection/selection_session.dart';
import 'src/selection/selection_translation_app.dart';
import 'src/settings/app_settings.dart';
import 'src/settings/permission_wizard_app.dart';
import 'src/settings/settings_app.dart';
import 'src/settings/settings_controller.dart';
import 'src/translation/live_region_session.dart';
import 'src/translation/provider_selection.dart';
import 'src/translation/translation_http.dart';
import 'src/common/constants/text_mode.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final bridge = ChannelPlatformBridge();
  try {
    await _startApplication(bridge);
  } catch (error) {
    await bridge.appStartFailed('$error');
    rethrow;
  }
}

Future<void> _startApplication(ChannelPlatformBridge bridge) async {
  final total = Stopwatch()..start();
  final stage = Stopwatch()..start();
  final initial = AppSettings.fromMap(await bridge.loadSettings());
  unawaited(bridge.perfMark('launch-dart-settings', stage));
  stage.reset();
  final support = await bridge.applicationSupportPath();
  Directory(support).createSync(recursive: true);
  final database = sqlite3.open('$support/translation_history.sqlite')
    ..execute('PRAGMA journal_mode=WAL');
  unawaited(bridge.perfMark('launch-dart-database', stage));
  final history = TranslationHistoryStore(
    database,
    onChanged: () => unawaited(bridge.notifyHistoryChanged()),
  );
  final screenshots = ScreenshotHistoryStore(
    database,
    Directory('$support/ScreenshotHistory'),
    onChanged: () => unawaited(bridge.notifyHistoryChanged()),
  );
  final vocabulary = VocabularyStore(
    database,
    onChanged: () => unawaited(bridge.notifyHistoryChanged()),
  );
  final session = SelectionSession(
    provider: providerForSettings(initial, bridge),
    inputProvider: providerForInput(initial, bridge),
    detectLanguage: bridge.detectLanguage,
    language: initial.direction,
    inputLanguage: initial.inputDirection,
    lookupDefinition: bridge.lookupDefinition,
  );
  final live = LiveRegionSession(
    providerFor: (settings) => providerForSettings(settings, bridge),
    detectLanguage: bridge.detectLanguage,
    clock: SystemLiveRegionClock(),
    onView: (view) {
      unawaited(bridge.publishLiveRegion(view.toMap()));
    },
  );
  final settings = SettingsController(
    initial: initial,
    platform: bridge,
    onSaved: (candidate) {
      final closedId = session.dismissIfServiceRemoved({
        for (final service in candidate.services) service.id,
      });
      if (closedId != null) {
        unawaited(bridge.stopSpeech());
        unawaited(bridge.hideOverlay(sessionId: closedId));
      }
      if (!session.isExpanded) session.dismiss();
      session.language = candidate.direction;
      session.inputLanguage = candidate.inputDirection;
      session.provider = providerForSettings(candidate, bridge);
      session.inputProvider = providerForInput(candidate, bridge);
      session.serviceChoices = () => serviceChoices(candidate);
      live.noteSettings(candidate);
    },
  );
  session.assistProviderFor = (mode) =>
      assistProviderForSettings(settings.current, bridge, mode);
  session.serviceProviderFor = (serviceId, mode) => mode == TextMode.translate
      ? providerForService(settings.current, bridge, serviceId)
      : assistProviderForService(settings.current, bridge, mode, serviceId);
  session.serviceChoices = () => serviceChoices(initial);

  void prewarm() {
    final origin = translationOrigin(settings.current);
    if (origin != null) unawaited(prewarmTranslationConnection(origin));
  }

  String? screenshotCapture;
  var screenshotGeneration = 0;
  final screenshotTranslation = LiveRegionSession(
    providerFor: (settings) => providerForSettings(settings, bridge),
    detectLanguage: bridge.detectLanguage,
    clock: SystemLiveRegionClock(),
    onView: (view) {
      final id = screenshotCapture;
      if (id == null) return;
      unawaited(
        bridge.publishScreenshotTranslation({'id': id, ...view.toMap()}),
      );
    },
  );

  bridge.handleApplicationRequests((call) async {
    switch (call.method) {
      case MethodNames.getSettings:
      case MethodNames.saveSettings:
      case MethodNames.saveDrawingPreferences:
      case MethodNames.saveRecordingOptions:
      case MethodNames.toggleAutomatic:
      case MethodNames.testService:
      case MethodNames.checkSystemTranslation:
        return settings.handle(call);
      case MethodNames.historyPage:
      case MethodNames.historyRecording:
      case MethodNames.setHistoryRecording:
      case MethodNames.historySources:
      case MethodNames.historyRetention:
      case MethodNames.setHistoryRetention:
      case MethodNames.deleteHistory:
      case MethodNames.clearHistory:
        return handleHistoryRequest(history, call);
      case MethodNames.vocabularyList:
      case MethodNames.deleteVocabulary:
      case MethodNames.vocabularyCsv:
        return handleVocabularyRequest(vocabulary, call);
      case MethodNames.recordScreenshotHistory:
      case MethodNames.screenshotHistoryList:
      case MethodNames.deleteScreenshotHistory:
      case MethodNames.clearScreenshotHistory:
      case MethodNames.screenshotHistoryRecording:
      case MethodNames.setScreenshotHistoryRecording:
      case MethodNames.addScreenshotHistory:
        return handleScreenshotHistoryRequest(
          screenshots,
          call,
          DateTime.now().millisecondsSinceEpoch,
        );
      case MethodNames.liveRegionCommand:
        final command = Map<Object?, Object?>.from(call.arguments as Map);
        final generation = command['generation'] as int;
        final action = LiveRegionAction.values.byName(
          command['action'] as String,
        );
        switch (action) {
          case LiveRegionAction.start:
            prewarm();
            live.start(settings.current, generation);
          case LiveRegionAction.pause:
            live.pause(generation);
          case LiveRegionAction.resume:
            live.resume(generation);
          case LiveRegionAction.end:
            live.end(generation);
          case LiveRegionAction.discard:
            live.discard(generation);
          case LiveRegionAction.captureFailed:
            live.captureUnavailable(generation, command['failure'] as String);
        }
        return null;
      case MethodNames.liveRegionOcr:
        final sample = Map<Object?, Object?>.from(call.arguments as Map);
        final blocks = <LiveTextBlock>[
          for (final item in sample['blocks'] as List? ?? const [])
            if (item is Map) LiveTextBlock.fromMap(item),
        ];
        await live.onOcr(
          LiveOcrSample(
            generation: sample['generation'] as int,
            text: sample['text'] as String?,
            failure: sample['failure'] as String?,
            blocks: blocks,
          ),
        );
        return null;
      case MethodNames.cancelScreenshotTranslation:
        final map = Map<Object?, Object?>.from(call.arguments as Map);
        if (screenshotCapture != map['id']) return null;
        screenshotCapture = null;
        screenshotGeneration += 1;
        screenshotTranslation.end(screenshotGeneration);
        return null;
      case MethodNames.prewarmTranslation:
        prewarm();
        return null;
      case MethodNames.translateScreenshotBlocks:
        final map = Map<Object?, Object?>.from(call.arguments as Map);
        screenshotCapture = map['id'] as String;
        screenshotGeneration += 1;
        screenshotTranslation.start(settings.current, screenshotGeneration);
        await screenshotTranslation.onOcr(
          LiveOcrSample(
            generation: screenshotGeneration,
            blocks: [
              for (final item in map['blocks'] as List)
                LiveTextBlock.fromMap(item as Map),
            ],
          ),
        );
        return null;
      default:
        throw MissingPluginException('未知应用操作：${call.method}');
    }
  });

  stage.reset();
  try {
    await bridge.applySettings(initial.toMap());
  } on PlatformException catch (error) {
    settings.error = error.message;
  }
  unawaited(bridge.perfMark('launch-dart-apply', stage));
  runApp(
    TranSnapApp(
      selection: bridge,
      overlay: bridge,
      speech: bridge,
      perf: bridge,
      session: session,
      history: history,
      vocabulary: vocabulary,
    ),
  );
  await bridge.appReady();
  unawaited(bridge.perfMark('launch-dart-ready', total));
}

@pragma('vm:entry-point')
Future<void> settingsMain() async {
  await _runWindow(const SettingsApp());
}

@pragma('vm:entry-point')
Future<void> screenshotMain() async {
  await _runWindow(const ScreenshotApp());
}

@pragma('vm:entry-point')
Future<void> captureMain() async {
  await _runWindow(const CaptureApp());
}

@pragma('vm:entry-point')
Future<void> permissionWizardMain() async {
  await _runWindow(const PermissionWizardApp());
}

@pragma('vm:entry-point')
Future<void> historyMain() async {
  await _runWindow(const HistoryApp());
}

Future<void> _runWindow(Widget app) async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(app);
  const startup = MethodChannel(ChannelNames.windowStartup);
  await startup.invokeMethod<void>(MethodNames.windowReady);
}
