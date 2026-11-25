import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/preference_keys.dart';
import 'package:transnap/src/common/constants/screenshot_actions.dart';
import 'package:transnap/src/screenshot/screenshot_app.dart';

import 'support/capture_pixels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('取色：悬停显示指针处色值，单击复制源像素的 #RRGGBB', (tester) async {
    final editor = await _pumpEditor(tester, 'test/eyedropper');
    await tester.tap(find.byKey(const Key(ScreenshotActions.eyedropper)));
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(100, 200));
    await mouse.moveTo(const Offset(101, 200));
    await tester.runAsync(() => Future<void>.delayed(_decode));
    await tester.pump();
    expect(find.byKey(const Key('eyedropper-label')), findsOneWidget);
    expect(find.text('#3366CC'), findsOneWidget);
    await mouse.moveTo(const Offset(500, 200));
    await tester.pump();
    expect(find.text('#FFFFFF'), findsOneWidget);

    await tester.tapAt(const Offset(100, 200));
    await _settle(tester);
    expect(editor.texts, ['#3366CC']);
    expect(find.text('已复制 #3366CC'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('标尺：拖动显示长度与 Δx × Δy，测量线不进入导出，切换工具后清除', (tester) async {
    final editor = await _pumpEditor(tester, 'test/ruler');
    await _copy(tester, editor);
    await tester.tap(find.byKey(const Key(ScreenshotActions.ruler)));
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(100, 100), const Offset(60, 80));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ruler-label')), findsOneWidget);
    expect(find.text('100.0 px（60 × 80）'), findsOneWidget);
    await _copy(tester, editor);
    expect(editor.copies, hasLength(2));
    expect(editor.copies.last, editor.copies.first);
    await tester.tap(find.byKey(const Key(ScreenshotActions.crop)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ruler-label')), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('确认截图按设置执行：复制并保存只发一次带复制标记的保存并关闭，改为复制图片后只复制并关闭', (tester) async {
    final editor = await _pumpEditor(
      tester,
      'test/confirm-action',
      confirmAction: 'copyAndSave',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = StandardMethodCodec();
    Future<void> confirm() => tester.runAsync(() async {
      await messenger.handlePlatformMessage(
        editor.channel.name,
        codec.encodeMethodCall(
          const MethodCall(MethodNames.confirmScreenshot, {'id': 'measure'}),
        ),
        (_) {},
      );
      await Future<void>.delayed(_decode);
    });
    await confirm();
    await tester.pumpAndSettle();
    expect(
      editor.calls.where(
        (method) => {
          MethodNames.saveScreenshot,
          MethodNames.copyScreenshot,
          MethodNames.closeScreenshot,
        }.contains(method),
      ),
      [MethodNames.saveScreenshot, MethodNames.closeScreenshot],
    );
    expect(editor.copies, hasLength(1));

    await messenger.handlePlatformMessage(
      editor.channel.name,
      codec.encodeMethodCall(
        const MethodCall(MethodNames.screenshotToolbarChanged, {
          PreferenceKeys.screenshotConfirmAction: 'copy',
        }),
      ),
      (_) {},
    );
    await tester.pump(const Duration(seconds: 2));
    await confirm();
    await tester.pumpAndSettle();
    expect(
      editor.calls.where((method) => method == MethodNames.saveScreenshot),
      hasLength(1),
    );
    expect(editor.copies, hasLength(2));
    expect(_closes(editor), 2);
    await tester.pump(const Duration(seconds: 2));
  });
}

const _decode = Duration(milliseconds: 200);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(_decode));
    await tester.pump();
  }
}

typedef _Editor = ({
  MethodChannel channel,
  List<String> calls,
  List<Uint8List> copies,
  List<String> texts,
});

int _closes(_Editor editor) => editor.calls
    .where((method) => method == MethodNames.closeScreenshot)
    .length;

Future<_Editor> _pumpEditor(
  WidgetTester tester,
  String name, {
  String? confirmAction,
}) async {
  tester.view.physicalSize = const Size(640, 480);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final png = await tester.runAsync(_png);
  final capture = await tester.runAsync(() => capturePixels(png!));
  final channel = MethodChannel(name);
  final calls = <String>[];
  final copies = <Uint8List>[];
  final texts = <String>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call.method);
    final arguments = call.arguments as Map?;
    switch (call.method) {
      case MethodNames.getScreenshot:
        return {
          'id': 'measure',
          ...capture!,
          'width': 640,
          'height': 480,
          'capturedAt': 0,
          PreferenceKeys.screenshotConfirmAction: ?confirmAction,
        };
      case MethodNames.copyScreenshot:
        copies.add(arguments!['bytes'] as Uint8List);
      case MethodNames.saveScreenshot:
        if (arguments!['copy'] == true) copies.add(arguments['bytes'] as Uint8List);
        return '/tmp/截图.png';
      case MethodNames.copyText:
        texts.add(arguments!['text'] as String);
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  await tester.pumpWidget(ScreenshotApp(channel: channel));
  await awaitCaptureSource(tester);
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(_decode));
  await tester.pump();
  return (channel: channel, calls: calls, copies: copies, texts: texts);
}

Future<void> _copy(WidgetTester tester, _Editor editor) async {
  final copy = find.byKey(const Key(ScreenshotActions.copy));
  await tester.ensureVisible(copy);
  await tester.runAsync(() async {
    await tester.tap(copy);
    await Future<void>.delayed(_decode);
  });
  await tester.pumpAndSettle();
}

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFFFFFFFF), BlendMode.src);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 320, 480),
    Paint()..color = const Color(0xFF3366CC),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(640, 480);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

