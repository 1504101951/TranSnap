import 'package:transnap/src/common/constants/method_names.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/emoji_catalog.dart';
import 'package:transnap/src/common/constants/screenshot_actions.dart';
import 'package:transnap/src/common/constants/toolbar_grid.dart';
import 'package:transnap/src/common/widgets/app_motion.dart';
import 'package:transnap/src/settings/screenshot_toolbar_preferences.dart';
import 'package:transnap/src/common/constants/preference_keys.dart';
import 'package:transnap/src/common/widgets/native_glass.dart';
import 'package:transnap/src/common/constants/screenshot_enums.dart';
import 'package:transnap/src/common/utils/geometry.dart';
import 'package:transnap/src/common/utils/screenshot_filename.dart';
import 'package:transnap/src/screenshot/edit_document.dart';
import 'package:transnap/src/screenshot/recognized_text_panel.dart';
import 'package:transnap/src/screenshot/editor_surface.dart';
import 'package:transnap/src/screenshot/screenshot_app.dart';
import 'package:transnap/src/screenshot/sticker_panel.dart';
import 'package:transnap/src/settings/app_settings.dart';

import 'support/capture_pixels.dart';

void main() {
  test('截图快捷键独立保存并拒绝与翻译使用同一组合', () {
    final settings = AppSettings(primaryLanguage: 'zh-CN');
    settings.screenshotShortcutKeyCode = 7;
    settings.screenshotShortcutLabel = 'X';
    settings.validate();
    final restored = AppSettings.fromMap(settings.toMap());
    expect(restored.screenshotShortcutKeyCode, 7);
    expect(restored.shortcutKeyCode, 17);
    restored.screenshotShortcutKeyCode = restored.shortcutKeyCode;
    expect(restored.validate, throwsFormatException);
    expect(
      screenshotFilename(DateTime(2026, 9, 6, 1, 2, 3, 4)),
      '截图_2026-09-06_01-02-03-004.png',
    );
    expect(
      pinOriginAppKit(
        crop: const Rect.fromLTWH(2, 2, 4, 4),
        display: const Rect.fromLTWH(100, 200, 800, 600),
        image: const Size(8, 8),
      ),
      const Offset(300, 350),
    );
  });

  test('编辑文档：删除标注可撤销并回到原位置，重做再次删除', () async {
    final document = EditDocument();
    document.loadCapture(await decodePng(await _pngCheckerboard()));
    final ids = [
      for (final text in ['a', 'b', 'c'])
        document.addAnnotation(
          EditAnnotation(
            id: '',
            kind: AnnotationKind.text,
            bounds: const Rect.fromLTWH(0, 0, 4, 4),
            text: text,
          ),
        ),
    ];
    document.removeAnnotation(ids[1]);
    expect(document.annotations.map((item) => item.text), ['a', 'c']);
    document.undo();
    expect(document.annotations.map((item) => item.text), ['a', 'b', 'c']);
    document.redo();
    expect(document.annotations.map((item) => item.text), ['a', 'c']);
    document.undo();
    document.removeAnnotation('missing');
    document.undo();
    expect(document.annotations.map((item) => item.text), ['a', 'b']);
  });

  test('文字框高度随宽度换行增长，空文字仍占一行', () {
    const text = 'aaaa aaaa aaaa aaaa';
    final wide = textBoxHeight(text: text, fontSize: 18, width: 2000);
    final narrow = textBoxHeight(text: text, fontSize: 18, width: 100);
    expect(narrow, greaterThan(wide));
    expect(textBoxHeight(text: '', fontSize: 18, width: 2000), wide);
  });

  test('编辑文档：裁剪改变导出尺寸，标注改像素，撤销重做可逆，遮挡导出不可还原', () async {
    final source = await _pngCheckerboard();
    final document = EditDocument();
    document.loadCapture(await decodePng(source));

    document.setCrop(const Rect.fromLTWH(0, 0, 4, 4));
    final cropped = await document.renderPng();
    final croppedImage = await _decode(cropped);
    expect(croppedImage.width, 4);
    expect(croppedImage.height, 4);
    expect(await _pixel(croppedImage, 1, 1), _red);
    croppedImage.dispose();

    expect(document.canUndo, isFalse);
    document.setCrop(const Rect.fromLTWH(0, 0, 8, 8));
    expect(document.cropRect, const Rect.fromLTWH(0, 0, 8, 8));
    document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.rectangle,
        bounds: Rect.fromLTWH(0, 0, 3, 3),
        color: Color(0xFF00FF00),
        strokeWidth: 1,
      ),
    );
    document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.arrow,
        bounds: Rect.fromLTWH(0, 0, 3, 3),
        start: Offset(0, 3),
        end: Offset(3, 0),
        color: Color(0xFFFFFF00),
        strokeWidth: 1,
      ),
    );
    document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.text,
        bounds: Rect.fromLTWH(0, 0, 2, 2),
        text: 'A',
        color: Color(0xFFFFFFFF),
        fontSize: 6,
      ),
    );
    document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.mask,
        bounds: Rect.fromLTWH(5, 5, 3, 3),
        color: Color(0xFF000000),
      ),
    );
    expect(document.annotations.length, 4);
    document.setCrop(const Rect.fromLTWH(1, 1, 6, 6));
    expect(document.annotations.length, 4);
    expect(document.annotations.first.kind, AnnotationKind.rectangle);
    document.setCrop(const Rect.fromLTWH(0, 0, 8, 8));

    final annotated = await document.renderPng();
    final annotatedImage = await _decode(annotated);
    expect(annotatedImage.width, 8);
    expect(_nearColor(await _pixel(annotatedImage, 6, 6), _black), isTrue);
    expect(_nearColor(await _pixel(annotatedImage, 6, 6), _blue), isFalse);
    expect(listEquals(annotated, source), isFalse);
    annotatedImage.dispose();

    final bakedBytes = annotated;
    document.undo();
    expect(
      document.annotations.where((item) => item.kind == AnnotationKind.mask),
      isEmpty,
    );
    final bakedImage = await _decode(bakedBytes);
    expect(_nearColor(await _pixel(bakedImage, 6, 6), _black), isTrue);
    bakedImage.dispose();

    final afterUndo = await document.renderPng();
    final afterUndoImage = await _decode(afterUndo);
    expect(_nearColor(await _pixel(afterUndoImage, 6, 6), _blue), isTrue);
    afterUndoImage.dispose();

    document.redo();
    final afterRedo = await document.renderPng();
    final afterRedoImage = await _decode(afterRedo);
    expect(_nearColor(await _pixel(afterRedoImage, 6, 6), _black), isTrue);
    afterRedoImage.dispose();

    final next = await _solidPng(2, 2, _red);
    document.loadCapture(await decodePng(next));
    expect(document.annotations, isEmpty);
    expect(document.canUndo, isFalse);
    expect(document.canRedo, isFalse);
  });

  testWidgets('双击复制合成 bytes 并关闭；关闭不复制；保存失败保留图片', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final bytes = await tester.runAsync(_pngCheckerboard);
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/screenshot');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    Object? copiedBytes;
    String? saveError;

    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case MethodNames.getScreenshot:
          return {
            'id': 'shot',
            ...capture!,
            'capturedAt': 1788662400000,
            'width': 8,
            'height': 8,
            'directory': '/tmp/screenshots',
          };
        case MethodNames.copyScreenshot:
          final args = call.arguments as Map;
          copiedBytes = args['bytes'];
          return null;
        case MethodNames.saveScreenshot:
          if (saveError != null) {
            throw PlatformException(code: 'save_failed', message: saveError);
          }
          final args = call.arguments as Map;
          expect(args['bytes'], isA<Uint8List>());
          return '/tmp/截图.png';
        case MethodNames.pinScreenshot:
          return 'pin-1';
        case MethodNames.closeScreenshot:
          return null;
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    await showFullToolbar(tester);
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);
    expect(find.text('/tmp/screenshots'), findsNothing);
    expect(find.text('固定目录…'), findsNothing);

    calls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      calls.where((call) => call.method == MethodNames.closeScreenshot),
      isNotEmpty,
    );
    expect(
      calls.where((call) => call.method == MethodNames.copyScreenshot),
      isEmpty,
    );
    expect(copiedBytes, isNull);

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    saveError = '目录不可写';
    await _tapExport(tester, const Key('screenshot-save'));
    expect(find.text('目录不可写'), findsOneWidget);
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);

    saveError = null;
    await tester.tap(find.byKey(const Key('screenshot-tool-rect')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('screenshot-shape-filledRectangle')));
    await tester.pumpAndSettle();
    final canvas = find.byKey(const Key('screenshot-canvas'));
    await tester.drag(canvas, const Offset(220, 220));
    await tester.pumpAndSettle();
    calls.clear();
    copiedBytes = null;
    await _tapExport(tester, const Key('screenshot-copy'));
    expect(find.text('已复制图片'), findsOneWidget);
    expect(copiedBytes, isA<Uint8List>());
    final copyArgs =
        calls
                .firstWhere((call) => call.method == MethodNames.copyScreenshot)
                .arguments
            as Map;
    expect(copyArgs['id'], 'shot');
    expect(copyArgs['bytes'], same(copiedBytes));
    expect(listEquals(copiedBytes! as Uint8List, bytes!), isFalse);

    calls.clear();
    await tester.runAsync(() async {
      await tester.tap(canvas);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.tap(canvas);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(
      calls.where((call) => call.method == MethodNames.copyScreenshot),
      isNotEmpty,
    );
    expect(
      calls.where((call) => call.method == MethodNames.closeScreenshot),
      isNotEmpty,
    );
    expect(find.text('已复制图片'), findsOneWidget);
  });

  testWidgets('源图像素建图失败时显示不自动消失的错误，不停在空白等待', (tester) async {
    const channel = MethodChannel('test/screenshot-bad-pixels');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'shot-bad',
          'pixels': Uint8List(16),
          'rowBytes': 32,
          'width': 8,
          'height': 8,
          'capturedAt': 1788662400000,
          'directory': '/tmp/screenshots',
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    expect(tester.takeException(), isNotNull);
    expect(find.text('无法载入这张图片（8 × 8 像素）。'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('无法载入这张图片（8 × 8 像素）。'), findsOneWidget);
  });

  testWidgets('无屏幕录制权限时不进入编辑画布', (tester) async {
    const channel = MethodChannel('test/screenshot-denied');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var requested = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'screenAccess': false,
          'error': '截图需要屏幕录制权限。请在设置中允许 TranSnap。',
        };
      }
      if (call.method == MethodNames.requestScreenAccess) {
        requested = true;
        return {'screenAccess': false};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-canvas')), findsNothing);
    expect(find.text('申请屏幕录制权限'), findsOneWidget);
    await tester.tap(find.text('申请屏幕录制权限'));
    await tester.pumpAndSettle();
    expect(requested, isTrue);
    expect(find.byKey(const Key('screenshot-canvas')), findsNothing);
  });

  testWidgets('无屏幕权限的导入图片保留选区、像素与OCR翻译，屏幕采集入口禁用', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_pngCheckerboard);
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/screenshot-imported-image');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Uint8List? recognizedPixels;
    String? clipboard;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.getScreenshot:
          return {
            'id': 'imported-image',
            ...capture!,
            'capturedAt': 1788662400000,
            'imageScale': 1.0,
            'screenAccess': false,
            'canCaptureMedia': false,
            'directory': '',
          };
        case MethodNames.recognizeText:
          recognizedPixels = (call.arguments as Map)['bytes'] as Uint8List;
          return {'text': 'Imported text', 'codes': <Object>[]};
        case MethodNames.copyText:
          clipboard = (call.arguments as Map)['text'] as String;
          return null;
        case MethodNames.recognizeBlocks:
          return [
            {'text': 'Imported text', 'x': 0, 'y': 0, 'width': 8, 'height': 4},
          ];
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);
    expect(find.byKey(const Key('result-window-canvas')), findsOneWidget);
    expect(find.byKey(const Key('result-window-bar')), findsOneWidget);
    expect(find.byKey(const Key('screenshot-toolbar')), findsNothing);
    expect(find.byKey(const Key('crop-size-label')), findsNothing);
    expect(find.text('申请屏幕录制权限'), findsNothing);
    expect(find.textContaining('截图需要屏幕录制权限'), findsNothing);
    for (final action in [
      ScreenshotActions.record,
      ScreenshotActions.scrolling,
      ScreenshotActions.live,
      ScreenshotActions.cursor,
    ]) {
      expect(find.byKey(Key(action)), findsNothing);
    }
    for (final key in [
      const Key(ScreenshotActions.rect),
      const Key(ScreenshotActions.arrow),
      const Key(ScreenshotActions.text),
      const Key(ScreenshotActions.brush),
      const Key('${ScreenshotActions.brushPrefix}mosaic-tool'),
      const Key('screenshot-undo'),
      const Key('screenshot-redo'),
      const Key(ScreenshotActions.ocrCopy),
      const Key(ScreenshotActions.ocrTranslate),
      const Key(ScreenshotActions.pin),
      const Key(ScreenshotActions.copy),
      const Key(ScreenshotActions.save),
    ]) {
      expect(find.byKey(key), findsOneWidget);
    }
    expect(find.byKey(const Key('opened-image-upward-tray')), findsNothing);
    await tester.tap(find.byKey(const Key(ScreenshotActions.rect)));
    await tester.pumpAndSettle();
    final upwardTray = find.byKey(const Key('opened-image-upward-tray'));
    expect(upwardTray, findsOneWidget);
    expect(
      tester.getRect(upwardTray).bottom,
      lessThan(tester.getRect(find.byKey(const Key('result-window-bar'))).top),
    );

    await _tapExport(tester, const Key(ScreenshotActions.ocrCopy));
    expect(find.text('Imported text'), findsOneWidget);
    await tester.tap(find.byTooltip('复制全部'));
    await tester.pump();
    expect(clipboard, 'Imported text');
    await tester.runAsync(() async {
      final image = await _decode(recognizedPixels!);
      expect(image.width, 8);
      expect(image.height, 8);
      expect(_nearColor(await _pixel(image, 1, 1), _red), isTrue);
      expect(_nearColor(await _pixel(image, 6, 6), _blue), isTrue);
      image.dispose();
    });
    await tester.tap(find.byTooltip('关闭').last);
    await tester.pump();
    await _tapExport(tester, const Key(ScreenshotActions.ocrTranslate));
    await _publishTranslation(tester, channel, {
      'id': 'imported-image',
      'phase': 'running',
      'status': '已完成',
      'overlays': [
        {'text': '导入图片译文', 'x': 0, 'y': 0, 'width': 8, 'height': 4},
      ],
      'metrics': <Object>[],
    });
    expect(find.text('导入图片译文'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);
    expect(find.text('申请屏幕录制权限'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('识别结果渲染 Markdown，复制全部保存原文且弹窗保留到手动关闭', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_pngCheckerboard);
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/screenshot-ocr');
    const markdown = '# Hello\n\n| World |\n| --- |';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? clipboard;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'shot-ocr',
          ...capture!,
          'capturedAt': 1788662400000,
          'width': 8,
          'height': 8,
          'directory': '',
        };
      }
      if (call.method == MethodNames.recognizeText) {
        return {'text': markdown, 'codes': <Object>[]};
      }
      if (call.method == MethodNames.copyText) {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pump();
    await _tapExport(tester, const Key('screenshot-ocr-copy'));
    expect(clipboard, isNull);
    expect(find.text('已复制文字'), findsNothing);
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('World'), findsOneWidget);
    expect(find.textContaining('# '), findsNothing);
    await tester.tap(find.byTooltip('复制全部'));
    await tester.pump();
    expect(clipboard, markdown);
    expect(find.text('已复制文字'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Hello'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭').last);
    await tester.pump();
    expect(find.text('Hello'), findsNothing);
  });

  testWidgets('等待中的功能按钮自身显示进度环；按钮隐藏时在工具栏末尾显示进度环格（#142）', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final png = await tester.runAsync(_pngCheckerboard);
    final capture = await tester.runAsync(() => capturePixels(png!));
    const channel = MethodChannel('test/screenshot-busy');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var pending = Completer<Object?>();
    var hidden = <String>{};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'shot-busy',
          ...capture!,
          'width': 8,
          'height': 8,
          ...(() {
            final base = ScreenshotToolbarPreferences();
            return base.copyWith(
              hidden: hidden,
              favorites: [
                ScreenshotActions.crop,
                ScreenshotActions.record,
                ScreenshotActions.ocrTranslate,
                ScreenshotActions.pin,
              ],
              columns: [
                base.columns[0],
                base.columns[1].withSlot(5, ScreenshotActions.ocrCopy),
              ],
            );
          })().toMap(),
        };
      }
      if (call.method == MethodNames.recognizeText) return pending.future;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pump();
    await showFullToolbar(tester);
    BusyRing ring() => tester.widget<BusyRing>(
      find
          .ancestor(
            of: find.byKey(const Key(ScreenshotActions.ocrCopy)),
            matching: find.byType(BusyRing),
          )
          .first,
    );
    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    await tester.ensureVisible(find.byKey(const Key(ScreenshotActions.ocrCopy)));
    await tester.tap(find.byKey(const Key(ScreenshotActions.ocrCopy)));
    await settle();
    expect(ring().active, isTrue);
    expect(find.byKey(const Key('screenshot-busy')), findsNothing);
    pending.complete({'text': '', 'codes': <Object>[]});
    await settle();
    expect(ring().active, isFalse);

    hidden = {ScreenshotActions.ocrCopy};
    pending = Completer<Object?>();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pump();
    await showFullToolbar(tester);
    expect(find.byKey(const Key(ScreenshotActions.ocrCopy)), findsNothing);
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall(MethodNames.screenshotToolbarSlot, {
          'id': 'shot-busy',
          'modifiers': ToolbarModifiers.option,
          'digit': 6,
        }),
      ),
      (_) {},
    );
    await settle();
    expect(find.byKey(const Key('screenshot-busy')), findsOneWidget);
    pending.complete({'text': '', 'codes': <Object>[]});
    await settle();
    expect(find.byKey(const Key('screenshot-busy')), findsNothing);
  });

  test('只有带主机名的 http/https 内容可作为链接打开', () {
    expect(isOpenableLink('https://example.com/a?b=1'), isTrue);
    expect(isOpenableLink('HTTP://EXAMPLE.COM'), isTrue);
    for (final payload in [
      'https://',
      'example.com',
      'file:///etc/hosts',
      'javascript:alert(1)',
      'tel:10086',
      '4006381333931',
    ]) {
      expect(isOpenableLink(payload), isFalse, reason: payload);
    }
  });

  testWidgets('识别结果列出二维码与条码：逐条复制，只有 http/https 可打开并关闭截图', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_pngCheckerboard);
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/screenshot-codes');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    var codes = <Object>[
      {'symbology': 'qr', 'payload': 'https://example.com/a'},
      {'symbology': 'qr', 'payload': 'javascript:alert(1)'},
      {'symbology': 'ean13', 'payload': '4006381333931'},
    ];
    var opened = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case MethodNames.getScreenshot:
          return {
            'id': 'shot-codes',
            ...capture!,
            'capturedAt': 0,
            'width': 8,
            'height': 8,
          };
        case MethodNames.recognizeText:
          return {'text': '', 'codes': codes};
        case MethodNames.openLink:
          return opened;
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pump();
    await _tapExport(tester, const Key('screenshot-ocr-copy'));
    expect(find.text('识别结果'), findsOneWidget);
    expect(find.text('二维码'), findsNWidgets(2));
    expect(find.text('条码 · EAN13'), findsOneWidget);
    expect(find.text('https://example.com/a'), findsOneWidget);
    expect(find.byTooltip('复制全部'), findsNothing);
    expect(find.byTooltip('打开链接'), findsOneWidget);

    await tester.tap(find.byTooltip('复制内容').last);
    await tester.pump();
    expect(
      calls.where((c) => c.method == MethodNames.copyText).single.arguments,
      {'text': '4006381333931'},
    );
    expect(find.text('已复制内容'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));

    await tester.tap(find.byTooltip('打开链接'));
    await tester.pumpAndSettle();
    expect(
      calls.where((c) => c.method == MethodNames.openLink).single.arguments,
      {'id': 'shot-codes', 'url': 'https://example.com/a'},
    );
    expect(find.text('无法打开链接'), findsOneWidget);
    expect(
      calls.where((c) => c.method == MethodNames.closeScreenshot),
      isEmpty,
    );

    opened = true;
    await tester.tap(find.byTooltip('打开链接'));
    await tester.pumpAndSettle();
    expect(
      calls.where((c) => c.method == MethodNames.closeScreenshot),
      isNotEmpty,
    );

    codes = [];
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pump();
    await _tapExport(tester, const Key('screenshot-ocr-copy'));
    expect(find.text('画面中没有可识别的文字、二维码或条码'), findsOneWidget);
    expect(find.text('识别结果'), findsNothing);
  });

  testWidgets('截图翻译把段落块交主引擎，并按快照逐段覆盖译文（#138）', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_pngCheckerboard);
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/screenshot-ocr-overlay');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const blocks = [
      {'text': 'Hello', 'x': 0, 'y': 0, 'width': 8, 'height': 4},
      {'text': 'World', 'x': 0, 'y': 4, 'width': 8, 'height': 4},
    ];
    Map<Object?, Object?>? sent;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.getScreenshot:
          return {
            'id': 'shot-ocr-overlay',
            ...capture!,
            'capturedAt': 1788662400000,
            'width': 8,
            'height': 8,
            'directory': '',
          };
        case MethodNames.recognizeBlocks:
          return blocks;
        case MethodNames.translateScreenshotBlocks:
          sent = call.arguments as Map<Object?, Object?>;
          return null;
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pump();
    await _tapExport(tester, const Key('screenshot-ocr-translate'));
    expect(sent, {'id': 'shot-ocr-overlay', 'blocks': blocks});

    await _publishTranslation(tester, channel, {
      'id': 'shot-ocr-overlay',
      'phase': 'running',
      'status': '正在翻译',
      'overlays': [
        {'text': '你好', 'x': 0, 'y': 0, 'width': 8, 'height': 4},
      ],
      'metrics': <Object>[],
    });
    expect(find.text('你好'), findsOneWidget);
    expect(find.text('世界'), findsNothing);
    expect(find.text('正在翻译'), findsOneWidget);

    await _publishTranslation(tester, channel, {
      'id': 'shot-ocr-overlay',
      'phase': 'running',
      'status': '已完成',
      'overlays': [
        {'text': '你好', 'x': 0, 'y': 0, 'width': 8, 'height': 4},
        {'text': '世界', 'x': 0, 'y': 4, 'width': 8, 'height': 4},
        {'text': '零宽', 'x': 0, 'y': 4, 'width': 0, 'height': 4},
      ],
      'metrics': <Object>[],
    });
    expect(find.text('你好'), findsOneWidget);
    expect(find.text('世界'), findsOneWidget);
    expect(find.text('零宽'), findsNothing);
    expect(find.text('已完成'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1100));
    expect(find.text('已完成'), findsNothing);
    const reason = 'Apple 系统翻译不支持「ro → 简体中文」。';
    await _publishTranslation(tester, channel, {
      'id': 'shot-ocr-overlay',
      'phase': 'running',
      'status': reason,
      'failed': true,
      'overlays': <Object>[],
      'metrics': <Object>[],
    });
    await tester.pump(const Duration(seconds: 3));
    expect(find.text(reason), findsOneWidget);
  });

  test('译文浮层字号取能放进矩形的最大值，下限为 1（#67 截图译文浮层）', () {
    const style = TextStyle(fontWeight: FontWeight.w600);
    double height(String text, double fontSize, double width) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: style.copyWith(fontSize: fontSize),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      final result = painter.height;
      painter.dispose();
      return result;
    }

    const text = 'Hello world translated paragraph';
    const box = Size(120, 40);
    final fitted = fitOverlayFontSize(text: text, box: box, style: style);
    expect(
      height(text, fitted, box.width),
      lessThanOrEqualTo(box.height + 0.5),
    );
    expect(height(text, fitted + 1, box.width), greaterThan(box.height + 0.5));
    expect(
      fitOverlayFontSize(text: text, box: const Size(120, 1), style: style),
      1,
    );
    final single = fitOverlayFontSize(
      text: 'A',
      box: const Size(400, 30),
      style: style,
    );
    expect(single, lessThanOrEqualTo(30));
    expect(height('A', single + 1, 400), greaterThan(30.5));
  });

  testWidgets('截图翻译的迟到识别结果不发起翻译且不在替换后的截图上显示（#115）', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_pngCheckerboard);
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/screenshot-ocr-stale');
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final snapshot = <String, Object?>{
      'id': 'first',
      ...capture!,
      'capturedAt': 1788662400000,
      'width': 8,
      'height': 8,
      'directory': '',
    };
    final requested = Completer<void>();
    final reply = Completer<List<Object?>>();
    Object? translatedBlocks;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.getScreenshot:
          return snapshot;
        case MethodNames.recognizeBlocks:
          requested.complete();
          return reply.future;
        case MethodNames.translateScreenshotBlocks:
          translatedBlocks = (call.arguments as Map)['blocks'];
          return null;
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const Key('screenshot-ocr-translate')),
    );
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('screenshot-ocr-translate')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    for (var i = 0; i < 50 && !requested.isCompleted; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    await tester.runAsync(
      () => requested.future.timeout(const Duration(seconds: 1)),
    );
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
    reply.complete([
      {'text': 'Hello', 'x': 0, 'y': 0, 'width': 4, 'height': 2},
    ]);
    await tester.pumpAndSettle();
    expect(translatedBlocks, isNull);
    expect(find.byKey(const Key('screenshot-canvas')), findsOneWidget);
    await _publishTranslation(tester, channel, {
      'id': 'first',
      'phase': 'running',
      'status': '已完成',
      'overlays': [
        {'text': '你好', 'x': 0, 'y': 0, 'width': 8, 'height': 4},
      ],
      'metrics': <Object>[],
    });
    expect(find.text('你好'), findsNothing);
    expect(find.text('已完成'), findsNothing);
  });

  testWidgets('Esc 关闭会话不复制；文字输入按 Esc 写入标注', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_pngCheckerboard);
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/screenshot-esc-text');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'shot-esc',
          ...capture!,
          'capturedAt': 1788662400000,
          'width': 8,
          'height': 8,
          'directory': '',
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      calls.where((call) => call.method == MethodNames.closeScreenshot),
      isNotEmpty,
    );
    expect(
      calls.where((call) => call.method == MethodNames.copyScreenshot),
      isEmpty,
    );
  });

  test('文字工具输入后出现在导出文档；画笔不是矩形', () async {
    final source = await _pngCheckerboard();
    final document = EditDocument();
    document.loadCapture(await decodePng(source));
    document.setCrop(const Rect.fromLTWH(0, 0, 6, 6));
    document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.text,
        bounds: Rect.fromLTWH(0, 0, 8, 8),
        text: 'HelloEdit',
        color: Color(0xFFFFFFFF),
        fontSize: 6,
      ),
    );
    expect(document.annotations.single.text, 'HelloEdit');
    expect(document.cropRect, const Rect.fromLTWH(0, 0, 6, 6));
    document.undo();
    expect(document.annotations, isEmpty);
    expect(document.cropRect, const Rect.fromLTWH(0, 0, 6, 6));

    document.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.stroke,
        bounds: Rect.fromLTWH(0, 0, 5, 5),
        points: [Offset(0, 0), Offset(1, 2), Offset(4, 1), Offset(5, 5)],
        color: Color(0xFF00FF00),
        strokeWidth: 1,
      ),
    );
    expect(document.annotations.single.kind, AnnotationKind.stroke);
    expect(document.annotations.single.points.length, 4);
    final stroked = await document.renderPng();
    final image = await _decode(stroked);
    expect(image.width, 6);
    expect(image.height, 6);
    expect(_nearColor(await _pixel(image, 5, 0), _blue), isTrue);
    expect(
      _nearColor(await _pixel(image, 5, 0), const Color(0xFF00FF00)),
      isFalse,
    );
    image.dispose();
  });

  testWidgets('文字工具输入后按 Esc 保留文字并导出；空文字框按 Esc 不留标注', (tester) async {
    tester.view.physicalSize = const Size(640, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(() => _solidPng(64, 64, _blue));
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/screenshot-type-path');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    Uint8List? copied;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case MethodNames.getScreenshot:
          return {
            'id': 'shot-type-path',
            ...capture!,
            'capturedAt': 1788662400000,
            'width': 64,
            'height': 64,
            'directory': '',
          };
        case MethodNames.copyScreenshot:
          copied = (call.arguments as Map)['bytes'] as Uint8List;
          return null;
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await showFullToolbar(tester);
    await tester.ensureVisible(find.byKey(const Key('screenshot-tool-text')));
    await tester.tap(find.byKey(const Key('screenshot-tool-text')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('screenshot-canvas')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('screenshot-text-field')), findsOneWidget);

    calls.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('screenshot-text-field')), findsNothing);
    expect(
      calls.where((c) => c.method == MethodNames.closeScreenshot),
      isEmpty,
    );

    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('screenshot-canvas')));
    await tester.pump();
    expect(find.byKey(const Key('screenshot-text-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('screenshot-text-field')),
      'HelloEdit',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('screenshot-text-field')), findsNothing);

    await tester.ensureVisible(find.byKey(const Key('screenshot-copy')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('screenshot-copy')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(copied, isNotNull);
    expect(listEquals(copied!, bytes!), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('贴纸：美化的子级打开贴纸面板，选中后放在选区中央并导出，原生转发 Delete 删除（#103）', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('stickers-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final bytes = await tester.runAsync(() async {
      File('${directory.path}/red.png')
          .writeAsBytesSync(await _solidPng(10, 10, const Color(0xFFFF0000)));
      return _solidPng(64, 64, _blue);
    });
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/screenshot-sticker');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Uint8List? copied;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.getScreenshot:
          return {
            'id': 'shot-sticker',
            ...capture!,
            'capturedAt': 0,
            'width': 64,
            'height': 64,
            PreferenceKeys.stickers: [
              {'id': 'red', 'width': 20.0, 'height': 20.0},
            ],
            PreferenceKeys.stickerDirectory: directory.path,
          };
        case MethodNames.copyScreenshot:
          copied = (call.arguments as Map)['bytes'] as Uint8List;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await showFullToolbar(tester);
    await tester.ensureVisible(find.byKey(const Key('screenshot-beautify')));
    await tester.tap(find.byKey(const Key('screenshot-beautify')));
    await tester.pump();
    await tester.tap(find.byKey(const Key(ScreenshotActions.sticker)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('贴纸').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sticker-cell-red')));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }

    Future<(int, int, int)> exportedCenter() async {
      await tester.ensureVisible(find.byKey(const Key('screenshot-copy')));
      return (await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('screenshot-copy')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final codec = await ui.instantiateImageCodec(copied!);
        final image = (await codec.getNextFrame()).image;
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final offset = (32 * image.width + 32) * 4;
        return (
          data.getUint8(offset),
          data.getUint8(offset + 1),
          data.getUint8(offset + 2),
        );
      }))!;
    }

    expect(await exportedCenter(), (255, 0, 0));
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall(MethodNames.deleteScreenshotSelection, {
          'id': 'shot-sticker',
        }),
      ),
      (_) {},
    );
    await tester.pump();
    expect(await exportedCenter(), (0, 0, 255));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('贴纸下拉框：默认 Emoji 段，点表情放置 Emoji 贴纸并收起（#103）', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(() => _solidPng(64, 64, _blue));
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/screenshot-emoji');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.getScreenshot:
          return {
            'id': 'shot-emoji',
            ...capture!,
            'capturedAt': 0,
            'width': 64,
            'height': 64,
            PreferenceKeys.stickers: const <Object?>[],
            PreferenceKeys.stickerDirectory: '/unused',
          };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await showFullToolbar(tester);
    await tester.ensureVisible(find.byKey(const Key('screenshot-beautify')));
    await tester.tap(find.byKey(const Key('screenshot-beautify')));
    await tester.pump();
    await tester.tap(find.byKey(const Key(ScreenshotActions.sticker)));
    await tester.pumpAndSettle();
    final firstEmoji = ValueKey(
      'emoji-cell-${EmojiCatalog.groups.first.emoji.first}',
    );
    expect(find.byType(StickerPanel), findsOneWidget);
    await tester.tap(find.byKey(firstEmoji));
    await tester.pumpAndSettle();
    expect(find.byType(StickerPanel), findsNothing);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('贴纸下拉框：两段都有「管理贴纸…」且高度不变，点击收起并发出 openStickerSettings（#103）', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(() => _solidPng(64, 64, _blue));
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/screenshot-sticker-manage');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'shot-manage',
          ...capture!,
          'capturedAt': 0,
          'width': 64,
          'height': 64,
          PreferenceKeys.stickers: const <Object?>[],
          PreferenceKeys.stickerDirectory: '/unused',
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await showFullToolbar(tester);
    await tester.ensureVisible(find.byKey(const Key('screenshot-beautify')));
    await tester.tap(find.byKey(const Key('screenshot-beautify')));
    await tester.pump();
    await tester.tap(find.byKey(const Key(ScreenshotActions.sticker)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sticker-manage')), findsOneWidget);
    final emojiHeight = tester.getSize(find.byType(StickerPanel)).height;
    await tester.tap(find.text('贴纸').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sticker-manage')), findsOneWidget);
    expect(tester.getSize(find.byType(StickerPanel)).height, emojiHeight);
    expect(find.text('还没有贴纸'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sticker-manage')));
    await tester.pumpAndSettle();
    expect(find.byType(StickerPanel), findsNothing);
    expect(methods, contains(MethodNames.openStickerSettings));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('美化行：未开启美化时下拉禁用，应用背景后可用，「无背景」关闭美化（#103）', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(() => _solidPng(64, 64, _blue));
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/screenshot-beautify-none');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == MethodNames.getScreenshot
          ? {
              'id': 'shot-none',
              ...capture!,
              'capturedAt': 0,
              'width': 64,
              'height': 64,
            }
          : null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await showFullToolbar(tester);
    await tester.ensureVisible(find.byKey(const Key('screenshot-beautify')));
    await tester.tap(find.byKey(const Key('screenshot-beautify')));
    await tester.pump();

    bool paddingEnabled() =>
        tester
            .widget<NativeGlassMenuButton<double>>(
              find.byType(NativeGlassMenuButton<double>).first,
            )
            .onChanged !=
        null;
    expect(paddingEnabled(), isFalse);
    await tester.tap(find.byTooltip('背景'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('apply-color')));
    await tester.pumpAndSettle();
    expect(paddingEnabled(), isTrue);
    await tester.tap(find.byTooltip('背景'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('beautify-none')));
    await tester.pumpAndSettle();
    expect(paddingEnabled(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('美化行选择背景后复制输出扩出内边距的图片，贴图仍是原图，切换工具收起美化行', (tester) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(() => _solidPng(64, 64, _blue));
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/screenshot-beautify');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Uint8List? copied;
    Uint8List? pinned;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.getScreenshot:
          return {
            'id': 'shot-beautify',
            ...capture!,
            'capturedAt': 1788662400000,
            'width': 64,
            'height': 64,
            'directory': '',
            'displayX': 0,
            'displayY': 0,
            'displayWidth': 900,
            'displayHeight': 900,
          };
        case MethodNames.copyScreenshot:
          copied = (call.arguments as Map)['bytes'] as Uint8List;
          return null;
        case MethodNames.pinScreenshot:
          pinned = (call.arguments as Map)['bytes'] as Uint8List;
          return 'pin-beautify';
        default:
          return null;
      }
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await showFullToolbar(tester);
    await tester.ensureVisible(find.byKey(const Key('screenshot-beautify')));
    await tester.tap(find.byKey(const Key('screenshot-beautify')));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byKey(const Key('screenshot-beautify-row')),
        matching: find.byTooltip('背景'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('screenshot-children-group-0')),
        matching: find.byKey(const Key(ScreenshotActions.sticker)),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('背景'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('gradient-preset-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('apply-color')));
    await tester.pumpAndSettle();

    Future<void> press(String key) async {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.runAsync(() async {
        await tester.tap(find.byKey(Key(key)));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
    }

    await press('screenshot-copy');
    final image = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(copied!);
      return (await codec.getNextFrame()).image;
    });
    expect((image!.width, image.height), (192, 192));
    image.dispose();

    await tester.ensureVisible(find.byKey(const Key('screenshot-tool-rect')));
    await tester.tap(find.byKey(const Key('screenshot-tool-rect')));
    await tester.pump();
    expect(find.byTooltip('背景'), findsNothing);
    await press('screenshot-pin');
    expect(pinned, isNotNull);
    final pin = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(pinned!);
      return (await codec.getNextFrame()).image;
    });
    expect((pin!.width, pin.height), (64, 64));
    pin.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('画笔拖拽导出不是填充矩形；⌘Z 撤销同一份历史', (tester) async {
    tester.view.physicalSize = const Size(640, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(() => _solidPng(64, 64, _blue));
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/screenshot-brush-path');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Uint8List? copied;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'shot-brush-path',
          ...capture!,
          'capturedAt': 1788662400000,
          'width': 64,
          'height': 64,
          'directory': '',
        };
      }
      if (call.method == MethodNames.copyScreenshot) {
        copied = (call.arguments as Map)['bytes'] as Uint8List;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await showFullToolbar(tester);
    await tester.tap(find.byKey(const Key('screenshot-tool-brush')));
    await tester.pump();
    await tester.drag(
      find.byKey(const Key('screenshot-canvas')),
      const Offset(120, 16),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('screenshot-copy')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(copied, isNotNull);
    final image = await tester.runAsync(() => _decode(copied!));
    final width = image!.width;
    final height = image.height;
    final data = await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    image.dispose();
    final pixels = data!.buffer.asUint8List();
    var changed = 0;
    final total = width * height;
    for (var i = 0; i < pixels.length; i += 4) {
      if (pixels[i] != 0 || pixels[i + 1] != 0 || pixels[i + 2] != 0xFF) {
        changed++;
      }
    }
    expect(changed, greaterThan(0));
    expect(changed, lessThan(total ~/ 2));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    copied = null;
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('screenshot-copy')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    final undone = await tester.runAsync(() => _decode(copied!));
    final undoneData = await tester.runAsync(
      () => undone!.toByteData(format: ui.ImageByteFormat.rawRgba),
    );
    undone!.dispose();
    final restored = undoneData!.buffer.asUint8List();
    for (var i = 0; i < restored.length; i += 4) {
      expect(restored.sublist(i, i + 3), [0, 0, 0xFF]);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('快照带窗口裁剪时导出尺寸等于该矩形', (tester) async {
    tester.view.physicalSize = const Size(960, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(_pngCheckerboard);
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/screenshot-window-crop');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Uint8List? copied;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'shot-window-crop',
          ...capture!,
          'capturedAt': 1788662400000,
          'width': 8,
          'height': 8,
          'cropX': 0,
          'cropY': 0,
          'cropWidth': 4,
          'cropHeight': 4,
          'directory': '',
        };
      }
      if (call.method == MethodNames.copyScreenshot) {
        copied = (call.arguments as Map)['bytes'] as Uint8List;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    await showFullToolbar(tester);
    await _tapExport(tester, const Key('screenshot-copy'));
    expect(copied, isNotNull);
    final image = await tester.runAsync(() => _decode(copied!));
    expect(image!.width, 4);
    expect(image.height, 4);
    image.dispose();
  });

  testWidgets('文字工具有颜色字号；结束输入后单击选中、再次点击进入编辑', (tester) async {
    tester.view.physicalSize = const Size(640, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(() => _solidPng(64, 64, _blue));
    final capture = await tester.runAsync(() => capturePixels(bytes!));
    const channel = MethodChannel('test/screenshot-text-reedit');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'shot-text-reedit',
          ...capture!,
          'capturedAt': 1788662400000,
          'width': 64,
          'height': 64,
          'directory': '',
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    await awaitCaptureSource(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await showFullToolbar(tester);
    await tester.ensureVisible(find.byKey(const Key('screenshot-tool-text')));
    expect(find.byKey(const Key('screenshot-tool-cursor')), findsNothing);
    await tester.tap(find.byKey(const Key('screenshot-tool-text')));
    await tester.pump();
    expect(find.byKey(const Key('screenshot-text-size-up')), findsOneWidget);
    await tester.tap(find.byKey(const Key('screenshot-canvas')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('screenshot-text-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('screenshot-text-field')),
      'Hello',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('screenshot-text-field')), findsNothing);

    final canvasBox = tester.getRect(
      find.byKey(const Key('screenshot-canvas')),
    );
    await tester.tapAt(canvasBox.center + const Offset(120, 120));
    await tester.pump();
    expect(find.byKey(const Key('screenshot-text-field')), findsNothing);
    await tester.tapAt(canvasBox.center + const Offset(120, 120));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('screenshot-text-field')), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('screenshot-text-field')),
      'World',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
  });
}

Future<void> _publishTranslation(
  WidgetTester tester,
  MethodChannel channel,
  Map<String, Object?> state,
) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(MethodNames.publishScreenshotTranslation, state),
        ),
        (_) {},
      );
  await tester.pump();
}

Future<void> _tapExport(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.runAsync(() async {
    await tester.tap(find.byKey(key));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  await tester.pumpAndSettle();
}

const _red = Color(0xFFFF0000);
const _blue = Color(0xFF0000FF);
const _black = Color(0xFF000000);

Future<Uint8List> _pngCheckerboard() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 8, 8), Paint()..color = _blue);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 4, 4), Paint()..color = _red);
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 8);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

Future<Uint8List> _solidPng(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = color,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

Future<Color> _pixel(ui.Image image, int x, int y) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final offset = (y * image.width + x) * 4;
  final bytes = data!.buffer.asUint8List();
  return Color.fromARGB(
    bytes[offset + 3],
    bytes[offset],
    bytes[offset + 1],
    bytes[offset + 2],
  );
}

bool listEquals(Uint8List a, Uint8List b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _nearColor(Color a, Color b) {
  return (a.r - b.r).abs() < 0.08 &&
      (a.g - b.g).abs() < 0.08 &&
      (a.b - b.b).abs() < 0.08 &&
      (a.a - b.a).abs() < 0.08;
}
