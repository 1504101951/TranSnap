import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/channel_names.dart';
import 'package:transnap/src/common/constants/platform_capabilities.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/main.dart' as app;
import 'package:transnap/src/selection/selection_translation_app.dart';

void main() {
  testWidgets('截图翻译与设置提交等待期间，历史分页和关闭记录可独立完成', (tester) async {
    final detection = Completer<Map<String, Object?>>();
    final started = Completer<void>();
    final saving = Completer<void>();
    final saveStarted = Completer<void>();
    var holdSettings = false;
    final directory = Directory.systemTemp.createTempSync('history-channel-');
    const methods = MethodChannel(ChannelNames.platform);
    const events = MethodChannel(ChannelNames.platformEvents);
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case MethodNames.capabilities:
          return [for (final c in PlatformCapability.values) c.name];
        case MethodNames.loadSettings:
          return <String, Object>{};
        case MethodNames.applicationSupportPath:
          return directory.path;
        case MethodNames.applySettings:
          if (holdSettings) {
            saveStarted.complete();
            await saving.future;
          }
          return null;
        case MethodNames.credentialIds:
          return <String>[];
        case MethodNames.languageCandidates:
          started.complete();
          return detection.future;
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    await app.main();
    await tester.pump();
    final history = tester
        .widget<TranSnapApp>(find.byType(TranSnapApp))
        .history;
    addTearDown(() {
      history.database.close();
      directory.deleteSync(recursive: true);
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(events, null);
      methods.setMethodCallHandler(null);
    });

    Future<Object?> request(
      String name, [
      Map<String, Object> arguments = const {},
    ]) {
      final result = Completer<Object?>();
      unawaited(
        messenger.handlePlatformMessage(
          methods.name,
          codec.encodeMethodCall(MethodCall(name, arguments)),
          (reply) {
            try {
              result.complete(codec.decodeEnvelope(reply!));
            } catch (error, stack) {
              result.completeError(error, stack);
            }
          },
        ),
      );
      return result.future;
    }

    final translating = request(MethodNames.translateScreenshotBlocks, {
      'id': 'closed-shot',
      'blocks': [
        {
          'text': 'Hello',
          'x': 0.0,
          'y': 0.0,
          'width': 4.0,
          'height': 2.0,
          'segments': [],
        },
      ],
    });
    await started.future;
    holdSettings = true;
    final updating = request(MethodNames.toggleAutomatic);
    await saveStarted.future;
    await request(MethodNames.setHistoryRecording, {'enabled': false});
    expect(history.recordingEnabled, isFalse);
    expect(await request(MethodNames.historyPage, {'limit': 10}), isEmpty);
    await request(MethodNames.setHistoryRetention, {'days': 0});
    await request(MethodNames.setHistoryRecording, {'enabled': true});
    for (final stamp in [1, DateTime.now().millisecondsSinceEpoch]) {
      history.insert(
        sourceText: 'source',
        translatedText: '译文',
        detectedLanguage: 'en',
        targetLanguage: 'zh',
        providerId: 'test',
        completedAt: stamp,
        sourceLabel: 'Safari',
      );
    }
    expect(await request(MethodNames.historySources), ['Safari']);
    final filtered = await request(MethodNames.historyPage, {
      'query': '译文',
      'source': 'Safari',
      'from': 1,
      'to': 2,
    }) as List;
    expect(filtered, hasLength(1));
    expect(
      (await request(MethodNames.historyRetention, {'days': 30})
          as Map)['expiredCount'],
      1,
    );
    await request(MethodNames.setHistoryRetention, {'days': 30});
    expect(history.page(), hasLength(1));
    await request(MethodNames.deleteHistory, {'id': history.page().single.id});
    expect(history.page(), isEmpty);
    history.insert(
      sourceText: 'last',
      translatedText: '最后',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await request(MethodNames.clearHistory);
    expect(history.page(), isEmpty);
    await request(MethodNames.setHistoryRecording, {'enabled': false});
    expect(detection.isCompleted, isFalse);
    expect(saving.isCompleted, isFalse);
    saving.complete();
    await updating;
    await request(MethodNames.cancelScreenshotTranslation, {
      'id': 'closed-shot',
    });
    detection.complete({
      'candidates': [
        {'code': 'en', 'confidence': 0.9},
      ],
      'unchangedScripts': <String>[],
    });
    await translating;
    expect(history.page(), isEmpty);
  });
}
