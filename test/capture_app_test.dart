import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/capture/capture_app.dart';
import 'package:translate_app/src/common/constants/channel_names.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/preference_keys.dart';
import 'package:translate_app/src/common/constants/screenshot_actions.dart';
import 'package:translate_app/src/common/constants/screenshot_enums.dart';
import 'package:translate_app/src/common/widgets/app_motion.dart';
import 'package:translate_app/src/screenshot/screenshot_app.dart';
import 'package:translate_app/src/settings/screenshot_toolbar_preferences.dart';
import 'package:translate_app/src/common/constants/toolbar_grid.dart';

import 'support/capture_pixels.dart';

/// 无参数；验证工具状态、实际选区与媒体结果中的输入输出和边界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Map<String, Object?> state;

  /// next为原生已发生的状态；模拟平台边界通知并渲染当前帧，无返回值。
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
    // Widget测试只替换系统平台视图边界；媒体生命周期由原生测试覆盖。
    messenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (_) async => null,
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
  });

  testWidgets('两种采集共用四个独立气泡，上方提示且暂停放弃保持契约', (tester) async {
    // 320×84包含36pt上方提示空间；验证四个独立材料及两种内容的暂停、放弃、结束边界。
    tester.view.physicalSize = const Size(320, 84);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final kind in ['recording', 'scrolling']) {
      await tester.pumpWidget(const SizedBox.shrink());
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
      for (final tooltip in tester.widgetList<Tooltip>(find.byType(Tooltip))) {
        expect(tooltip.preferBelow, isFalse);
      }
      expect(find.text(label), findsOneWidget);
      // 84pt高面板只保留36pt提示区；长错误文字必须限制在气泡外，首击操作始终可命中。
      await notify(tester, {
        ...state,
        'error': '相邻画面缺少稳定的重叠内容，请减小单次滚动幅度或避开动态内容。已保留确认部分。',
      });
      final feedback = find.byKey(const Key('toolbar-feedback-bubble'));
      final feedbackRect = tester.getRect(feedback);
      expect(feedbackRect.height, greaterThanOrEqualTo(28));
      for (final action in ['暂停', '结束', '放弃']) {
        final button = find.byTooltip(action);
        expect(button.hitTestable(), findsOneWidget);
        expect(feedbackRect.overlaps(tester.getRect(button)), isFalse);
      }
      // 错误提示保留 2 秒供用户阅读，1 秒时尚在界面上，满 2 秒后关闭（#144）。
      await tester.pump(const Duration(seconds: 1));
      expect(feedback, findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(feedback, findsNothing);
      await tester.tap(find.byTooltip('暂停'));
      await tester.pumpAndSettle();
      expect(find.text('已暂停 · $label'), findsOneWidget);
      expect(find.byTooltip('开始'), findsOneWidget);
      await tester.tap(find.byTooltip('开始'));
      await tester.pumpAndSettle();
      expect(find.text(label), findsOneWidget);
      await tester.tap(find.byTooltip('结束'));
      await tester.pumpAndSettle();
      expect(find.text('正在完成采集…'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.stop))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.pause))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('放弃'));
      await tester.pumpAndSettle();
      expect(find.byType(IconButton), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('视频结果等比显示源逻辑尺寸且八个操作在底部居中横向排列', (tester) async {
    // 1706×868源像素来自2倍屏，1200×900视口足以按853×434逻辑尺寸完整显示，底部横向工具栏为356×48pt（#142）。
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state = {
      'id': 'video-result',
      'phase': 'videoReady',
      'duration': 9.45,
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
    expect(find.byType(IconButton), findsNWidgets(8));
    // 底部八个操作的32pt命中区从左至右保持12pt间距，水平居中且不覆盖媒体。
    final viewport = Offset.zero & const Size(1200, 900);
    final media = tester.getRect(video);
    final buttons = <Rect>[];
    Rect? previous;
    for (final action in [
      '播放视频',
      '裁剪',
      '复制视频',
      '保存 MP4',
      '导出 GIF',
      '导出 APNG',
      '导出 WebM',
      '关闭当前采集',
    ]) {
      expect(find.byTooltip(action).hitTestable(), findsOneWidget);
      final button = tester.getRect(find.byTooltip(action));
      expect(viewport.contains(button.topLeft), isTrue);
      expect(viewport.contains(button.bottomRight), isTrue);
      expect(media.overlaps(button), isFalse);
      expect(button.top, greaterThan(media.bottom));
      expect(button.bottom, viewport.bottom - 8);
      if (previous != null) {
        expect(button.top, previous.top);
        expect(button.left - previous.right, 12);
      }
      buttons.add(button);
      previous = button;
    }
    expect(
      (buttons.first.left + buttons.last.right) / 2,
      moreOrLessEquals(viewport.center.dx, epsilon: 0.01),
    );
    expect(find.byType(TextField), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == 'NativeGlassWindowPage',
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('受限视频窗口为底部工具栏保留完整外边距且不裁剪媒体', (tester) async {
    // 原生窗口底部预留64pt、左右预留16pt；超大视频应等比缩小，保留上左右8pt外边距与底部工具栏。
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
    expect(media.width / media.height, closeTo(16 / 9, 0.001));
    expect(media.left, greaterThanOrEqualTo(8));
    expect(media.top, greaterThanOrEqualTo(8));
    for (final action in [
      '播放视频',
      '裁剪',
      '复制视频',
      '保存 MP4',
      '导出 GIF',
      '导出 APNG',
      '导出 WebM',
      '关闭当前采集',
    ]) {
      final rect = tester.getRect(find.byTooltip(action));
      expect(rect.top, greaterThanOrEqualTo(media.bottom + 16));
      expect(rect.left, greaterThanOrEqualTo(8));
      expect(rect.right, lessThanOrEqualTo(892));
      expect(rect.bottom, lessThanOrEqualTo(592));
      expect(find.byTooltip(action).hitTestable(), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭与Escape单击放弃，转换中仍能关闭', (tester) async {
    // 关闭即丢弃会话；覆盖转换中关闭以及录制结果最小尺寸 356×65pt（底部 356×48 工具栏、16pt 间距及 1pt 媒体）。
    tester.view.physicalSize = const Size(356, 65);
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
    await tester.tap(find.byTooltip('关闭当前采集'));
    await tester.pumpAndSettle();
    expect(find.byType(IconButton), findsNothing);
    expect(tester.takeException(), isNull);
    // 新结果按一次Escape即可清理；不要求第二次键盘或确认输入。
    await notify(tester, resultState);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(IconButton), findsNothing);
    tester.view.physicalSize = const Size(900, 600);
    await notify(tester, {
      ...resultState,
      'id': 'closing-conversion',
      'phase': 'converting',
      'exporting': 'gif',
      'progress': 0.5,
    });
    await tester.pump();
    await tester.tap(find.byTooltip('关闭当前采集'));
    await tester.pumpAndSettle();
    expect(find.byType(IconButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MP4后台保存只显示保存状态，防重复且保留取消与关闭入口', (tester) async {
    // 边界：完整 MP4 的复制没有编码进度；忙碌快照缺少 progress，不能显示 0% 或其他虚构百分比。
    // 返回结果页后可再次保存；取消保存保留源视频，关闭保存中的结果结束当前会话。
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
    await tester.tap(find.byTooltip('保存 MP4'));
    await tester.pump();
    // 正在保存时仅「取消保存」按钮外圈进度环激活，其余按钮进度环为假（#142）。
    BusyRing ringOf(String tooltip) => tester.widget<BusyRing>(
      find
          .ancestor(
            of: find.byTooltip(tooltip),
            matching: find.byType(BusyRing),
          )
          .first,
    );
    expect(ringOf('取消保存').active, isTrue);
    expect(ringOf('导出 GIF').active, isFalse);
    expect(find.text('正在保存…'), findsOneWidget);
    expect(find.textContaining('%'), findsNothing);
    expect(find.byTooltip('保存 MP4'), findsNothing);
    final buttons = {
      for (final button in tester.widgetList<IconButton>(
        find.byType(IconButton),
      ))
        button.tooltip!: button,
    };
    for (final label in [
      '播放视频',
      '裁剪',
      '复制视频',
      '导出 GIF',
      '导出 APNG',
      '导出 WebM',
    ]) {
      expect(buttons[label]!.onPressed, isNull);
    }
    expect(buttons['关闭当前采集']!.onPressed, isNotNull);
    await tester.tap(find.byTooltip('取消保存'));
    await tester.pump();
    expect(ringOf('保存 MP4').active, isFalse);
    expect(find.text('保存已取消，源视频保持不变。'), findsOneWidget);
    expect(
      tester
          .widgetList<IconButton>(find.byType(IconButton))
          .firstWhere((button) => button.tooltip == '保存 MP4')
          .onPressed,
      isNotNull,
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byTooltip('保存 MP4'));
    await tester.pump();
    await tester.tap(find.byTooltip('关闭当前采集'));
    await tester.pumpAndSettle();
    expect(find.byType(IconButton), findsNothing);
    expect(find.text('正在保存…'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GIF直接导出全视频，取消和保存反馈在工具栏外仅停留一秒', (tester) async {
    // 非整数源时长由原生元数据决定；结果页不要求用户输入尺寸和片段。
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
    await tester.tap(find.byTooltip('导出 GIF'));
    await tester.pump();
    expect(find.text('正在转换 50%'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byTooltip('取消转换'));
    await tester.pump();
    final bubble = find.byKey(const Key('toolbar-feedback-bubble'));
    expect(find.textContaining('源视频保持不变'), findsOneWidget);
    for (final button in tester.widgetList<IconButton>(
      find.byType(IconButton),
    )) {
      // 跳过错误提示气泡自身的手动关闭按钮，只校对工具栏外围操作按钮不被气泡遮挡。
      if (button.key == const Key('toolbar-feedback-dismiss')) continue;
      final target = find.byTooltip(button.tooltip!);
      expect(tester.getRect(bubble).overlaps(tester.getRect(target)), isFalse);
      expect(target.hitTestable(), findsOneWidget);
    }
    // 取消回调通过 state['error'] 呈现，沿用 2000ms 错误停读；随后保存成功反馈沿用 1000ms（#144）。
    await tester.pump(const Duration(milliseconds: 1999));
    expect(bubble, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(bubble, findsNothing);
    await tester.tap(find.byTooltip('保存 MP4'));
    await tester.pump();
    expect(find.text('已保存 MP4'), findsOneWidget);
    expect(
      tester.getRect(bubble).overlaps(tester.getRect(find.byTooltip('保存 MP4'))),
      isFalse,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(bubble, findsNothing);
    expect(find.byTooltip('播放视频').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('裁剪期间全部操作等待；APNG/WebM 转换只把对应位置换成取消，完成后提示对应保存结果', (tester) async {
    // 边界：裁剪调用在用户点系统「裁剪」或「取消」前不返回，期间七个操作都不可用（#110）；
    // exporting 为 apng 时只有第五个位置、为 webm 时只有第六个位置变为取消，其余导出禁用，关闭仍可用；
    // 新的 apngPath/webmPath 才显示对应保存反馈。
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
    // 两种逐帧导出的发起方法、exporting 值、提示文字、保存路径键与反馈。
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

    /// 无参数；返回自上而下每个操作的提示文字及是否可点。
    List<(String, bool)> actions() => [
      for (final button in tester.widgetList<IconButton>(
        find.byType(IconButton),
      ))
        (button.tooltip!, button.onPressed != null),
    ];
    await tester.tap(find.byTooltip('裁剪'));
    await tester.pump();
    expect(actions().every((action) => !action.$2), isTrue);
    trimming.complete();
    await tester.pumpAndSettle();
    expect(actions().every((action) => action.$2), isTrue);

    for (final (_, _, label, pathKey, path, feedback) in exports) {
      await tester.tap(find.byTooltip(label));
      await tester.pump();
      expect(find.text('正在转换 25%'), findsOneWidget);
      expect(
        tester
            .widget<BusyRing>(
              find
                  .ancestor(
                    of: find.byTooltip('取消转换'),
                    matching: find.byType(BusyRing),
                  )
                  .first,
            )
            .active,
        isTrue,
      );
      expect(actions(), [
        ('播放视频', false),
        ('裁剪', false),
        ('复制视频', false),
        ('保存 MP4', false),
        ('导出 GIF', false),
        for (final other in ['导出 APNG', '导出 WebM'])
          other == label ? ('取消转换', true) : (other, false),
        ('关闭当前采集', true),
      ]);
      await notify(tester, {
        ...state,
        'phase': 'videoReady',
        'exporting': null,
        pathKey: path,
      });
      expect(find.text(feedback), findsOneWidget);
      expect(actions().every((action) => action.$2), isTrue);
      await tester.pump(const Duration(seconds: 1));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('截图组动态目标行沿用裁剪区域，取消准备保留编辑', (tester) async {
    // 从320×240中框选中央160×120；录制确认与长截图直启均保留当前区域。
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
        // 模拟真实关闭后的空快照，防止菜单取消意外销毁编辑画面却被测试忽略。
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
      // 源图异步建好后文档才有图。
      await awaitCaptureSource(tester);
      await tester.pumpAndSettle();
      final canvas = tester.getRect(find.byKey(const Key('screenshot-canvas')));
      await tester.dragFrom(
        canvas.topLeft + Offset(canvas.width / 4, canvas.height / 4),
        Offset(canvas.width / 2, canvas.height / 2),
      );
      await tester.pumpAndSettle();
      // 默认网格中截图在裸数字第 2 格，提示为「名称 + 键位」（#141）。
      expect(find.byTooltip('截图 2'), findsOneWidget);
      // 截图的子级组紧跟截图所在的第 1 组，挤开后续组：横放时在下一行，竖放时在右一列（#141）。
      final children = find.byKey(const Key('screenshot-children-group-0'));
      expect(
        find.descendant(of: children, matching: find.byTooltip('录制')),
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
            4,
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
          find.descendant(of: targetRow, matching: find.byType(AppKitView)),
          findsNWidgets(6),
        );
        // 原生Esc收起目标行后保留冻结帧和裁剪；再次展开仍可启动同一个选区。
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
      // 录制携带缺省的不延时，长截图不携带延时（#129）。
      expect(selected!['delay'], scrolling ? isNull : 0);
      expect(find.byTooltip('开始长截图'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('窗口目标增加应用图标行，切换清空选择且长列表可滚动访问', (tester) async {
    // 320pt窄屏与25个应用超过可见行宽；验证真实控件选择、命中与提交目标，不检查下游调用次数。
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
    // 源图异步建好后文档才有图。
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    final canvasBefore = tester.getRect(
      find.byKey(const Key('screenshot-canvas')),
    );
    await tester.tap(find.byTooltip('录制'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('窗口'));
    await tester.pumpAndSettle();
    final apps = find.byKey(const Key('recording-applications-row'));
    expect(apps, findsOneWidget);
    expect(find.byTooltip('当前应用').hitTestable(), findsOneWidget);
    expect(find.byTooltip('应用1'), findsOneWidget);
    expect(
      find.descendant(of: apps, matching: find.byIcon(Icons.apps)),
      findsOneWidget,
    );

    /// 无参数；返回当前开始按钮，用真实启用状态验证目标选择边界。
    IconButton startButton() => tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '开始录制',
      ),
    );
    expect(startButton().onPressed, isNull);
    await tester.tap(find.byTooltip('当前应用'));
    await tester.pumpAndSettle();
    expect(startButton().onPressed, isNotNull);
    expect(tester.getSemantics(find.byTooltip('当前应用')).label, contains('当前应用'));
    // 负坐标显示器上的应用窗口仍映射到当前显示画布；整个画布为实际录制区域。
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

  testWidgets('长图结果保留来源逻辑宽度并等比滚动，只提供保存复制放弃', (tester) async {
    // 200×2000像素来自2x屏幕，逻辑宽100、高1000；800×600视口不能放大或压扁，右侧只有三枚操作。
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final png = await tester.runAsync(
      () => _selectionImage(width: 200, height: 2000),
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
      'width': 200,
      'height': 2000,
      'previewScale': 2.0,
      'imageBytes': png,
      'warning': '相邻画面缺少稳定的重叠内容，请减小单次滚动幅度或避开动态内容。已保留确认部分。',
    };
    await tester.pumpWidget(const CaptureApp(channel: channel));
    await tester.pump();
    final preview = find.byKey(const Key('long-image-preview'));
    expect(tester.getSize(preview), const Size(100, 1000));
    expect(find.textContaining('相邻画面缺少稳定的重叠内容'), findsOneWidget);
    expect(find.byTooltip('复制图片'), findsNothing);
    expect(find.byKey(const Key('screenshot-canvas')), findsNothing);
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
    expect(tester.getSize(preview), const Size(100, 1000));
    // 视口上边距8pt，滚动400后预览顶边为-392，源逻辑尺寸不变。
    expect(tester.getTopLeft(preview).dy, -392);
    Rect? previous;
    for (final action in ['保存', '复制', '放弃']) {
      expect(find.byTooltip(action).hitTestable(), findsOneWidget);
      final button = tester.getRect(find.byTooltip(action));
      expect(button.left, greaterThan(tester.getRect(preview).right));
      if (previous != null) {
        expect(button.left, previous.left);
        expect(button.top - previous.bottom, 12);
      }
      previous = button;
    }
    await tester.tap(find.byTooltip('复制'));
    await tester.pump();
    expect(copiedId, 'long-image');
    expect(find.text('已复制'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('相邻画面缺少稳定的重叠内容'), findsNothing);
    await tester.tap(find.byTooltip('保存'));
    await tester.pump();
    expect(savedName, startsWith('截图_'));
    expect(savedName, endsWith('.png'));
    expect(find.text('已保存截图'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('媒体结果图片不能作为屏幕选区启动采集', (tester) async {
    // 没有冻结帧身份的图片仍可留在编辑器里，但两个采集入口必须保持禁用。
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
    // 源图异步建好后文档才有图。
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
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
    // 作用：同一个控制条同时表达录制与翻译两种状态。
    // 边界：recording 为真时显示“录制：1:05 · 状态”（65 秒）；为假时只显示翻译状态，不出现录制时长。
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
    // 边界：preparing 且 countdown 为 3 时显示「3 秒后开始」，暂停与结束禁用、放弃可用；
    // 没有 countdown 的 preparing 仍显示通用准备文案。
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
            of: find.byTooltip(description),
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
    // 边界：快照延时 0、点击特效 optical 时选「延时 5 秒」保留 optical；选「液态弹波」保存 liquid；
    // 开始录制的 delay 为 5；切到窗口目标后全部 7 项点击特效菜单均不可用。
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
            PreferenceKeys.recordingClickEffect:
                RecordingClickEffect.optical.name,
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
    // 源图异步建好后文档才有图。
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key(ScreenshotActions.record)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('录制选项'));
    await tester.pumpAndSettle();
    expect(find.text('不延时'), findsOneWidget);
    expect(find.text('延时 10 秒'), findsOneWidget);
    expect(find.text('点击特效：关闭'), findsOneWidget);
    await tester.tap(find.text('延时 5 秒'));
    await tester.pumpAndSettle();
    expect(saved, {
      PreferenceKeys.recordingDelay: 5,
      PreferenceKeys.recordingClickEffect: RecordingClickEffect.optical.name,
    });
    expect(find.text('不延时'), findsNothing);
    await tester.tap(find.byTooltip('录制选项：延时 5 秒'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('液态弹波'));
    await tester.pumpAndSettle();
    expect(saved, {
      PreferenceKeys.recordingDelay: 5,
      PreferenceKeys.recordingClickEffect: RecordingClickEffect.liquid.name,
    });
    await tester.tap(find.byTooltip('开始录制'));
    await tester.pumpAndSettle();
    expect(started!['delay'], 5);

    await tester.tap(find.byTooltip('窗口'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('录制选项：延时 5 秒'));
    await tester.pumpAndSettle();
    for (final effect in RecordingClickEffect.values) {
      final label = effect == RecordingClickEffect.off
          ? '点击特效：关闭'
          : effect.label;
      expect(
        tester
            .widget<MenuItemButton>(
              find.ancestor(
                of: find.text(label),
                matching: find.byType(MenuItemButton),
              ),
            )
            .onPressed,
        isNull,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('实时翻译是顶层工具，任意工具下点击都进入目标选择并可开始', (tester) async {
    // 作用：实时翻译不依赖先选中截图工具。
    // 边界：当前工具为画笔时点击实时翻译，直接出现目标选择行；开始请求带 live 且不再携带录制参数。
    final png = await tester.runAsync(_selectionImage);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const selectionChannel = MethodChannel('test/live-top-level');
    Map? started;
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
        started = call.arguments as Map;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(selectionChannel, null),
    );
    await tester.pumpWidget(const ScreenshotApp(channel: selectionChannel));
    // 源图异步建好后文档才有图。
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key(ScreenshotActions.brush)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recording-targets-row')), findsNothing);
    await tester.tap(find.byKey(const Key(ScreenshotActions.live)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recording-targets-row')), findsOneWidget);
    // 展开后不出现截图工具的录制与长截图；高亮的是实时翻译，不是截图工具。
    expect(find.byKey(const Key(ScreenshotActions.record)), findsNothing);
    expect(find.byKey(const Key(ScreenshotActions.scrolling)), findsNothing);
    // 选中的工具用强调色实底表示；矩形工具此时未选中，作为对照。
    Color? tint(String id) => tester
        .widget<IconButton>(find.byKey(Key(id)))
        .style!
        .backgroundColor!
        .resolve(const {});
    expect(tint(ScreenshotActions.live), isNot(tint(ScreenshotActions.rect)));
    expect(tint(ScreenshotActions.crop), tint(ScreenshotActions.rect));
    await tester.tap(find.byTooltip('开始实时翻译'));
    await tester.pumpAndSettle();
    expect(started, containsPair('live', true));
    expect(started!.containsKey('record'), isFalse);
  });

  testWidgets('工具栏按用户拼接的父子结构显示子级，一级的录制直接展开目标选择', (tester) async {
    // 作用：父子关系来自配置而不是写死在截图工具下。
    // 边界：滚动长截图拼到画笔之下、录制为一级；选中画笔时第二行出现滚动长截图，选中截图时不出现；
    // 点击一级的录制后出现目标选择行，高亮的是录制而不是它借用的截图工具。
    final png = await tester.runAsync(_selectionImage);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const selectionChannel = MethodChannel('test/toolbar-tree');
    // 除滚动长截图外全部为一级，按注册表顺序每列 6 格填入无、⌘、⌥、⌃ 四列（#141）。
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
    // 源图异步建好后文档才有图。
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    // 初始工具是截图：它没有子级，第二行没有滚动长截图。
    expect(find.byKey(const Key(ScreenshotActions.scrolling)), findsNothing);
    await tester.tap(find.byKey(const Key(ScreenshotActions.brush)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key(ScreenshotActions.scrolling)), findsOneWidget);
    await tester.tap(find.byKey(const Key(ScreenshotActions.record)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recording-targets-row')), findsOneWidget);
    expect(find.byKey(const Key(ScreenshotActions.scrolling)), findsNothing);
    // 选中的工具用强调色实底表示；矩形工具此时未选中，作为对照。
    Color? tint(String id) => tester
        .widget<IconButton>(find.byKey(Key(id)))
        .style!
        .backgroundColor!
        .resolve(const {});
    expect(tint(ScreenshotActions.record), isNot(tint(ScreenshotActions.rect)));
    expect(tint(ScreenshotActions.crop), tint(ScreenshotActions.rect));
  });

  testWidgets('全屏选区准备按钮使用独立材料且保持可点，开始提交源像素并防重复', (tester) async {
    // 320×240冻结画面置于更大视口；输出仍是源图像素，异步确认不可重复提交。
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
    // 源图异步建好后文档才有图。
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key(ScreenshotActions.record)));
    await tester.pumpAndSettle();
    final confirm = find.byTooltip('开始录制');
    expect(confirm, findsOneWidget);
    final targetRow = find.byKey(const Key('recording-targets-row'));
    // 三个目标、录制选项、开始与取消各自使用独立材料（#129）。
    expect(
      find.descendant(of: targetRow, matching: find.byType(AppKitView)),
      findsNWidgets(6),
    );
    final screen =
        Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
    for (final tooltip in ['录制选项', '开始录制', '取消录制']) {
      final rect = tester.getRect(find.byTooltip(tooltip));
      expect(screen.contains(rect.topLeft), isTrue);
      expect(screen.contains(rect.bottomRight), isTrue);
      expect(rect.size, const Size(32, 32));
      expect(find.byTooltip(tooltip).hitTestable(), findsOneWidget);
    }
    expect(find.byTooltip('固定区域'), findsNothing);
    await tester.tap(confirm);
    await tester.pump();
    final confirmButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '开始录制',
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

  // 验证录制结果按钮与 ⌘C 复制视频交互：等待态防重入、成功展示「已复制视频」、转换中禁用以及原生错误直接展示（#142）。
  testWidgets('录制结果支持点击复制视频与⌘C，等待及转换中不可重复触发并展示失败原因（#142）', (tester) async {
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

    // 1. 点击复制视频并挂起原生调用：验证按钮与 ⌘C 均禁用、外圈等待进度环激活。
    pendingCopy = Completer<void>();
    await tester.tap(find.byTooltip('复制视频'));
    await tester.pump();
    expect(copyCalls, 1);
    expect(
      tester
          .widget<BusyRing>(
            find
                .ancestor(
                  of: find.byTooltip('复制视频'),
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

    // 完成后进度环停转，出现「已复制视频」且不覆盖工具栏按钮，1 秒后消失。
    pendingCopy.complete();
    pendingCopy = null;
    await tester.pumpAndSettle();
    expect(find.text('已复制视频'), findsOneWidget);
    final bubble = find.byKey(const Key('toolbar-feedback-bubble'));
    expect(
      tester.getRect(bubble).overlaps(tester.getRect(find.byTooltip('复制视频'))),
      isFalse,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(bubble, findsNothing);

    // 2. 空闲状态按 ⌘C 触发复制并反馈成功。
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(copyCalls, 2);
    expect(find.text('已复制视频'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));

    // 3. 转换中「复制视频」不可点且 ⌘C 不触发调用。
    await notify(tester, {
      ...state,
      'phase': 'converting',
      'exporting': 'gif',
      'progress': 0.4,
    });
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == '复制视频',
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(copyCalls, 2);

    // 4. 恢复就绪后若原生失败，展示原生返回的错误信息而非成功反馈。
    await notify(tester, {...state, 'phase': 'videoReady', 'exporting': null});
    copyError = '录制文件不存在，无法复制。';
    await tester.tap(find.byTooltip('复制视频'));
    await tester.pumpAndSettle();
    expect(copyCalls, 3);
    expect(find.text('录制文件不存在，无法复制。'), findsOneWidget);
    expect(find.text('已复制视频'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('采集错误气泡悬停 2 秒暂停并在移开后重计，点击关闭按钮立即消失（#144）', (tester) async {
    // 作用：验证 CaptureApp 错误提示遵循 2000ms 自动关闭、悬停停读与手动关闭交互。
    // 边界：悬停期间超过 3s 仍停留；移出鼠标 1999ms 仍存在，满 2000ms 关闭；点击关闭按钮立即清空。
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
    // 作用：验证同一帧并发点击只发出首个请求，以及失败阶段不会退回隐藏空白页。
    // 边界：保存请求挂起期间同帧点击导出不发出第二个原生调用；phase=failed 且带 error 时保留错误气泡。
    tester.view.physicalSize = const Size(520, 420);
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

    // 同帧尚未重绘禁用态前连续点击两个操作：第二个调用被 _pending 守卫拦截。
    await tester.tap(find.byTooltip('保存 MP4'));
    await tester.tap(find.byTooltip('导出 GIF'));
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

/// width/height为源像素尺寸；返回真实PNG，供冻结画面和长图结果验证。
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
