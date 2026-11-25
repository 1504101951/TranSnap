import 'package:transnap/src/common/constants/method_names.dart';

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:transnap/src/common/constants/screenshot_actions.dart';
import 'package:transnap/src/settings/screenshot_toolbar_preferences.dart';
import 'package:transnap/src/common/constants/toolbar_grid.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:transnap/src/common/utils/geometry.dart';
import 'package:transnap/src/common/constants/screenshot_enums.dart';
import 'package:transnap/src/screenshot/drawing_controls.dart';
import 'package:transnap/src/screenshot/edit_document.dart';
import 'package:transnap/src/screenshot/screenshot_app.dart';
import 'package:transnap/src/common/widgets/app_motion.dart';
import 'package:transnap/src/common/widgets/native_glass.dart';
import 'package:transnap/src/common/widgets/native_resize_cursor.dart';
import 'package:transnap/src/screenshot/screenshot_editor_layout.dart';

import 'support/capture_pixels.dart';
import 'package:transnap/src/common/widgets/line_icon.dart';

void main() {
  test('工具栏依次使用下、上、右、左侧空白，完整位于窗口且不与选区相交', () {
    const viewport = Size(960, 740);
    final cases = [
      (crop: const Rect.fromLTWH(200, 100, 400, 200), side: 'bottom'),
      (crop: const Rect.fromLTWH(200, 440, 400, 290), side: 'top'),
      (crop: const Rect.fromLTWH(0, 0, 820, 740), side: 'right'),
      (crop: const Rect.fromLTWH(140, 0, 820, 740), side: 'left'),
    ];
    for (final item in cases) {
      final layout = ScreenshotEditorLayout.place(
        viewport: viewport,
        image: viewport,
        crop: item.crop,
      );
      expect(layout.canvas, Offset.zero & viewport);
      expect(layout.toolbar.overlaps(item.crop), isFalse);
      expect((Offset.zero & viewport).contains(layout.toolbar.topLeft), isTrue);
      expect(
        (Offset.zero & viewport).contains(layout.toolbar.bottomRight),
        isTrue,
      );
      switch (item.side) {
        case 'bottom':
          expect(layout.toolbar.top, greaterThan(item.crop.bottom));
          expect(layout.axis, Axis.horizontal);
        case 'top':
          expect(layout.toolbar.bottom, lessThan(item.crop.top));
          expect(layout.axis, Axis.horizontal);
        case 'right':
          expect(layout.toolbar.left, greaterThan(item.crop.right));
          expect(layout.axis, Axis.vertical);
        case 'left':
          expect(layout.toolbar.right, lessThan(item.crop.left));
          expect(layout.axis, Axis.vertical);
      }
    }
  });

  test('全屏和近全屏选区将工具栏放在内侧边缘，不移动或缩放画布', () {
    for (final viewport in [const Size(960, 740), const Size(320, 600)]) {
      const image = Size(1920, 1480);
      for (final crop in [
        Offset.zero & image,
        const Rect.fromLTWH(2, 2, 1916, 1476),
      ]) {
        final layout = ScreenshotEditorLayout.place(
          viewport: viewport,
          image: image,
          crop: crop,
        );
        expect(layout.canvas, Offset.zero & viewport);
        expect(
          layout.toolbar.overlaps(mapRectToFitted(crop, image, layout.canvas)),
          isTrue,
        );
        expect(
          (Offset.zero & viewport).contains(layout.toolbar.bottomRight),
          isTrue,
        );
      }
    }
  });

  test('三四行工具栏在全屏贴边与横竖布局中保持屏幕内且不改变画布', () {
    for (final size in [const Size(960, 740), const Size(320, 600)]) {
      for (final thickness in [112.0, 156.0]) {
        for (final scale in [1.0, 2.0]) {
          for (final crop in [
            Offset.zero & size,
            Rect.fromLTWH(0, 0, size.width - 190, size.height),
          ]) {
            final layout = ScreenshotEditorLayout.place(
              viewport: size,
              image: Size(size.width * scale, size.height * scale),
              crop: Rect.fromLTRB(
                crop.left * scale,
                crop.top * scale,
                crop.right * scale,
                crop.bottom * scale,
              ),
              thickness: thickness,
              toolbarLength: 1200,
            );
            expect(layout.canvas, Offset.zero & size);
            expect(
              (Offset.zero & size).contains(layout.toolbar.topLeft),
              isTrue,
            );
            expect(
              (Offset.zero & size).contains(layout.toolbar.bottomRight),
              isTrue,
            );
            expect(
              layout.axis == Axis.horizontal
                  ? layout.toolbar.height
                  : layout.toolbar.width,
              thickness,
            );
          }
        }
      }
    }
  });

  test('工具栏居中对齐选区；居中被屏幕左右边挡住时竖放到另一侧，边角与全屏保持横放（#67）', () {
    const viewport = Size(1000, 640);
    ScreenshotEditorLayout place(Rect crop, {double length = 504}) =>
        ScreenshotEditorLayout.place(
          viewport: viewport,
          image: viewport,
          crop: crop,
          toolbarLength: length,
          centerLength: 504,
          thickness: 84,
        );
    final narrow = place(const Rect.fromLTWH(380, 150, 240, 200));
    expect(narrow.axis, Axis.horizontal);
    expect(narrow.toolbar, const Rect.fromLTWH(248, 358, 504, 84));
    expect(
      place(const Rect.fromLTWH(380, 150, 240, 200), length: 560).toolbar,
      const Rect.fromLTWH(248, 358, 560, 84),
    );
    final nearLeft = place(const Rect.fromLTWH(40, 150, 200, 220));
    expect(nearLeft.axis, Axis.vertical);
    expect(nearLeft.toolbar, const Rect.fromLTWH(248, 8, 84, 504));
    final nearRight = place(const Rect.fromLTWH(760, 150, 200, 220));
    expect(nearRight.axis, Axis.vertical);
    expect(nearRight.toolbar, const Rect.fromLTWH(668, 8, 84, 504));
    final corner = place(const Rect.fromLTWH(20, 20, 240, 180));
    expect(corner.axis, Axis.horizontal);
    expect(corner.toolbar, const Rect.fromLTWH(8, 208, 504, 84));
    final full = place(Offset.zero & viewport);
    expect(full.axis, Axis.horizontal);
    expect(full.toolbar, const Rect.fromLTWH(248, 548, 504, 84));
  });

  testWidgets('默认窗口仅预览可重新框选，手动选区八点和边框可拉伸', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final png = await tester.runAsync(() => _image(width: 960, height: 740));
    final capture = await tester.runAsync(() => capturePixels(png!));
    const channel = MethodChannel('test/crop-cursor');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'cursor',
          ...capture!,
          'width': 960,
          'height': 740,
          'cropX': 200,
          'cropY': 180,
          'cropWidth': 400,
          'cropHeight': 300,
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(20, 20));
    await mouse.moveTo(const Offset(400, 300));
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.precise,
    );
    await tester.dragFrom(const Offset(280, 220), const Offset(240, 180));
    await tester.pumpAndSettle();
    final cases = <Offset, MouseCursor>{
      const Offset(280, 220): const NativeResizeCursor(
        ResizeCursorAxes.northWestSouthEast,
        channel: channel,
      ),
      const Offset(400, 220): SystemMouseCursors.resizeUpDown,
      const Offset(520, 220): const NativeResizeCursor(
        ResizeCursorAxes.northEastSouthWest,
        channel: channel,
      ),
      const Offset(520, 310): SystemMouseCursors.resizeLeftRight,
      const Offset(520, 400): const NativeResizeCursor(
        ResizeCursorAxes.northWestSouthEast,
        channel: channel,
      ),
      const Offset(400, 400): SystemMouseCursors.resizeUpDown,
      const Offset(280, 400): const NativeResizeCursor(
        ResizeCursorAxes.northEastSouthWest,
        channel: channel,
      ),
      const Offset(280, 310): SystemMouseCursors.resizeLeftRight,
      const Offset(340, 220): SystemMouseCursors.resizeUpDown,
      const Offset(340, 400): SystemMouseCursors.resizeUpDown,
      const Offset(280, 260): SystemMouseCursors.resizeLeftRight,
      const Offset(520, 260): SystemMouseCursors.resizeLeftRight,
      const Offset(400, 300): SystemMouseCursors.grab,
      const Offset(100, 100): SystemMouseCursors.precise,
    };
    for (final item in cases.entries) {
      await mouse.moveTo(item.key);
      await tester.pumpAndSettle();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        item.value,
        reason: '光标位置 ${item.key}',
      );
    }
    await mouse.removePointer();
  });

  testWidgets('整屏初始选区直接选中：控制点可拉伸，内部可拖动', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final png = await tester.runAsync(() => _image(width: 960, height: 740));
    final capture = await tester.runAsync(() => capturePixels(png!));
    const channel = MethodChannel('test/crop-selected');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'selected',
          ...capture!,
          'width': 960,
          'height': 740,
          'cropX': 200,
          'cropY': 180,
          'cropWidth': 400,
          'cropHeight': 300,
          'cropSelected': true,
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(20, 20));

    Future<MouseCursor?> cursorAt(Offset position) async {
      await mouse.moveTo(position);
      await tester.pumpAndSettle();
      return RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
    }

    const resize = NativeResizeCursor(
      ResizeCursorAxes.northWestSouthEast,
      channel: channel,
    );
    expect(await cursorAt(const Offset(200, 180)), resize);
    expect(await cursorAt(const Offset(400, 330)), SystemMouseCursors.grab);
    await tester.dragFrom(const Offset(600, 480), const Offset(-100, -80));
    await tester.pumpAndSettle();
    expect(await cursorAt(const Offset(500, 400)), resize);
    expect(await cursorAt(const Offset(100, 100)), SystemMouseCursors.precise);
    await mouse.removePointer();
  });

  test('比例矩形朝指针方向生长，较短边不小于下限，空间不足时整体缩小', () {
    const bounds = Size(960, 740);
    Rect rect(
      Offset anchor,
      Offset toward,
      double ratio, {
      bool byHeight = false,
      double minSide = 8,
    }) => ratioRect(
      anchor: anchor,
      toward: toward,
      ratio: ratio,
      byHeight: byHeight,
      bounds: bounds,
      minSide: minSide,
    );
    expect(
      rect(const Offset(100, 100), const Offset(300, 400), 1),
      const Rect.fromLTWH(100, 100, 200, 200),
    );
    expect(
      rect(const Offset(100, 100), const Offset(40, 0), 16 / 9),
      const Rect.fromLTWH(40, 66.25, 60, 33.75),
    );
    expect(
      rect(const Offset(0, 0), const Offset(500, 90), 16 / 9, byHeight: true),
      const Rect.fromLTWH(0, 0, 160, 90),
    );
    expect(
      rect(const Offset(100, 700), const Offset(900, 710), 1),
      const Rect.fromLTWH(100, 700, 40, 40),
    );
    expect(
      rect(const Offset(900, 100), const Offset(1200, 200), 1),
      const Rect.fromLTWH(900, 100, 60, 60),
    );
    final landscape = rect(const Offset(10, 10), const Offset(11, 11), 16 / 9);
    expect(landscape.height, closeTo(8, 1e-9));
    expect(landscape.width, closeTo(128 / 9, 1e-9));
    final portrait = rect(const Offset(10, 10), const Offset(11, 11), 9 / 16);
    expect(portrait.width, closeTo(8, 1e-9));
    expect(portrait.height, closeTo(128 / 9, 1e-9));
    expect(
      rect(const Offset(10, 10), const Offset(10, 10), 1, minSide: 0),
      const Rect.fromLTWH(10, 10, 0, 0),
    );
  });

  testWidgets('方向键移动选区 1 像素、⇧ 10 像素，⌥ 调整大小，限制在截图内且最小边长 8', (tester) async {
    final calls = (await _pumpSelectedCrop(tester, 'test/crop-nudge')).calls;
    final label = find.byKey(const Key('crop-size-label'));
    expect(find.text('400 × 300'), findsOneWidget);
    expect(tester.getRect(label).bottom, 176);
    expect(tester.getRect(label).left, 200);

    await _arrow(tester, LogicalKeyboardKey.arrowRight);
    await _arrow(tester, LogicalKeyboardKey.arrowDown);
    await _arrow(
      tester,
      LogicalKeyboardKey.arrowLeft,
      modifiers: [LogicalKeyboardKey.shiftLeft],
    );
    expect(await _copyCrop(tester, calls), (
      const Size(400, 300),
      const Rect.fromLTWH(191, 181, 400, 300),
    ));

    await _arrow(
      tester,
      LogicalKeyboardKey.arrowRight,
      modifiers: [LogicalKeyboardKey.altLeft],
    );
    await _arrow(
      tester,
      LogicalKeyboardKey.arrowUp,
      modifiers: [LogicalKeyboardKey.altLeft, LogicalKeyboardKey.shiftLeft],
    );
    expect(find.text('401 × 290'), findsOneWidget);
    for (final key in [
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowDown,
    ]) {
      await _arrow(
        tester,
        key,
        modifiers: [LogicalKeyboardKey.shiftLeft],
        times: 60,
      );
    }
    expect(await _copyCrop(tester, calls), (
      const Size(401, 290),
      const Rect.fromLTWH(559, 450, 401, 290),
    ));

    for (final key in [
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowUp,
    ]) {
      await _arrow(
        tester,
        key,
        modifiers: [LogicalKeyboardKey.shiftLeft],
        times: 60,
      );
    }
    expect(tester.getRect(label).topLeft, const Offset(4, 4));
    await _arrow(
      tester,
      LogicalKeyboardKey.arrowLeft,
      modifiers: [LogicalKeyboardKey.altLeft, LogicalKeyboardKey.shiftLeft],
      times: 50,
    );
    expect(find.text('8 × 290'), findsOneWidget);
    expect(await _copyCrop(tester, calls), (
      const Size(8, 290),
      const Rect.fromLTWH(0, 0, 8, 290),
    ));
    for (final key in [
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowDown,
    ]) {
      await _arrow(
        tester,
        key,
        modifiers: [LogicalKeyboardKey.altLeft, LogicalKeyboardKey.shiftLeft],
        times: 100,
      );
    }
    expect(find.text('960 × 740'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('原生转发的方向键微调当前选区，⇧ 10 像素、⌥ 调整大小，过期捕获忽略（#106）', (tester) async {
    final pumped = await _pumpSelectedCrop(tester, 'test/crop-native-nudge');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Future<void> nudge(
      int dx,
      int dy, {
      bool shift = false,
      bool option = false,
      String id = 'crop',
    }) async {
      await messenger.handlePlatformMessage(
        pumped.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(MethodNames.nudgeScreenshotCrop, {
            'id': id,
            'dx': dx,
            'dy': dy,
            'shift': shift,
            'option': option,
          }),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    await nudge(1, 0);
    await nudge(0, 1, shift: true);
    await nudge(1, 0, shift: true, option: true);
    await nudge(1, 0, id: 'stale');
    expect(find.text('410 × 300'), findsOneWidget);
    expect(await _copyCrop(tester, pumped.calls), (
      const Size(410, 300),
      const Rect.fromLTWH(201, 190, 410, 300),
    ));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('文字输入中与选中标注时方向键不移动选区，取消选中后恢复', (tester) async {
    final calls = (await _pumpSelectedCrop(
      tester,
      'test/crop-nudge-ignore',
    )).calls;
    await tester.tap(find.byKey(const Key('screenshot-tool-text')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('screenshot-canvas')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('screenshot-text-field')),
      'Hi',
    );
    expect(find.byKey(const Key('crop-size-label')), findsNothing);
    await _arrow(tester, LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('screenshot-tool-rect')));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(250, 250), const Offset(100, 80));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('screenshot-tool-cursor')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(350, 300));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    await _arrow(tester, LogicalKeyboardKey.arrowRight);
    expect(
      (await _copyCrop(tester, calls)).$2,
      const Rect.fromLTWH(200, 180, 400, 300),
    );

    await tester.tapAt(const Offset(100, 100));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    await _arrow(tester, LogicalKeyboardKey.arrowRight);
    expect(
      (await _copyCrop(tester, calls)).$2,
      const Rect.fromLTWH(201, 180, 400, 300),
    );
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('锁定比例后新框选、控制点与 ⌥ 方向键保持比例；自由与新截图解除', (tester) async {
    final pumped = await _pumpSelectedCrop(tester, 'test/crop-ratio');
    await tester.tap(find.byKey(const Key(ScreenshotActions.ratio)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ratio-row')), findsOneWidget);
    await tester.tap(find.byTooltip('比例 1:1'));
    await tester.pumpAndSettle();
    expect(find.text('400 × 400'), findsOneWidget);
    await tester.tap(find.byTooltip('比例 16:9'));
    await tester.pumpAndSettle();
    expect(find.text('400 × 225'), findsOneWidget);

    await tester.dragFrom(const Offset(600, 405), const Offset(100, 300));
    await tester.pumpAndSettle();
    expect(find.text('500 × 281'), findsOneWidget);
    await tester.dragFrom(const Offset(450, 180), const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(find.text('642 × 361'), findsOneWidget);
    await tester.dragFrom(const Offset(20, 20), const Offset(160, 40));
    await tester.pumpAndSettle();
    expect(find.text('160 × 90'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ratio-row')), findsNothing);
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);
    await _arrow(
      tester,
      LogicalKeyboardKey.arrowRight,
      modifiers: [LogicalKeyboardKey.altLeft],
    );
    expect(find.text('161 × 91'), findsOneWidget);

    await tester.tap(find.byKey(const Key(ScreenshotActions.ratio)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('自由比例'));
    await tester.pumpAndSettle();
    await _arrow(
      tester,
      LogicalKeyboardKey.arrowDown,
      modifiers: [LogicalKeyboardKey.altLeft],
    );
    expect(find.text('161 × 92'), findsOneWidget);

    await tester.tap(find.byTooltip('比例 1:1'));
    await tester.pumpAndSettle();
    expect(find.text('161 × 161'), findsOneWidget);
    await tester.runAsync(() async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            pumped.channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(MethodNames.screenshotChanged, {
                ...pumped.snapshot,
                'id': 'second',
              }),
            ),
            (_) {},
          );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ratio-row')), findsNothing);
    await _arrow(
      tester,
      LogicalKeyboardKey.arrowRight,
      modifiers: [LogicalKeyboardKey.altLeft],
    );
    expect(find.text('401 × 300'), findsOneWidget);
  });

  testWidgets('光标优先操作文字并可选中移动拉伸截图，空白拖动不重新框选', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final png = await tester.runAsync(() => _image(width: 960, height: 740));
    final capture = await tester.runAsync(() => capturePixels(png!));
    const channel = MethodChannel('test/unified-cursor');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Uint8List? copied;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'unified',
          ...capture!,
          'width': 960,
          'height': 740,
          'cropX': 200,
          'cropY': 180,
          'cropWidth': 400,
          'cropHeight': 300,
        };
      }
      if (call.method == MethodNames.copyScreenshot) {
        copied = (call.arguments as Map)['bytes'] as Uint8List;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key(ScreenshotActions.cursor)));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(400, 300), const Offset(40, 20));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(640, 350), const Offset(60, 0));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(240, 200));
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      const NativeResizeCursor(
        ResizeCursorAxes.northWestSouthEast,
        channel: channel,
      ),
    );
    await mouse.removePointer();
    await tester.tap(find.byKey(const Key(ScreenshotActions.text)));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(300, 260), const Offset(200, 60));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('screenshot-text-field')),
      '来源与译文',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final lineHeight = textBoxHeight(
      text: '来源与译文',
      fontSize: ScreenshotDefaults.fontSize,
      width: 200,
    );
    await tester.tap(find.byKey(const Key(ScreenshotActions.cursor)));
    await tester.pumpAndSettle();
    await tester.dragFrom(
      Offset(400, 260 + lineHeight / 2),
      const Offset(30, 30),
    );
    await tester.pumpAndSettle();
    await tester.dragFrom(
      Offset(530, 290 + lineHeight / 2),
      const Offset(40, 20),
    );
    await tester.pumpAndSettle();
    final textMouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await textMouse.addPointer(location: const Offset(40, 40));
    for (final corner in <Offset, String>{
      const Offset(330, 290): ResizeCursorAxes.northWestSouthEast,
      const Offset(570, 290): ResizeCursorAxes.northEastSouthWest,
      Offset(330, 290 + lineHeight): ResizeCursorAxes.northEastSouthWest,
      Offset(570, 290 + lineHeight): ResizeCursorAxes.northWestSouthEast,
    }.entries) {
      await textMouse.moveTo(corner.key);
      await tester.pumpAndSettle();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        NativeResizeCursor(corner.value, channel: channel),
      );
    }
    await textMouse.moveTo(const Offset(40, 40));
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.basic,
    );
    await textMouse.removePointer();
    await tester.tapAt(Offset(440, 290 + lineHeight / 2));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(Offset(440, 290 + lineHeight / 2));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('screenshot-text-field'));
    expect(field, findsOneWidget);
    final textBox = find
        .ancestor(of: field, matching: find.byType(Positioned))
        .first;
    expect(tester.getRect(textBox), Rect.fromLTWH(330, 290, 240, lineHeight));
    expect(find.text('来源与译文'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(50, 50), const Offset(40, 40));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key(ScreenshotActions.copy)));
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pumpAndSettle();
    expect(copied, isNotNull);
    final decoded = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(copied!);
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    });
    expect(decoded!.width, 460);
    expect(decoded.height, 300);
    decoded.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('工具栏按组排列：隐藏工具留空位，整组隐藏不显示，组左侧标注组合（#141）', (tester) async {
    final png = await tester.runAsync(_image);
    final capture = await tester.runAsync(() => capturePixels(png!));
    final defaults = ScreenshotToolbarPreferences();
    final preferences = defaults.copyWith(
      hidden: {
        defaults.columns[1].slots[1]!,
        ...defaults.columns[2].slots.whereType<String>(),
      },
    );
    const channel = MethodChannel('test/toolbar-grid');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'grid',
          ...capture!,
          'width': 320,
          'height': 240,
          'cropX': 40,
          'cropY': 20,
          'cropWidth': 120,
          'cropHeight': 60,
          ...preferences.toMap(),
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    final first = defaults.columns[1].slots[0]!;
    final third = defaults.columns[1].slots[2]!;
    expect(
      tester.getTopLeft(find.byKey(Key(third))).dx -
          tester.getTopLeft(find.byKey(Key(first))).dx,
      72,
    );
    expect(find.byKey(const Key('screenshot-grid-group-1')), findsOneWidget);
    expect(find.byKey(const Key('screenshot-grid-group-2')), findsNothing);
    expect(
      find.byKey(const Key('toolbar-group-label-screenshot-grid-group-0')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('screenshot-grid-group-0')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('screenshot-grid-group-1')),
        matching: find.text('1'),
      ),
      findsNothing,
    );
    expect(find.byKey(Key('toolbar-badge-$third')), findsNothing);
  });

  testWidgets('工具栏每行两个分区块并带修饰键提示，三级托盘对齐唤起按钮，放不下时每行一块（#141、#67）', (
    tester,
  ) async {
    final png = await tester.runAsync(_image);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const channel = MethodChannel('test/toolbar-lines');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'lines',
          ...capture!,
          'width': 320,
          'height': 240,
          'cropX': 40,
          'cropY': 20,
          'cropWidth': 120,
          'cropHeight': 60,
          'canCaptureMedia': true,
          ...ScreenshotToolbarPreferences().toMap(),
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    Rect rect(String key) => tester.getRect(find.byKey(Key(key)));
    final toolbar = rect('screenshot-toolbar');
    final group0 = rect('screenshot-grid-group-0');
    final group1 = rect('screenshot-grid-group-1');
    final group2 = rect('screenshot-grid-group-2');
    expect(group1.top, group0.top);
    expect(group1.right, toolbar.right - ToolbarGrid.blockPadding);
    expect(
      group1.left - group0.right,
      ToolbarGrid.blockPadding * 2 +
          ToolbarGrid.blockGap +
          ToolbarGrid.hintExtent +
          4,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const Key('toolbar-hint-screenshot-grid-group-1')),
          )
          .data,
      '⌘',
    );
    expect(
      rect('toolbar-hint-screenshot-grid-group-1').right,
      lessThan(group1.left),
    );
    expect(
      tester
          .widget<LineIcon>(
            find.byKey(const Key('toolbar-hint-screenshot-grid-group-0')),
          )
          .icon,
      LucideIcons.keyboard,
    );
    expect(group2.top, greaterThan(group0.top));
    expect(group2.left, group0.left);
    final children = rect('screenshot-children-group-0');
    expect(children.top, greaterThan(group0.top));
    expect(children.top, lessThan(group2.top));

    await tester.tap(find.byKey(const Key(ScreenshotActions.record)));
    await tester.pumpAndSettle();
    final targets = rect('recording-targets-row');
    expect(targets.top, greaterThan(rect('screenshot-children-group-0').top));
    expect(targets.height, ToolbarGrid.trayButton);
    expect(
      targets.left + ToolbarGrid.trayButton / 2,
      tester.getCenter(find.byKey(const Key(ScreenshotActions.record))).dx,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('recording-targets-row')),
        matching: find.byType(NativeGlassSurface),
      ),
      findsNothing,
    );
    expect(targets.top, lessThan(rect('screenshot-grid-group-2').top));

    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();
    final narrow0 = rect('screenshot-grid-group-0');
    final narrow1 = rect('screenshot-grid-group-1');
    expect(narrow1.top, greaterThan(narrow0.top));
    expect(narrow1.left, narrow0.left);
  });

  testWidgets('子级组从父级按钮液态展开，收起时融合回父级后移除（#142）', (tester) async {
    final png = await tester.runAsync(_image);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const channel = MethodChannel('test/toolbar-liquid');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'liquid',
          ...capture!,
          'width': 320,
          'height': 240,
          'cropX': 40,
          'cropY': 20,
          'cropWidth': 120,
          'cropHeight': 60,
          'canCaptureMedia': true,
          ...ScreenshotToolbarPreferences().toMap(),
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    final record = find.byKey(const Key(ScreenshotActions.record));
    final settled = tester.getCenter(record);

    await tester.tap(find.byKey(const Key(ScreenshotActions.cursor)));
    await tester.pump();
    expect(find.byKey(const Key('screenshot-closing-group-0')), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-closing-group-0')), findsNothing);
    expect(record, findsNothing);

    await tester.tap(find.byKey(const Key(ScreenshotActions.crop)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final crop = tester.getCenter(
      find.byKey(const Key(ScreenshotActions.crop)),
    );
    expect(
      (tester.getCenter(record) - crop).distance,
      lessThan((settled - crop).distance),
    );
    await tester.pumpAndSettle();
    expect(tester.getCenter(record), settled);
  });

  testWidgets('切换父级时，新子级组紧跟新父级所在行，旧子级组直接移除（#142）', (tester) async {
    final png = await tester.runAsync(_image);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const channel = MethodChannel('test/toolbar-switch-parent');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'switch-parent',
          ...capture!,
          'width': 320,
          'height': 240,
          'cropX': 40,
          'cropY': 20,
          'cropWidth': 120,
          'cropHeight': 60,
          'canCaptureMedia': true,
          ...ScreenshotToolbarPreferences().toMap(),
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('screenshot-children-group-0')),
        matching: find.byKey(const Key(ScreenshotActions.record)),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key(ScreenshotActions.beautify)));
    await tester.pump();
    expect(find.byKey(const Key('screenshot-closing-group-0')), findsNothing);
    expect(find.byKey(const Key(ScreenshotActions.record)), findsNothing);
    final children = find.byKey(const Key('screenshot-children-group-0'));
    expect(
      find.descendant(
        of: children,
        matching: find.byKey(const Key(ScreenshotActions.sticker)),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('screenshot-grid-group-1')),
        matching: find.byKey(const Key(ScreenshotActions.beautify)),
      ),
      findsOneWidget,
    );
    final horizontal =
        tester
            .widget<Flex>(find.byKey(const Key('screenshot-grid-group-1')))
            .direction ==
        Axis.horizontal;
    final parentGroupRect = tester.getRect(
      find.byKey(const Key('screenshot-grid-group-1')),
    );
    final childrenRect = tester.getRect(children);
    expect(
      horizontal ? childrenRect.top : childrenRect.left,
      (horizontal ? parentGroupRect.bottom : parentGroupRect.right) +
          ToolbarGrid.blockPadding +
          ToolbarGrid.lineGap +
          ToolbarGrid.trayPadding,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('拖动选区并松手后，没有新的收起组，展开中的组也不再重新从父级位置开始（#142）', (tester) async {
    final png = await tester.runAsync(_image);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const channel = MethodChannel('test/toolbar-drag-no-replay');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'drag-no-replay',
          ...capture!,
          'width': 320,
          'height': 240,
          'cropX': 40,
          'cropY': 20,
          'cropWidth': 120,
          'cropHeight': 60,
          'canCaptureMedia': true,
          ...ScreenshotToolbarPreferences().toMap(),
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();

    final record = find.byKey(const Key(ScreenshotActions.record));
    final crop = find.byKey(const Key(ScreenshotActions.crop));
    final settledDelta = tester.getCenter(record) - tester.getCenter(crop);

    final canvas = tester.getRect(find.byKey(const Key('screenshot-canvas')));
    final gesture = await tester.startGesture(
      canvas.topLeft + const Offset(10, 10),
    );
    await gesture.moveBy(const Offset(100, 80));
    await tester.pump();
    expect(find.byKey(const Key('screenshot-toolbar')), findsNothing);
    expect(record.hitTestable(), findsNothing);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byKey(const Key('screenshot-closing-group-0')), findsNothing);
    expect(tester.getCenter(record) - tester.getCenter(crop), settledDelta);
    await tester.pumpAndSettle();
    expect(tester.getCenter(record) - tester.getCenter(crop), settledDelta);
  });

  testWidgets('收起未完成时快速切换带二级菜单的工具立即打断，不挤压新属性组或附加行到第三行（#67、#1）', (tester) async {
    final png = await tester.runAsync(_image);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const channel = MethodChannel('test/toolbar-fast-interrupt');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'fast-interrupt',
          ...capture!,
          'width': 320,
          'height': 240,
          'cropX': 40,
          'cropY': 20,
          'cropWidth': 120,
          'cropHeight': 60,
          'canCaptureMedia': true,
          ...ScreenshotToolbarPreferences().toMap(),
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key(ScreenshotActions.cursor)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 48));
    expect(find.byKey(const Key('screenshot-closing-group-0')), findsOneWidget);

    await tester.tap(find.byKey(const Key(ScreenshotActions.rect)));
    await tester.pump();
    expect(find.byKey(const Key('screenshot-closing-group-0')), findsNothing);
    final attrGroup = find.byKey(const Key('screenshot-attributes-group-0'));
    expect(attrGroup, findsOneWidget);
    expect(
      find.ancestor(of: attrGroup, matching: find.byType(LiquidSplit)),
      findsOneWidget,
    );
    final gridGroup0 = find.byKey(const Key('screenshot-grid-group-0'));
    final horizontal =
        tester.widget<Flex>(gridGroup0).direction == Axis.horizontal;
    final rectGroupRect = tester.getRect(gridGroup0);
    final attrGroupRect = tester.getRect(attrGroup);
    expect(
      horizontal ? attrGroupRect.top : attrGroupRect.left,
      (horizontal ? rectGroupRect.bottom : rectGroupRect.right) +
          ToolbarGrid.blockPadding +
          ToolbarGrid.lineGap +
          ToolbarGrid.trayPadding,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key(ScreenshotActions.brush)));
    await tester.pump();
    expect(find.byKey(const Key('screenshot-closing-group-0')), findsNothing);
    expect(
      find.ancestor(of: attrGroup, matching: find.byType(LiquidSplit)),
      findsOneWidget,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key(ScreenshotActions.ratio)));
    await tester.pump();
    expect(find.byKey(const Key('screenshot-closing-group-0')), findsNothing);
    expect(
      find.ancestor(
        of: find.byKey(const Key('ratio-row')),
        matching: find.byType(LiquidSplit),
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key(ScreenshotActions.beautify)));
    await tester.pump();
    expect(find.byKey(const Key('screenshot-closing-group-0')), findsNothing);
    expect(
      find.ancestor(
        of: find.byKey(const Key('screenshot-beautify-row')),
        matching: find.byType(LiquidSplit),
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key(ScreenshotActions.crop)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key(ScreenshotActions.record)));
    await tester.pump();
    expect(
      find.ancestor(
        of: find.byKey(const Key('recording-targets-row')),
        matching: find.byType(LiquidSplit),
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('展开与收起中途反向切换原位平滑接续，快速收起在短时内完成移除（#67）', (tester) async {
    final png = await tester.runAsync(_image);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const channel = MethodChannel('test/toolbar-reverse-interrupt');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'reverse-interrupt',
          ...capture!,
          'width': 320,
          'height': 240,
          'cropX': 40,
          'cropY': 20,
          'cropWidth': 120,
          'cropHeight': 60,
          'canCaptureMedia': true,
          ...ScreenshotToolbarPreferences().toMap(),
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();

    final record = find.byKey(const Key(ScreenshotActions.record));
    final crop = find.byKey(const Key(ScreenshotActions.crop));
    final settledOffset = tester.getCenter(record) - tester.getCenter(crop);

    await tester.tap(find.byKey(const Key(ScreenshotActions.cursor)));
    await tester.pumpAndSettle();

    await tester.tap(crop);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 32));
    final midDistance =
        (tester.getCenter(record) - tester.getCenter(crop)).distance;
    expect(midDistance, greaterThan(2.0));
    expect(midDistance, lessThan(settledOffset.distance - 2.0));

    await tester.tap(find.byKey(const Key(ScreenshotActions.cursor)));
    await tester.pump();
    expect(find.byKey(const Key('screenshot-closing-group-0')), findsOneWidget);
    expect(
      (tester.getCenter(record) - tester.getCenter(crop)).distance,
      closeTo(midDistance, 2.0),
    );
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.byKey(const Key('screenshot-closing-group-0')), findsNothing);

    await tester.tap(crop);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key(ScreenshotActions.cursor)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    await tester.tap(crop);
    await tester.pump();
    expect(find.byKey(const Key('screenshot-closing-group-0')), findsNothing);
    await tester.pumpAndSettle();
    expect(tester.getCenter(record) - tester.getCenter(crop), settledOffset);
    expect(tester.takeException(), isNull);
  });

  testWidgets('画笔工具下展开美化不漏出画笔属性，且次级行靠起点排列不左右分散（#67、#141）', (tester) async {
    final png = await tester.runAsync(_image);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const channel = MethodChannel('test/toolbar-beautify-isolation');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'beautify-isolation',
          ...capture!,
          'width': 320,
          'height': 240,
          'cropX': 40,
          'cropY': 20,
          'cropWidth': 120,
          'cropHeight': 60,
          'canCaptureMedia': true,
          ...ScreenshotToolbarPreferences().toMap(),
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key(ScreenshotActions.brush)));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('screenshot-attributes-group-0')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key(ScreenshotActions.beautify)));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('screenshot-attributes-group-0')),
      findsNothing,
    );
    expect(find.byKey(const Key('screenshot-beautify-row')), findsOneWidget);
    final stickerGroup = tester.getRect(
      find.byKey(const Key('screenshot-children-group-0')),
    );
    expect(
      stickerGroup.left,
      tester.getRect(find.byKey(const Key(ScreenshotActions.beautify))).left +
          ToolbarGrid.trayPadding,
    );

    await tester.tap(find.byKey(const Key(ScreenshotActions.beautify)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-beautify-row')), findsNothing);
    expect(
      find.byKey(const Key('screenshot-attributes-group-0')),
      findsOneWidget,
    );

    final columns = [
      for (final column in ScreenshotToolbarPreferences().columns)
        ToolbarColumn(column.modifiers, [
          for (final slot in column.slots)
            slot == ScreenshotActions.arrow ? null : slot,
        ]),
    ];
    final prefs = ScreenshotToolbarPreferences(
      columns: columns,
      children: {
        ...ScreenshotActions.defaultChildren,
        ScreenshotActions.rect: const [ScreenshotActions.arrow],
      },
    );
    const codec = StandardMethodCodec();
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        MethodCall(MethodNames.screenshotChanged, {
          'id': 'beautify-isolation-custom',
          ...capture!,
          'width': 320,
          'height': 240,
          'cropX': 40,
          'cropY': 20,
          'cropWidth': 120,
          'cropHeight': 60,
          'canCaptureMedia': true,
          ...prefs.toMap(),
        }),
      ),
      (_) {},
    );
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key(ScreenshotActions.rect)));
    await tester.pumpAndSettle();
    final childRect = tester.getRect(
      find.byKey(const Key('screenshot-children-group-0')),
    );
    final attrRect = tester.getRect(
      find.byKey(const Key('screenshot-attributes-group-0')),
    );
    final customGrid0 = tester.getRect(
      find.byKey(const Key('screenshot-grid-group-0')),
    );
    expect(childRect.top, attrRect.top);
    expect(customGrid0.top, lessThan(childRect.top));
    expect(
      childRect.left,
      tester.getRect(find.byKey(const Key(ScreenshotActions.rect))).left +
          ToolbarGrid.trayPadding,
    );
    expect(
      attrRect.left - childRect.right,
      ToolbarGrid.traySeparatorGap * 2 + 1,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('工具顺序与局部快捷键生效，文字编辑不切换工具，更新配置保留画布', (tester) async {
    final png = await tester.runAsync(_image);
    final capture = await tester.runAsync(() => capturePixels(png!));
    final rest = [
      for (final id in ScreenshotActions.icons.keys.toList().reversed)
        if (id != ScreenshotActions.text && id != ScreenshotActions.crop) id,
    ];
    final preferences = ScreenshotToolbarPreferences(
      columns: [
        ToolbarColumn(0, [ScreenshotActions.text, ...rest.sublist(0, 5)]),
        ToolbarColumn(ToolbarModifiers.command, [
          rest[5],
          ScreenshotActions.crop,
          ...rest.sublist(6, 10),
        ]),
        ToolbarColumn(ToolbarModifiers.option, rest.sublist(10, 16)),
        ToolbarColumn(ToolbarModifiers.control, [
          ...rest.sublist(16),
          null,
          null,
          null,
        ]),
      ],
      children: const {},
      hidden: {ScreenshotActions.text},
    );
    const channel = MethodChannel('test/toolbar-config');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'tool-test',
          ...capture!,
          'width': 320,
          'height': 240,
          ...preferences.toMap(),
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    final canvas = tester.getRect(find.byKey(const Key('screenshot-canvas')));
    final close = tester.getTopLeft(
      find.byKey(const Key(ScreenshotActions.close)),
    );
    final crop = tester.getTopLeft(
      find.byKey(const Key(ScreenshotActions.crop)),
    );
    final horizontal =
        tester
            .widget<Flex>(find.byKey(const Key('screenshot-grid-group-0')))
            .direction ==
        Axis.horizontal;
    final group0 = tester.getRect(
      find.byKey(const Key('screenshot-grid-group-0')),
    );
    final group1 = tester.getRect(
      find.byKey(const Key('screenshot-grid-group-1')),
    );
    final paired = horizontal
        ? group0.top == group1.top
        : group0.left == group1.left;
    expect(
      horizontal == paired ? close.dx < crop.dx : close.dy < crop.dy,
      isTrue,
    );
    expect(find.byKey(const Key(ScreenshotActions.text)), findsNothing);
    Future<void> nativeSlot(String id, int modifiers, int digit) async {
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(MethodNames.screenshotToolbarSlot, {
            'id': id,
            'modifiers': modifiers,
            'digit': digit,
          }),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    await nativeSlot('stale', 0, 1);
    expect(find.byKey(const Key(ScreenshotActions.sizeUp)), findsNothing);
    await nativeSlot('tool-test', 0, 1);
    expect(find.byKey(const Key(ScreenshotActions.sizeUp)), findsOneWidget);
    await nativeSlot('tool-test', ToolbarModifiers.command, 2);
    expect(find.byKey(const Key(ScreenshotActions.sizeUp)), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key(ScreenshotActions.sizeUp)), findsOneWidget);
    await tester.tapAt(canvas.center);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await nativeSlot('tool-test', ToolbarModifiers.command, 2);
    expect(find.byKey(const Key(ScreenshotActions.sizeUp)), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const Key(ScreenshotActions.sizeUp)), findsOneWidget);
    await tester.enterText(find.byType(TextField), '保留草稿');
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(
          MethodNames.screenshotToolbarChanged,
          ScreenshotToolbarPreferences().toMap(),
        ),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.text('保留草稿'), findsOneWidget);
    expect(find.byKey(const Key(ScreenshotActions.text)), findsOneWidget);
    expect(tester.getRect(find.byKey(const Key('screenshot-canvas'))), canvas);
  });

  testWidgets('主键盘和小键盘回车复制完整像素并退出，文字输入中回车只换行', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final png = await tester.runAsync(_image);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const channel = MethodChannel('test/screenshot-enter');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Uint8List? clipboard;
    var ended = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.getScreenshot:
          return {
            'id': 'enter',
            ...capture!,
            'width': 320,
            'height': 240,
            'capturedAt': 0,
          };
        case MethodNames.copyScreenshot:
          clipboard = (call.arguments as Map)['bytes'] as Uint8List;
          return null;
        case MethodNames.closeScreenshot:
          await messenger.handlePlatformMessage(
            channel.name,
            codec.encodeMethodCall(
              const MethodCall(
                MethodNames.screenshotChanged,
                <String, Object>{},
              ),
            ),
            (_) {},
          );
          ended.complete();
          return null;
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    for (final key in [
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.numpadEnter,
    ]) {
      clipboard = null;
      ended = Completer<void>();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        ScreenshotApp(key: ValueKey(key), channel: channel),
      );
      await awaitCaptureSource(tester);
      await tester.pumpAndSettle();
      final canvas = tester.getRect(find.byKey(const Key('screenshot-canvas')));
      final toolbar = tester.getRect(
        find.byKey(const Key('screenshot-toolbar')),
      );
      expect(canvas, const Rect.fromLTWH(0, 0, 960, 740));
      expect(canvas.overlaps(toolbar), isTrue);
      await tester.runAsync(() async {
        await tester.sendKeyEvent(key);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(ended.isCompleted, isTrue);
      expect(find.byKey(const Key('screenshot-canvas')), findsNothing);
      final size = await tester.runAsync(() async {
        final decoder = await ui.instantiateImageCodec(clipboard!);
        final frame = await decoder.getNextFrame();
        final size = Size(
          frame.image.width.toDouble(),
          frame.image.height.toDouble(),
        );
        final pixels = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        expect(pixels!.buffer.asUint8List().sublist((320 * 240 - 1) * 4), [
          0x22,
          0x55,
          0xAA,
          0xFF,
        ]);
        frame.image.dispose();
        decoder.dispose();
        return size;
      });
      expect(size, const Size(320, 240));
    }

    clipboard = null;
    ended = Completer<void>();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(
      const ScreenshotApp(key: ValueKey('text-enter'), channel: channel),
    );
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('screenshot-tool-text')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('screenshot-canvas')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('screenshot-text-field')),
      'Hello',
    );
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        composing: TextRange(start: 0, end: 2),
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        const MethodCall(MethodNames.confirmScreenshot, {'id': 'enter'}),
      ),
      (_) {},
    );
    await tester.pump();
    expect(find.byKey(const Key('screenshot-text-field')), findsOneWidget);
    expect(clipboard, isNull);
    await tester.enterText(
      find.byKey(const Key('screenshot-text-field')),
      'Hello',
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(find.byKey(const Key('screenshot-text-field')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-text-field')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-text-field')), findsNothing);
    expect(clipboard, isNull);
    expect(ended.isCompleted, isFalse);
    await tester.runAsync(() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-canvas')), findsNothing);
    expect(clipboard, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('左右竖栏完整可用，状态可见，拖动中保持画布位置且隐藏工具栏', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final png = await tester.runAsync(_image);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const channel = MethodChannel('test/screenshot-toolbar-sides');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final snapshot = <String, Object?>{
      'id': 'sides',
      ...capture!,
      'width': 320,
      'height': 240,
      'capturedAt': 0,
      'cropX': 0,
      'cropY': 0,
      'cropWidth': 160,
      'cropHeight': 240,
    };
    Uint8List? clipboard;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) return snapshot;
      if (call.method == MethodNames.copyScreenshot) {
        clipboard = (call.arguments as Map)['bytes'] as Uint8List;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    for (final x in [0, 160]) {
      await messenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(
          MethodCall(MethodNames.screenshotChanged, {...snapshot, 'cropX': x}),
        ),
        (_) {},
      );
      await awaitCaptureSource(tester);
      await tester.pumpAndSettle();
      final canvas = tester.getRect(find.byKey(const Key('screenshot-canvas')));
      final crop = mapRectToFitted(
        Rect.fromLTWH(x.toDouble(), 0, 160, 240),
        const Size(320, 240),
        canvas,
      );
      final toolbar = tester.getRect(
        find.byKey(const Key('screenshot-toolbar')),
      );
      expect(
        tester
            .widget<Flex>(find.byKey(const Key('screenshot-grid-group-0')))
            .direction,
        Axis.vertical,
      );
      expect(toolbar.overlaps(crop), isFalse);
      expect(toolbar.left > crop.right || toolbar.right < crop.left, isTrue);
      await tester.ensureVisible(find.byKey(const Key('screenshot-copy')));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('screenshot-copy')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(clipboard, isNotNull);
      expect(
        toolbar.overlaps(
          tester.getRect(find.byKey(const Key('toolbar-feedback-bubble'))),
        ),
        isFalse,
      );
      final size = await tester.runAsync(() async {
        final decoder = await ui.instantiateImageCodec(clipboard!);
        final frame = await decoder.getNextFrame();
        final size = Size(
          frame.image.width.toDouble(),
          frame.image.height.toDouble(),
        );
        frame.image.dispose();
        decoder.dispose();
        return size;
      });
      expect(size, const Size(160, 240));
    }
    final canvas = tester.getRect(find.byKey(const Key('screenshot-canvas')));
    final gesture = await tester.startGesture(canvas.center);
    await gesture.moveBy(const Offset(80, 80));
    await tester.pump();
    expect(find.byKey(const Key('screenshot-toolbar')), findsNothing);
    expect(tester.getRect(find.byKey(const Key('screenshot-canvas'))), canvas);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-toolbar')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('复制成功在工具栏外浮动一秒，重复成功重新计时，换图立即清除', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_image);
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/copy-feedback');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final snapshot = <String, Object?>{
      'id': 'feedback',
      ...capture!,
      'width': 320,
      'height': 240,
      'capturedAt': 0,
    };
    Uint8List? clipboard;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) return snapshot;
      if (call.method == MethodNames.copyScreenshot) {
        clipboard = (call.arguments as Map)['bytes'] as Uint8List;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    final feedback = find.byKey(const Key('toolbar-feedback-bubble'));
    final copyButton = find.byKey(const Key('screenshot-copy'));

    Future<void> copy() async {
      await tester.ensureVisible(copyButton);
      await tester.tap(copyButton);
      await tester.pump();
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (tester.widget<IconButton>(copyButton).onPressed != null &&
            feedback.evaluate().isNotEmpty) {
          return;
        }
      }
      fail('复制没有在限定时间内完成');
    }

    await copy();
    expect(clipboard, isNotNull);
    final toolbar = tester.getRect(find.byKey(const Key('screenshot-toolbar')));
    expect(tester.getRect(feedback).bottom, lessThan(toolbar.top));
    expect(
      find.descendant(
        of: find.byKey(const Key('screenshot-toolbar')),
        matching: find.text('已复制图片'),
      ),
      findsNothing,
    );
    await tester.pump(const Duration(milliseconds: 500));
    await copy();
    await tester.pump(const Duration(milliseconds: 999));
    expect(feedback, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(feedback, findsNothing);
    expect(find.text('已复制图片'), findsNothing);
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);

    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        MethodCall(MethodNames.screenshotChanged, {
          ...snapshot,
          'id': 'top',
          'cropX': 70,
          'cropY': 24,
          'cropWidth': 200,
          'cropHeight': 216,
        }),
      ),
      (_) {},
    );
    await awaitCaptureSource(tester);
    await copy();
    final toastRect = tester.getRect(feedback);
    expect(
      (Offset.zero & const Size(960, 740)).contains(toastRect.topLeft),
      isTrue,
    );
    expect(
      (Offset.zero & const Size(960, 740)).contains(toastRect.bottomRight),
      isTrue,
    );
    expect(
      toastRect.overlaps(
        tester.getRect(find.byKey(const Key('screenshot-toolbar'))),
      ),
      isFalse,
    );
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        MethodCall(MethodNames.screenshotChanged, {...snapshot, 'id': 'next'}),
      ),
      (_) {},
    );
    await awaitCaptureSource(tester);
    expect(feedback, findsNothing);
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });
  testWidgets('识别文字后复制的迟到成功不能在替换后的截图显示提示', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_image);
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/copy-feedback-stale-text');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final copyReply = Completer<void>();
    final copyPending = Completer<void>();
    final snapshot = <String, Object?>{
      'id': 'first',
      ...capture!,
      'width': 320,
      'height': 240,
      'capturedAt': 0,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) return snapshot;
      if (call.method == MethodNames.recognizeText) {
        return {'text': 'Hello', 'codes': <Object>[]};
      }
      if (call.method == MethodNames.copyText) {
        copyPending.complete();
        await copyReply.future;
        return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('screenshot-ocr-copy')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('screenshot-ocr-copy')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.tap(find.byTooltip('复制全部'));
    await tester.pump();
    await copyPending.future;
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        MethodCall(MethodNames.screenshotChanged, {
          ...snapshot,
          'id': 'second',
        }),
      ),
      (_) {},
    );
    await awaitCaptureSource(tester);
    copyReply.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('toolbar-feedback-bubble')), findsNothing);
    expect(find.text('已复制文字'), findsNothing);
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);
  });

  test('极窄与零尺寸视口下 ScreenshotEditorLayout.place 安全夹紧且不抛异常（#144）', () {
    for (final viewport in const [Size.zero, Size(12, 12)]) {
      final layout = ScreenshotEditorLayout.place(
        viewport: viewport,
        image: const Size(200, 200),
        crop: const Rect.fromLTWH(0, 0, 200, 200),
      );
      expect(layout.toolbar.width, greaterThanOrEqualTo(0));
      expect(layout.toolbar.height, greaterThanOrEqualTo(0));
      expect(layout.toolbar.left.isFinite, isTrue);
      expect(layout.toolbar.top.isFinite, isTrue);
    }
  });

  testWidgets('ColorPicker 非法 HEX 后点击渐变预设清除错误并恢复应用按钮（#144）', (tester) async {
    final results = <Object>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ColorPicker(
            initial: (color: Colors.black, gradient: null),
            onApply: results.add,
            onCancel: () {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('渐变'));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('color-hex')), 'ZZZZ');
    await tester.pump();
    expect(find.text('请输入6位十六进制颜色'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('apply-color')))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const Key('gradient-preset-1')));
    await tester.pump();
    expect(find.text('请输入6位十六进制颜色'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('apply-color')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('apply-color')));
    await tester.pump();
    expect(results, hasLength(1));
  });

  testWidgets('截图错误提示停留 2 秒并支持悬停暂停与手动关闭（#144）', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_image);
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/screenshot-error-feedback');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final snapshot = <String, Object?>{
      'id': 'err-shot',
      ...capture!,
      'width': 320,
      'height': 240,
      'capturedAt': 0,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) return snapshot;
      if (call.method == MethodNames.copyScreenshot) {
        throw PlatformException(code: 'copy_failed', message: '写入剪贴板失败');
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();

    final copyButton = find.byKey(const Key(ScreenshotActions.copy));
    final feedback = find.byKey(const Key('toolbar-feedback-bubble'));
    Future<void> triggerError() async {
      await tester.ensureVisible(copyButton);
      await tester.tap(copyButton);
      await tester.pump();
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (feedback.evaluate().isNotEmpty) return;
      }
      fail('截图错误反馈没有在限定时间内出现');
    }

    await triggerError();
    expect(find.text('写入剪贴板失败'), findsOneWidget);
    final dismiss = find.byKey(const Key('toolbar-feedback-dismiss'));
    expect(dismiss, findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(feedback, findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(feedback));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(feedback, findsOneWidget);

    await mouse.moveTo(Offset.zero);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1999));
    expect(feedback, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(feedback, findsNothing);

    await triggerError();
    expect(feedback, findsOneWidget);
    await tester.tap(dismiss);
    await tester.pump();
    expect(feedback, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('识别结果弹窗隔离 Enter/Esc 快捷键、夹紧窄视口并在顶层显示反馈（#144）', (tester) async {
    tester.view.physicalSize = const Size(520, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(() => _image(width: 520, height: 420));
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/recognition-isolation');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    final snapshot = <String, Object?>{
      'id': 'rec-iso',
      ...capture!,
      'width': 520,
      'height': 420,
      'capturedAt': 0,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == MethodNames.getScreenshot) return snapshot;
      if (call.method == MethodNames.recognizeText) {
        return {'text': '# 标题\n\n识别正文内容', 'codes': <Object>[]};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const Key(ScreenshotActions.ocrCopy)),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key(ScreenshotActions.ocrCopy)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();

    expect(find.text('识别正文内容'), findsOneWidget);
    final dragRect = tester.getRect(
      find.byKey(const ValueKey('recognized-text-drag-area')),
    );
    expect(dragRect.width, lessThanOrEqualTo(504));

    calls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(calls.where((m) => m == MethodNames.copyScreenshot), isEmpty);
    expect(calls.where((m) => m == MethodNames.closeScreenshot), isEmpty);
    expect(find.text('识别正文内容'), findsOneWidget);

    await tester.tap(find.byTooltip('复制全部'));
    await tester.pump();
    final bubble = find.byKey(const Key('toolbar-feedback-bubble'));
    expect(bubble, findsOneWidget);
    expect(bubble.hitTestable(), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('识别正文内容'), findsNothing);
    expect(calls.where((m) => m == MethodNames.closeScreenshot), isEmpty);
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });
}

Future<Uint8List> _image({int width = 320, int height = 240}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFF2255AA), BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

Future<
  ({
    MethodChannel channel,
    List<MethodCall> calls,
    Map<String, Object?> snapshot,
  })
>
_pumpSelectedCrop(WidgetTester tester, String name) async {
  tester.view.physicalSize = const Size(960, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final png = await tester.runAsync(
    () => _coordinateImage(width: 960, height: 740),
  );
  final capture = await tester.runAsync(() => capturePixels(png!));
  final channel = MethodChannel(name);
  final calls = <MethodCall>[];
  final snapshot = <String, Object?>{
    'id': 'crop',
    ...capture!,
    'width': 960,
    'height': 740,
    'capturedAt': 0,
    'cropX': 200,
    'cropY': 180,
    'cropWidth': 400,
    'cropHeight': 300,
    'cropSelected': true,
  };
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    return call.method == MethodNames.getScreenshot ? snapshot : null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  await tester.pumpWidget(ScreenshotApp(channel: channel));
  await awaitCaptureSource(tester);
  await tester.pumpAndSettle();
  return (channel: channel, calls: calls, snapshot: snapshot);
}

Future<void> _arrow(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  List<LogicalKeyboardKey> modifiers = const [],
  int times = 1,
}) async {
  for (final modifier in modifiers) {
    await tester.sendKeyDownEvent(modifier);
  }
  for (var i = 0; i < times; i++) {
    await tester.sendKeyEvent(key);
  }
  for (final modifier in modifiers.reversed) {
    await tester.sendKeyUpEvent(modifier);
  }
  await tester.pumpAndSettle();
}

Future<Uint8List> _coordinateImage({
  required int width,
  required int height,
}) async {
  final pixels = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final offset = (y * width + x) * 4;
      pixels[offset] = x & 0xFF;
      pixels[offset + 1] = y & 0xFF;
      pixels[offset + 2] = (x >> 8) | ((y >> 8) << 4);
      pixels[offset + 3] = 0xFF;
    }
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  final image = await completer.future;
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

Future<(Size, Rect)> _copyCrop(
  WidgetTester tester,
  List<MethodCall> calls,
) async {
  calls.clear();
  final copy = find.byKey(const Key(ScreenshotActions.copy));
  await tester.ensureVisible(copy);
  final rect = await tester.runAsync(() async {
    await tester.tap(copy);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final bytes =
        (calls
                    .firstWhere(
                      (call) => call.method == MethodNames.copyScreenshot,
                    )
                    .arguments
                as Map)['bytes']
            as Uint8List;
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final rgba = (await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!;
    final blue = rgba.getUint8(2);
    final rect = Rect.fromLTWH(
      (rgba.getUint8(0) | ((blue & 0x0F) << 8)).toDouble(),
      (rgba.getUint8(1) | ((blue >> 4) << 8)).toDouble(),
      frame.image.width.toDouble(),
      frame.image.height.toDouble(),
    );
    frame.image.dispose();
    codec.dispose();
    return rect;
  });
  await tester.pumpAndSettle();
  return (rect!.size, rect);
}
