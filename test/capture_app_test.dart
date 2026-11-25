import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:transnap/src/capture/capture_app.dart';
import 'package:transnap/src/common/constants/channel_names.dart';
import 'package:transnap/src/common/constants/glass_metrics.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/preference_keys.dart';
import 'package:transnap/src/common/constants/screenshot_actions.dart';
import 'package:transnap/src/common/widgets/app_motion.dart';
import 'package:transnap/src/common/widgets/app_tooltip.dart';
import 'package:transnap/src/screenshot/screenshot_app.dart';
import 'package:transnap/src/settings/screenshot_toolbar_preferences.dart';
import 'package:transnap/src/common/constants/toolbar_grid.dart';

import 'support/capture_pixels.dart';
import 'support/line_icons.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, Object?> state;

  Future<void> notify(WidgetTester tester, Map<String, Object?> next) async {
    state = next;
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(MethodNames.captureStateChanged, state),
      ),
      (_) {},
    );
    await tester.pump();
  }

  setUp(() {
    state = {'id': 'session', 'phase': 'idle'};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.setCapturePaused) {
        final paused = (call.arguments as Map)['paused'] == true;
        state = {...state, 'phase': paused ? 'paused' : state['kind']};
      }
      if (call.method == MethodNames.stopCapture &&
          ['recording', 'scrolling', 'paused'].contains(state['phase'])) {
        state = {...state, 'phase': 'finalizing'};
      }
      if (call.method == MethodNames.cancelCapture) {
        state = {'id': 'new-session', 'phase': 'idle'};
      }
      return state;
    });
    messenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (_) async => null,
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  testWidgets('实时翻译同时录制时状态气泡完整显示「录制：时长 · 识别状态」，不截断（#67）', (tester) async {
    tester.view.physicalSize = const Size(400, 84);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state = {
      'id': 'live',
      'kind': 'liveTranslation',
      'phase': 'recording',
      'recording': true,
      'elapsed': 12.0,
      'detail': '未识别到文字',
    };
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pumpAndSettle();
    const label = '录制：0:12 · 未识别到文字';
    expect(find.text(label), findsOneWidget);
    expect(
      tester.renderObject<RenderParagraph>(find.text(label)).didExceedMaxLines,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('两种采集共用四个独立气泡，上方提示且暂停放弃保持契约', (tester) async {
    tester.view.physicalSize = const Size(320, 84);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Finder findAppTooltip(String message) => find.byWidgetPredicate(
      (widget) => widget is AppTooltip && widget.message == message,
    );
    for (final kind in ['recording', 'scrolling']) {
      await tester.pumpWidget(const SizedBox.shrink());
      final tooltipCalls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == MethodNames.showOverlayTooltip ||
            call.method == MethodNames.hideOverlayTooltip) {
          tooltipCalls.add(call);
          return null;
        }
        if (call.method == MethodNames.setCapturePaused) {
          final paused = (call.arguments as Map)['paused'] == true;
          state = {...state, 'phase': paused ? 'paused' : state['kind']};
        }
        if (call.method == MethodNames.stopCapture &&
            ['recording', 'scrolling', 'paused'].contains(state['phase'])) {
          state = {...state, 'phase': 'finalizing'};
        }
        if (call.method == MethodNames.cancelCapture) {
          state = {'id': 'new-session', 'phase': 'idle'};
        }
        return state;
      });
      state = {
        'id': kind,
        'kind': kind,
        'phase': kind,
        'elapsed': 65.0,
        'height': 512,
      };
      await tester.pumpWidget(const CaptureApp(channel: channel));
      await tester.pumpAndSettle();
      expect(find.byType(IconButton), findsNWidgets(3));
      final label = kind == 'recording' ? '录制：1:05' : '长截图：512 像素';
      expect(find.byType(AppKitView), findsNWidgets(4));
      for (final tooltip in tester.widgetList<AppTooltip>(
        find.byType(AppTooltip),
      )) {
        expect(tooltip.preferAbove, isTrue);
      }
      expect(find.text(label), findsOneWidget);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(findAppTooltip('暂停')));
      await tester.pump(const Duration(milliseconds: 220));
      expect(
        tooltipCalls.where(
          (call) =>
              call.method == MethodNames.showOverlayTooltip &&
              (call.arguments as Map)['message'] == '暂停' &&
              (call.arguments as Map)['preferAbove'] == true,
        ),
        hasLength(1),
      );
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(
        tooltipCalls.where(
          (call) => call.method == MethodNames.hideOverlayTooltip,
        ),
        hasLength(1),
      );
      await mouse.removePointer();
      await notify(tester, {
        ...state,
        'error': '相邻画面缺少稳定的重叠内容，请减小单次滚动幅度或避开动态内容。已保留确认部分。',
      });
      final feedback = find.byKey(const Key('toolbar-feedback-bubble'));
      final feedbackRect = tester.getRect(feedback);
      expect(feedbackRect.height, greaterThanOrEqualTo(28));
      for (final action in ['暂停', '结束', '放弃']) {
        final button = findAppTooltip(action);
        expect(button.hitTestable(), findsOneWidget);
        expect(feedbackRect.overlaps(tester.getRect(button)), isFalse);
      }
      await tester.pump(const Duration(seconds: 1));
      expect(feedback, findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(feedback, findsNothing);
      await tester.tap(findAppTooltip('暂停'));
      await tester.pumpAndSettle();
      expect(find.text('已暂停 · $label'), findsOneWidget);
      expect(findAppTooltip('开始'), findsOneWidget);
      await tester.tap(findAppTooltip('开始'));
      await tester.pumpAndSettle();
      expect(find.text(label), findsOneWidget);
      await tester.tap(findAppTooltip('结束'));
      await tester.pumpAndSettle();
      expect(find.text('正在完成采集…'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: findLineIcon(LucideIcons.square),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: findLineIcon(LucideIcons.pause),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(findAppTooltip('放弃'));
      await tester.pumpAndSettle();
      expect(find.byType(IconButton), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('视频结果等比显示源逻辑尺寸，采用中性衬底与52pt底部操作栏骨架', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final invoked = <(String, Object?)>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      invoked.add((call.method, call.arguments));
      return state;
    });
    state = {
      'id': 'video-result',
      'phase': 'videoReady',
      'duration': 9.45,
      'position': 2.0,
      'playing': false,
      'width': 1706,
      'height': 868,
      'previewScale': 2.0,
    };
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pumpAndSettle();
    final video = find.byWidgetPredicate(
      (widget) =>
          widget is AppKitView &&
          widget.viewType == ChannelNames.captureVideoPreview,
    );
    expect(tester.getSize(video), const Size(853, 434));
    expect(find.byKey(const Key('result-window-canvas')), findsOneWidget);
    final bar = find.byKey(const Key('result-window-bar'));
    expect(bar, findsOneWidget);
    final viewport = Offset.zero & const Size(1200, 900);
    final barRect = tester.getRect(bar);
    final media = tester.getRect(video);
    expect(barRect.height, GlassMetrics.resultBarHeight);
    expect(barRect.bottom, viewport.bottom);
    expect(media.overlaps(barRect), isFalse);
    expect(media.bottom, lessThanOrEqualTo(barRect.top - 24));
    for (final key in [
      const Key('result-discard'),
      const Key('result-play-toggle'),
      const Key('result-video-slider'),
      const Key('result-trim'),
      const Key('result-copy'),
      const Key('result-export-menu'),
      const Key('result-save'),
    ]) {
      final rect = tester.getRect(find.byKey(key));
      expect(barRect.contains(rect.topLeft), isTrue);
      expect(barRect.contains(rect.bottomRight), isTrue);
    }
    expect(find.text('放弃'), findsOneWidget);
    expect(find.text('裁剪'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('导出'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(find.text('0:02'), findsOneWidget);
    expect(find.text('0:09'), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const Key('result-discard'))).right,
      lessThan(tester.getRect(find.byKey(const Key('result-play-toggle'))).left),
    );
    expect(
      tester.getRect(find.byKey(const Key('result-trim'))).right,
      lessThan(tester.getRect(find.byKey(const Key('result-copy'))).left),
    );
    expect(
      tester.getRect(find.byKey(const Key('result-export-menu'))).right,
      lessThan(tester.getRect(find.byKey(const Key('result-save'))).left),
    );
    invoked.clear();
    await tester.tap(find.byKey(const Key('result-play-toggle')));
    await tester.pumpAndSettle();
    expect(
      invoked.any((e) => e.$1 == MethodNames.toggleRecordingPlayback),
      isTrue,
    );
    await tester.tap(find.byKey(const Key('result-export-menu')));
    await tester.pumpAndSettle();
    expect(find.text('导出 GIF'), findsOneWidget);
    expect(find.text('导出 APNG'), findsOneWidget);
    expect(find.text('导出 WebM'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == 'NativeGlassWindowPage',
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('受限视频窗口为四周24pt衬底与52pt底部栏保留外边距且不裁剪媒体', (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state = {
      'id': 'large-video',
      'phase': 'videoReady',
      'duration': 5.0,
      'width': 3840,
      'height': 2160,
      'previewScale': 1.0,
    };
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pumpAndSettle();
    final media = tester.getRect(
      find.byWidgetPredicate(
        (widget) =>
            widget is AppKitView &&
            widget.viewType == ChannelNames.captureVideoPreview,
      ),
    );
    final bar = tester.getRect(find.byKey(const Key('result-window-bar')));
    expect(media.width / media.height, closeTo(16 / 9, 0.001));
    expect(media.left, greaterThanOrEqualTo(24));
    expect(media.top, greaterThanOrEqualTo(24));
    expect(media.bottom, lessThanOrEqualTo(bar.top - 24));
    for (final key in [
      const Key('result-discard'),
      const Key('result-play-toggle'),
      const Key('result-trim'),
      const Key('result-copy'),
      const Key('result-export-menu'),
      const Key('result-save'),
    ]) {
      expect(find.byKey(key).hitTestable(), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭与Escape单击放弃，转换中仍能关闭', (tester) async {
    tester.view.physicalSize = const Size(600, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state = {
      'id': 'closing-result',
      'phase': 'videoReady',
      'duration': 3.0,
      'width': 32,
      'height': 1000,
      'previewScale': 1.0,
    };
    final resultState = Map<String, Object?>.of(state);
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('result-discard')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('result-window-bar')), findsNothing);
    expect(tester.takeException(), isNull);
    await notify(tester, resultState);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('result-window-bar')), findsNothing);
    tester.view.physicalSize = const Size(900, 600);
    await notify(tester, {
      ...resultState,
      'id': 'closing-conversion',
      'phase': 'converting',
      'exporting': 'gif',
      'progress': 0.5,
    });
    await tester.pump();
    await tester.tap(find.byKey(const Key('result-discard')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('result-window-bar')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MP4后台保存只显示保存状态，防重复且保留取消与关闭入口', (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state = {
      'id': 'saving-video',
      'phase': 'videoReady',
      'previewScale': 1.0,
      'duration': 1.0,
      'width': 640,
      'height': 480,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.saveRecording) {
        state = {...state, 'phase': 'converting', 'exporting': 'mp4'};
      }
      if (call.method == MethodNames.cancelRecordingExport) {
        state = {...state, 'phase': 'videoReady', 'error': '保存已取消，源视频保持不变。'};
      }
      if (call.method == MethodNames.cancelCapture) {
        state = {'id': 'after-saving', 'phase': 'idle'};
      }
      return state;
    });
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('result-save')));
    await tester.pump();
    BusyRing ringOf(Key key) => tester.widget<BusyRing>(
      find.ancestor(of: find.byKey(key), matching: find.byType(BusyRing)).first,
    );
    expect(ringOf(const Key('result-cancel-save')).active, isTrue);
    expect(find.text('正在保存…'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    expect(find.byKey(const Key('result-save')), findsNothing);
    expect(
      tester.widget<IconButton>(find.byKey(const Key('result-play-toggle'))).onPressed,
      isNull,
    );
    for (final key in [
      const Key('result-trim'),
      const Key('result-copy'),
      const Key('result-export-menu'),
    ]) {
      expect(tester.widget<TextButton>(find.byKey(key)).onPressed, isNull);
    }
    expect(
      tester.widget<TextButton>(find.byKey(const Key('result-discard'))).onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('result-cancel-save')));
    await tester.pump();
    expect(ringOf(const Key('result-save')).active, isFalse);
    expect(find.text('保存已取消，源视频保持不变。'), findsOneWidget);
    expect(
      tester.widget<TextButton>(find.byKey(const Key('result-save'))).onPressed,
      isNotNull,
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byKey(const Key('result-save')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('result-discard')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('result-window-bar')), findsNothing);
    expect(find.text('正在保存…'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GIF从导出菜单发起，取消和保存反馈在工具栏外停留对应时长', (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state = {
      'id': 'video',
      'phase': 'videoReady',
      'previewScale': 1.0,
      'duration': 1.234567,
      'width': 640,
      'height': 480,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.exportRecordingGIF) {
        state = {
          ...state,
          'phase': 'converting',
          'exporting': 'gif',
          'progress': 0.5,
        };
      }
      if (call.method == MethodNames.cancelRecordingExport) {
        state = {...state, 'phase': 'videoReady', 'error': '转换已取消，源视频保持不变。'};
      }
      if (call.method == MethodNames.saveRecording) {
        state = {
          ...state,
          'error': null,
          'savedPath': '/截图/视频/2026-10-01/录屏.mp4',
        };
      }
      return state;
    });
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byKey(const Key('result-export-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出 GIF'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('正在转换 50%'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byKey(const Key('result-cancel-export')));
    await tester.pump();
    final bubble = find.byKey(const Key('toolbar-feedback-bubble'));
    expect(find.textContaining('源视频保持不变'), findsOneWidget);
    expect(
      tester
          .getRect(bubble)
          .overlaps(tester.getRect(find.byKey(const Key('result-window-bar')))),
      isFalse,
    );
    await tester.pump(const Duration(milliseconds: 1999));
    expect(bubble, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(bubble, findsNothing);
    await tester.tap(find.byKey(const Key('result-save')));
    await tester.pump();
    expect(find.text('已保存 MP4'), findsOneWidget);
    expect(
      tester
          .getRect(bubble)
          .overlaps(tester.getRect(find.byKey(const Key('result-save')))),
      isFalse,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(bubble, findsNothing);
    expect(find.byKey(const Key('result-play-toggle')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('裁剪期间全部操作等待；APNG/WebM 转换将导出按钮变为取消，完成后提示对应保存结果', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state = {
      'id': 'trim-video',
      'phase': 'videoReady',
      'previewScale': 1.0,
      'duration': 2.0,
      'width': 640,
      'height': 480,
    };
    final trimming = Completer<void>();
    const exports = [
      (
        MethodNames.exportRecordingAPNG,
        'apng',
        '导出 APNG',
        'apngPath',
        '/截图/apng/2026-10-21/录屏-20261021-120000.png',
        '已保存 APNG',
      ),
      (
        MethodNames.exportRecordingWebM,
        'webm',
        '导出 WebM',
        'webmPath',
        '/截图/webm/2026-10-22/录屏-20261022-120000.webm',
        '已保存 WebM',
      ),
    ];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.trimRecording) await trimming.future;
      for (final (method, exporting, _, _, _, _) in exports) {
        if (call.method != method) continue;
        state = {
          ...state,
          'phase': 'converting',
          'exporting': exporting,
          'progress': 0.25,
        };
      }
      return state;
    });
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('result-trim')));
    await tester.pump();
    for (final key in [
      const Key('result-discard'),
      const Key('result-trim'),
      const Key('result-copy'),
      const Key('result-export-menu'),
      const Key('result-save'),
    ]) {
      expect(tester.widget<TextButton>(find.byKey(key)).onPressed, isNull);
    }
    trimming.complete();
    await tester.pumpAndSettle();
    for (final key in [
      const Key('result-discard'),
      const Key('result-trim'),
      const Key('result-copy'),
      const Key('result-export-menu'),
      const Key('result-save'),
    ]) {
      expect(tester.widget<TextButton>(find.byKey(key)).onPressed, isNotNull);
    }

    for (final (_, _, menuLabel, pathKey, path, feedback) in exports) {
      await tester.tap(find.byKey(const Key('result-export-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(menuLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('正在转换 25%'), findsOneWidget);
      expect(
        tester
            .widget<BusyRing>(
              find
                  .ancestor(
                    of: find.byKey(const Key('result-cancel-export')),
                    matching: find.byType(BusyRing),
                  )
                  .first,
            )
            .active,
        isTrue,
      );
      expect(
        tester.widget<TextButton>(find.byKey(const Key('result-save'))).onPressed,
        isNull,
      );
      expect(
        tester.widget<TextButton>(find.byKey(const Key('result-discard'))).onPressed,
        isNotNull,
      );
      await notify(tester, {
        ...state,
        'phase': 'videoReady',
        'exporting': null,
        pathKey: path,
      });
      expect(find.text(feedback), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('result-export-menu')))
            .onPressed,
        isNotNull,
      );
      await tester.pump(const Duration(seconds: 1));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('截图组动态目标行沿用裁剪区域，取消准备保留编辑', (tester) async {
    final png = await tester.runAsync(_selectionImage);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const selectionChannel = MethodChannel('test/toolbar-capture');
    Map? selected;
    messenger.setMockMethodCallHandler(selectionChannel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'toolbar-selection',
          ...capture!,
          'width': 320,
          'height': 240,
          'canCaptureMedia': true,
        };
      }
      if (call.method == MethodNames.prepareCapture) {
        selected = call.arguments as Map;
        return null;
      }
      if (call.method == MethodNames.closeScreenshot) {
        await messenger.handlePlatformMessage(
          selectionChannel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall(
              MethodNames.screenshotChanged,
              <String, Object?>{},
            ),
          ),
          (_) {},
        );
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(selectionChannel, null),
    );
    for (final scrolling in [false, true]) {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(const ScreenshotApp(channel: selectionChannel));
      await awaitCaptureSource(tester);
      await tester.pumpAndSettle();
      await showFullToolbar(tester);
      final canvas = tester.getRect(find.byKey(const Key('screenshot-canvas')));
      await tester.dragFrom(
        canvas.topLeft + Offset(canvas.width / 4, canvas.height / 4),
        Offset(canvas.width / 2, canvas.height / 2),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('截图 1'), findsOneWidget);
      await revealToolbarChildren(tester);
      final children = find.byKey(const Key('screenshot-children-group-0'));
      expect(
        find.descendant(of: children, matching: find.byTooltip('滚动长截图')),
        findsOneWidget,
      );
      final first = find.byKey(const Key('screenshot-grid-group-0'));
      final horizontal =
          tester.widget<Flex>(first).direction == Axis.horizontal;
      expect(
        horizontal
            ? tester.getRect(children).top
            : tester.getRect(children).left,
        (horizontal
                ? tester.getRect(first).bottom
                : tester.getRect(first).right) +
            ToolbarGrid.blockPadding +
            ToolbarGrid.lineGap +
            ToolbarGrid.trayPadding,
      );
      if (scrolling) {
        await tester.tap(find.byKey(const Key(ScreenshotActions.scrolling)));
      } else {
        await tester.tap(find.byKey(const Key(ScreenshotActions.record)));
        await tester.pumpAndSettle();
        expect(find.byTooltip('全屏'), findsOneWidget);
        expect(find.byTooltip('窗口'), findsOneWidget);
        final targetRow = find.byKey(const Key('recording-targets-row'));
        expect(targetRow, findsOneWidget);
        expect(
          find.descendant(of: targetRow, matching: find.byType(IconButton)),
          findsNWidgets(7),
        );
        expect(
          find.descendant(of: targetRow, matching: find.byType(AppKitView)),
          findsNothing,
        );
        await messenger.handlePlatformMessage(
          selectionChannel.name,
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall(MethodNames.escapePressed),
          ),
          (_) {},
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('recording-targets-row')), findsNothing);
        expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);
        await tester.tap(find.byKey(const Key(ScreenshotActions.record)));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('当前选区'));
      }
      await tester.pumpAndSettle();
      if (!scrolling) await tester.tap(find.byTooltip('开始录制'));
      await tester.pumpAndSettle();
      expect(selected!['x'], closeTo(80, 1));
      expect(selected!['y'], closeTo(60, 1));
      expect(selected!['width'], closeTo(160, 1));
      expect(selected!['height'], closeTo(120, 1));
      expect(selected!['delay'], scrolling ? isNull : 0);
      expect(find.byTooltip('开始长截图'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('窗口目标增加应用图标行，切换清空选择且长列表可滚动访问', (tester) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final png = await tester.runAsync(_selectionImage);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const sourceChannel = MethodChannel('test/application-toolbar');
    final semantics = tester.ensureSemantics();
    Map? submitted;
    messenger.setMockMethodCallHandler(sourceChannel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'apps',
          'captureDisplayX': -100,
          'captureDisplayY': -50,
          ...capture!,
          'width': 320,
          'height': 240,
          'canCaptureMedia': true,
          'displayWidth': 320,
          'displayHeight': 600,
          'toolbarSafeX': 0,
          'toolbarSafeY': 24,
          'toolbarSafeWidth': 320,
          'toolbarSafeHeight': 528,
        };
      }
      if (call.method == MethodNames.captureSources) {
        return [
          for (var index = 0; index < 25; index++)
            {
              'applicationID': 'app.$index',
              'name': index == 0 ? '当前应用' : '应用$index',
              if (index != 1) 'icon': png,
              'windows': [
                {'x': -60.0, 'y': -30.0, 'width': 120.0, 'height': 80.0},
              ],
            },
        ];
      }
      if (call.method == MethodNames.prepareCapture) {
        submitted = call.arguments as Map;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(sourceChannel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: sourceChannel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    await showFullToolbar(tester);
    await revealToolbarChildren(tester);
    final canvasBefore = tester.getRect(
      find.byKey(const Key('screenshot-canvas')),
    );
    await tester.tap(find.byKey(const Key(ScreenshotActions.record)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('窗口'));
    await tester.pumpAndSettle();
    final apps = find.byKey(const Key('recording-applications-row'));
    expect(apps, findsOneWidget);
    expect(find.byTooltip('当前应用').hitTestable(), findsOneWidget);
    expect(find.byTooltip('应用1'), findsOneWidget);
    expect(
      find.descendant(of: apps, matching: findLineIcon(LucideIcons.layoutGrid)),
      findsOneWidget,
    );

    IconButton startButton() => tester.widget<IconButton>(
      find.descendant(
        of: find.byTooltip('开始录制'),
        matching: find.byType(IconButton),
      ),
    );
    expect(startButton().onPressed, isNull);
    await tester.tap(find.byTooltip('当前应用'));
    await tester.pumpAndSettle();
    expect(startButton().onPressed, isNotNull);
    expect(tester.getSemantics(find.byTooltip('当前应用')).label, contains('当前应用'));
    final preview =
        tester
                .widgetList<CustomPaint>(find.byType(CustomPaint))
                .map((widget) => widget.painter)
                .singleWhere(
                  (painter) => painter.runtimeType.toString() == '_DimPainter',
                )
            as dynamic;
    expect(preview.cropDisplay, canvasBefore);
    expect(preview.showHandles, isFalse);
    expect(preview.windows, [
      Rect.fromLTWH(
        canvasBefore.left + canvasBefore.width / 8,
        canvasBefore.top + canvasBefore.height / 12,
        canvasBefore.width * 3 / 8,
        canvasBefore.height / 3,
      ),
    ]);
    final safe = const Rect.fromLTWH(0, 24, 320, 528);
    for (final row in [apps, find.byKey(const Key('recording-targets-row'))]) {
      final rect = tester.getRect(row);
      expect(safe.contains(rect.topLeft), isTrue);
      expect(safe.contains(rect.bottomRight), isTrue);
    }
    await tester.drag(apps, const Offset(-1000, 0));
    await tester.pumpAndSettle();
    expect(find.byTooltip('应用24').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('应用24'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('开始录制'));
    await tester.pumpAndSettle();
    expect(submitted?['kind'], 'application');
    expect(submitted?['applicationID'], 'app.24');
    await tester.tap(find.byTooltip('全屏'));
    await tester.pumpAndSettle();
    final fullscreen =
        tester
                .widgetList<CustomPaint>(find.byType(CustomPaint))
                .map((widget) => widget.painter)
                .singleWhere(
                  (painter) => painter.runtimeType.toString() == '_DimPainter',
                )
            as dynamic;
    expect(fullscreen.cropDisplay, canvasBefore);
    expect(fullscreen.windows, isNull);

    expect(apps, findsNothing);
    await tester.tap(find.byTooltip('窗口'));
    await tester.pumpAndSettle();
    expect(apps, findsOneWidget);
    expect(startButton().onPressed, isNull);
    expect(
      tester.getRect(find.byKey(const Key('screenshot-canvas'))),
      canvasBefore,
    );
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('长图结果保留来源逻辑宽度并支持适合宽度与实际大小切换，底部栏提供放弃缩放复制保存', (tester) async {
    tester.view.physicalSize = const Size(700, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final png = await tester.runAsync(
      () => _selectionImage(width: 1600, height: 2400),
    );
    String? copiedId;
    String? savedName;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getCaptureState) return state;
      if (call.method == MethodNames.copyScreenshot) {
        copiedId = (call.arguments as Map)['id'] as String;
        return state;
      }
      if (call.method == MethodNames.saveScreenshot) {
        savedName = (call.arguments as Map)['name'] as String;
        state = {...state, 'savedPath': '/截图/2026-10-02/$savedName'};
        return state;
      }
      return state;
    });
    state = {
      'id': 'long-image',
      'phase': 'imageReady',
      'kind': 'scrolling',
      'width': 1600,
      'height': 2400,
      'previewScale': 2.0,
      'imageBytes': png,
      'warning': '相邻画面缺少稳定的重叠内容，请减小单次滚动幅度或避开动态内容。已保留确认部分。',
    };
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pump();
    final preview = find.byKey(const Key('long-image-preview'));
    final fitSize = tester.getSize(preview);
    expect(fitSize.width, closeTo(652, 0.01));
    expect(fitSize.height, closeTo(978, 0.01));
    expect(find.textContaining('相邻画面缺少稳定的重叠内容'), findsOneWidget);
    expect(find.byKey(const Key('screenshot-canvas')), findsNothing);
    await tester.tap(find.byKey(const Key('result-zoom-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('实际大小'));
    await tester.pumpAndSettle();
    expect(tester.getSize(preview), const Size(800, 1200));
    tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const Key('long-image-scroll')),
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .jumpTo(400);
    await tester.pump();
    expect(tester.getSize(preview), const Size(800, 1200));
    expect(tester.getTopLeft(preview).dy, -376);
    final bar = tester.getRect(find.byKey(const Key('result-window-bar')));
    for (final key in [
      const Key('result-discard'),
      const Key('result-zoom-menu'),
      const Key('result-copy'),
      const Key('result-save'),
    ]) {
      final rect = tester.getRect(find.byKey(key));
      expect(bar.contains(rect.topLeft), isTrue);
      expect(bar.contains(rect.bottomRight), isTrue);
    }
    await tester.tap(find.byKey(const Key('result-copy')));
    await tester.pump();
    expect(copiedId, 'long-image');
    expect(find.text('已复制'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('相邻画面缺少稳定的重叠内容'), findsNothing);
    await tester.tap(find.byKey(const Key('result-save')));
    await tester.pump();
    expect(savedName, startsWith('截图_'));
    expect(savedName, endsWith('.png'));
    expect(find.text('已保存截图'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('媒体结果图片不能作为屏幕选区启动采集', (tester) async {
    final png = await tester.runAsync(_selectionImage);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const selectionChannel = MethodChannel('test/image-capture-boundary');
    messenger.setMockMethodCallHandler(selectionChannel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'image-result',
          ...capture!,
          'width': 320,
          'height': 240,
          'canCaptureMedia': false,
        };
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(selectionChannel, null),
    );
    await tester.pumpWidget(const ScreenshotApp(channel: selectionChannel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    await revealToolbarChildren(tester);
    for (final action in [
      ScreenshotActions.record,
      ScreenshotActions.scrolling,
    ]) {
      expect(
        tester.widget<IconButton>(find.byKey(Key(action))).onPressed,
        isNull,
      );
    }
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);
  });

  testWidgets('实时翻译同步录制时控制条在翻译状态前显示录制时长', (tester) async {
    tester.view.physicalSize = const Size(320, 84);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state = {
      'id': 'live',
      'kind': 'liveTranslation',
      'phase': 'recording',
      'recording': true,
      'elapsed': 65.0,
      'detail': '正在翻译',
    };
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.text('录制：1:05 · 正在翻译'), findsOneWidget);
    await notify(tester, {...state, 'recording': false, 'elapsed': 0});
    await tester.pumpAndSettle();
    expect(find.text('正在翻译'), findsOneWidget);
    expect(find.textContaining('录制'), findsNothing);
  });

  testWidgets('录制倒计时期间状态气泡显示剩余秒数，只能放弃（#129）', (tester) async {
    tester.view.physicalSize = const Size(320, 84);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state = {
      'id': 'countdown',
      'kind': 'recording',
      'phase': 'preparing',
      'countdown': 3,
    };
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.text('3 秒后开始'), findsOneWidget);
    VoidCallback? press(String description) => tester
        .widget<IconButton>(
          find.descendant(
            of: find.byWidgetPredicate(
              (widget) => widget is AppTooltip && widget.message == description,
            ),
            matching: find.byType(IconButton),
          ),
        )
        .onPressed;
    expect(press('暂停'), isNull);
    expect(press('结束'), isNull);
    expect(press('放弃'), isNotNull);
    await notify(tester, {
      'id': 'countdown',
      'kind': 'recording',
      'phase': 'preparing',
    });
    await tester.pumpAndSettle();
    expect(find.text('正在准备采集…'), findsOneWidget);
  });

  testWidgets('录制选项：选择延时与点击特效即保存，开始录制携带所选延时，窗口目标禁用点击特效（#129、#143）', (
    tester,
  ) async {
    final png = await tester.runAsync(_selectionImage);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const selectionChannel = MethodChannel('test/recording-options');
    Map? saved;
    Map? started;
    messenger.setMockMethodCallHandler(selectionChannel, (call) async {
      switch (call.method) {
        case MethodNames.getScreenshot:
          return {
            'id': 'options',
            ...capture!,
            'width': 320,
            'height': 240,
            'canCaptureMedia': true,
            'cropActive': true,
            PreferenceKeys.recordingDelay: 0,
            PreferenceKeys.recordingClickEffectEnabled: false,
          };
        case MethodNames.saveRecordingOptions:
          saved = call.arguments as Map;
        case MethodNames.prepareCapture:
          started = call.arguments as Map;
        case MethodNames.captureSources:
          return <Object?>[];
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(selectionChannel, null),
    );
    await tester.pumpWidget(const ScreenshotApp(channel: selectionChannel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    await revealToolbarChildren(tester);
    await tester.tap(find.byKey(const Key(ScreenshotActions.record)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('录制选项'));
    await tester.pumpAndSettle();
    expect(find.text('不延时'), findsOneWidget);
    expect(find.text('延时 10 秒'), findsOneWidget);
    expect(find.text('包含点击特效'), findsOneWidget);
    await tester.tap(find.text('延时 5 秒'));
    await tester.pumpAndSettle();
    expect(saved, {
      PreferenceKeys.recordingDelay: 5,
      PreferenceKeys.recordingClickEffectEnabled: false,
    });
    expect(find.text('不延时'), findsNothing);
    await tester.tap(find.byTooltip('录制选项：延时 5 秒'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('包含点击特效'));
    await tester.pumpAndSettle();
    expect(saved, {
      PreferenceKeys.recordingDelay: 5,
      PreferenceKeys.recordingClickEffectEnabled: true,
    });
    await tester.tap(find.byTooltip('开始录制'));
    await tester.pumpAndSettle();
    expect(started!['delay'], 5);

    await tester.tap(find.byTooltip('窗口'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('录制选项：延时 5 秒'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MenuItemButton>(
            find.ancestor(
              of: find.text('包含点击特效'),
              matching: find.byType(MenuItemButton),
            ),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('实时翻译是录制目标行的开关：打开后开始按钮改为开始实时翻译并提交 live，录制选项照常可用且只在展开时选中（#1、#67）', (
    tester,
  ) async {
    final png = await tester.runAsync(_selectionImage);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const selectionChannel = MethodChannel('test/live-toggle');
    Map? started;
    final previews = <String>[];
    messenger.setMockMethodCallHandler(selectionChannel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'selection',
          ...capture!,
          'width': 320,
          'height': 240,
          'canCaptureMedia': true,
          'cropActive': true,
          PreferenceKeys.recordingDelay: 3,
          PreferenceKeys.recordingClickEffectEnabled: true,
        };
      }
      if (call.method == MethodNames.previewLiveRegion ||
          call.method == MethodNames.cancelLivePreview) {
        previews.add(call.method);
      }
      if (call.method == MethodNames.prepareCapture) {
        started = call.arguments as Map;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(selectionChannel, null),
    );
    await tester.pumpWidget(const ScreenshotApp(channel: selectionChannel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-live')), findsNothing);
    await tester.tap(find.byKey(const Key(ScreenshotActions.record)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recording-targets-row')), findsOneWidget);
    expect(find.byTooltip('开始录制'), findsOneWidget);
    IconButton button(String tooltip) => tester.widget<IconButton>(
      find.descendant(
        of: find.byTooltip(tooltip),
        matching: find.byType(IconButton),
      ).first,
    );
    bool optionsSelected() => tester
        .widget<Semantics>(
          find
              .ancestor(
                of: find.byTooltip('录制选项：延时 3 秒'),
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is Semantics &&
                      widget.properties.label == '录制选项：延时 3 秒',
                ),
              )
              .first,
        )
        .properties
        .selected!;
    expect(button('录制选项：延时 3 秒').onPressed, isNotNull);
    expect(optionsSelected(), isFalse);
    await tester.tap(find.byTooltip('录制选项：延时 3 秒'));
    await tester.pumpAndSettle();
    expect(find.text('不延时'), findsOneWidget);
    expect(optionsSelected(), isTrue);
    await tester.tap(find.byTooltip('录制选项：延时 3 秒'));
    await tester.pumpAndSettle();
    expect(find.text('不延时'), findsNothing);
    expect(optionsSelected(), isFalse);

    previews.clear();
    await tester.tap(find.byTooltip('实时翻译'));
    await tester.pumpAndSettle();
    expect(previews, [MethodNames.previewLiveRegion]);
    expect(find.byTooltip('开始录制'), findsNothing);
    expect(find.byTooltip('取消实时翻译'), findsOneWidget);
    expect(button('录制选项：延时 3 秒').onPressed, isNotNull);
    await tester.tap(find.byTooltip('开始实时翻译'));
    await tester.pumpAndSettle();
    expect(started, containsPair('live', true));
    expect(started!.containsKey('delay'), isFalse);
  });

  testWidgets('工具栏按用户拼接的父子结构显示子级，一级的录制直接展开目标选择', (tester) async {
    final png = await tester.runAsync(_selectionImage);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const selectionChannel = MethodChannel('test/toolbar-tree');
    final topLevel = [
      for (final id in ScreenshotActions.composable.keys)
        if (id != ScreenshotActions.scrolling) id,
    ];
    final toolbar = ScreenshotToolbarPreferences(
      columns: [
        for (final (index, modifiers)
            in ToolbarModifiers.allowed.take(4).indexed)
          ToolbarColumn(modifiers, [
            for (var slot = 0; slot < ToolbarGrid.slots; slot++)
              topLevel.elementAtOrNull(index * ToolbarGrid.slots + slot),
          ]),
      ],
      children: {
        ScreenshotActions.brush: [ScreenshotActions.scrolling],
      },
      favorites: const [],
    );
    messenger.setMockMethodCallHandler(selectionChannel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'selection',
          ...capture!,
          'width': 320,
          'height': 240,
          'canCaptureMedia': true,
          'cropActive': true,
          ...toolbar.toMap(),
        };
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(selectionChannel, null),
    );
    await tester.pumpWidget(const ScreenshotApp(channel: selectionChannel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    await showFullToolbar(tester);
    expect(find.byKey(const Key(ScreenshotActions.scrolling)), findsNothing);
    await tester.tap(find.byKey(const Key(ScreenshotActions.brush)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key(ScreenshotActions.scrolling)), findsOneWidget);
    await tester.tap(find.byKey(const Key(ScreenshotActions.record)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recording-targets-row')), findsOneWidget);
    expect(find.byKey(const Key(ScreenshotActions.scrolling)), findsNothing);
    Color? tint(String id) =>
        (tester
                    .widget<AnimatedContainer>(
                      find
                          .ancestor(
                            of: find.byKey(Key(id)),
                            matching: find.byType(AnimatedContainer),
                          )
                          .first,
                    )
                    .decoration!
                as ShapeDecoration)
            .color;
    expect(tint(ScreenshotActions.record), isNot(tint(ScreenshotActions.rect)));
    expect(tint(ScreenshotActions.crop), tint(ScreenshotActions.rect));
  });

  testWidgets('全屏选区准备按钮使用独立材料且保持可点，开始提交源像素并防重复', (tester) async {
    final png = await tester.runAsync(_selectionImage);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const selectionChannel = MethodChannel('test/capture-selection');
    final completion = Completer<void>();
    Map? selected;
    messenger.setMockMethodCallHandler(selectionChannel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'selection',
          ...capture!,
          'width': 320,
          'height': 240,
          'canCaptureMedia': true,
          'cropActive': true,
        };
      }
      if (call.method == MethodNames.prepareCapture) {
        if (selected != null) {
          throw PlatformException(code: '选区已经失效');
        }
        selected = call.arguments as Map;
        await completion.future;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(selectionChannel, null),
    );
    await tester.pumpWidget(const ScreenshotApp(channel: selectionChannel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    await showFullToolbar(tester);
    await revealToolbarChildren(tester);
    await tester.tap(find.byKey(const Key(ScreenshotActions.record)));
    await tester.pumpAndSettle();
    final confirm = find.byTooltip('开始录制');
    expect(confirm, findsOneWidget);
    final targetRow = find.byKey(const Key('recording-targets-row'));
    expect(
      find.descendant(of: targetRow, matching: find.byType(IconButton)),
      findsNWidgets(7),
    );
    expect(
      find.descendant(of: targetRow, matching: find.byType(AppKitView)),
      findsNothing,
    );
    final screen =
        Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
    for (final tooltip in ['录制选项', '开始录制', '取消录制']) {
      final rect = tester.getRect(find.byTooltip(tooltip));
      expect(screen.contains(rect.topLeft), isTrue);
      expect(screen.contains(rect.bottomRight), isTrue);
      expect(
        rect.size,
        const Size(ToolbarGrid.trayButton, ToolbarGrid.trayButton),
      );
      expect(find.byTooltip(tooltip).hitTestable(), findsOneWidget);
    }
    expect(find.byTooltip('固定区域'), findsNothing);
    await tester.tap(confirm);
    await tester.pump();
    final confirmButton = find.descendant(
      of: find.byTooltip('开始录制'),
      matching: find.byType(IconButton),
    );
    expect(tester.widget<IconButton>(confirmButton).onPressed, isNull);
    await tester.tap(confirm);
    expect(selected, containsPair('x', 0.0));
    expect(selected, containsPair('y', 0.0));
    expect(selected, containsPair('width', 320.0));
    expect(selected, containsPair('height', 240.0));
    expect(selected!.containsKey('automatic'), isFalse);
    completion.complete();
    await tester.pumpAndSettle();
    expect(find.text('选区已经失效'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('录制结果支持点击复制与⌘C，等待及转换中不可重复触发并展示失败原因（#142）', (tester) async {
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state = {
      'id': 'copy-video-session',
      'phase': 'videoReady',
      'previewScale': 1.0,
      'duration': 3.5,
      'width': 640,
      'height': 480,
    };
    var copyCalls = 0;
    Completer<void>? pendingCopy;
    String? copyError;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.copyRecording) {
        copyCalls += 1;
        expect(call.arguments, {'id': 'copy-video-session'});
        if (pendingCopy case final wait?) await wait.future;
        if (copyError != null) {
          throw PlatformException(code: 'capture_failed', message: copyError);
        }
      }
      return state;
    });

    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pumpAndSettle();

    pendingCopy = Completer<void>();
    await tester.tap(find.byKey(const Key('result-copy')));
    await tester.pump();
    expect(copyCalls, 1);
    expect(
      tester
          .widget<BusyRing>(
            find
                .ancestor(
                  of: find.byKey(const Key('result-copy')),
                  matching: find.byType(BusyRing),
                )
                .first,
          )
          .active,
      isTrue,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(copyCalls, 1);

    pendingCopy.complete();
    pendingCopy = null;
    await tester.pumpAndSettle();
    expect(find.text('已复制视频'), findsOneWidget);
    final bubble = find.byKey(const Key('toolbar-feedback-bubble'));
    expect(
      tester
          .getRect(bubble)
          .overlaps(tester.getRect(find.byKey(const Key('result-copy')))),
      isFalse,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(bubble, findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(copyCalls, 2);
    expect(find.text('已复制视频'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));

    await notify(tester, {
      ...state,
      'phase': 'converting',
      'exporting': 'gif',
      'progress': 0.4,
    });
    expect(
      tester.widget<TextButton>(find.byKey(const Key('result-copy'))).onPressed,
      isNull,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(copyCalls, 2);

    await notify(tester, {...state, 'phase': 'videoReady', 'exporting': null});
    copyError = '录制文件不存在，无法复制。';
    await tester.tap(find.byKey(const Key('result-copy')));
    await tester.pumpAndSettle();
    expect(copyCalls, 3);
    expect(find.text('录制文件不存在，无法复制。'), findsOneWidget);
    expect(find.text('已复制视频'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('采集错误气泡悬停 2 秒暂停并在移开后重计，点击关闭按钮立即消失（#144）', (tester) async {
    tester.view.physicalSize = const Size(380, 120);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state = {'id': 'hover-session', 'phase': 'recording', 'elapsed': 10.0};
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pumpAndSettle();

    await notify(tester, {...state, 'error': '录制写入受限，请检查磁盘空间。'});
    final bubble = find.byKey(const Key('toolbar-feedback-bubble'));
    final dismiss = find.byKey(const Key('toolbar-feedback-dismiss'));
    expect(bubble, findsOneWidget);
    expect(dismiss, findsOneWidget);

    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(bubble));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(bubble, findsOneWidget);

    await mouse.moveTo(Offset.zero);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1999));
    expect(bubble, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(bubble, findsNothing);

    await notify(tester, {...state, 'error': '另一条错误提示。'});
    expect(bubble, findsOneWidget);
    await tester.tap(dismiss);
    await tester.pump();
    expect(bubble, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('采集请求进行中阻止并发重入，failed 阶段仍展示错误气泡（#144）', (tester) async {
    tester.view.physicalSize = const Size(640, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pendingSave = Completer<Map<String, Object?>?>();
    final invoked = <String>[];
    state = {
      'id': 'reentry-session',
      'phase': 'videoReady',
      'width': 320,
      'height': 240,
      'previewScale': 1.0,
      'duration': 2.0,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      invoked.add(call.method);
      if (call.method == MethodNames.saveRecording) {
        return pendingSave.future;
      }
      return state;
    });

    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pumpAndSettle();
    invoked.clear();

    await tester.tap(find.byKey(const Key('result-save')));
    await tester.tap(find.byKey(const Key('result-copy')));
    expect(invoked, [MethodNames.saveRecording]);

    pendingSave.complete({...state, 'savedPath': '/tmp/out.mp4'});
    await tester.pump();
    expect(find.text('已保存 MP4'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));

    await notify(tester, {
      'id': 'failed-session',
      'phase': 'failed',
      'error': '屏幕录制权限已失效',
    });
    expect(find.text('屏幕录制权限已失效'), findsOneWidget);
    expect(find.byKey(const Key('toolbar-feedback-bubble')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<Uint8List> _selectionImage({int width = 320, int height = 240}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}
