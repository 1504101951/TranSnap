import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/widgets/app_motion.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/history/history_empty_state.dart';
import 'package:translate_app/src/history/screenshot_compose_dialogs.dart';
import 'package:translate_app/src/history/screenshot_history.dart';
import 'package:translate_app/src/history/screenshot_history_page.dart';

/// 无参数；用假历史通道验证截图历史分段的缺失文件、删除确认、清空确认与合成边界（#29）。
void main() {
  testWidgets('图片缺失的条目只能删除；删除与清空需确认，关闭记录后提示开启方式', (tester) async {
    // 边界：文件缺失只保留删除；取消删除或清空不修改数据；列表为空时清空按钮禁用。
    final directory = Directory.systemTemp.createTempSync('screenshot-page-');
    addTearDown(() => directory.deleteSync(recursive: true));
    // 1×1 透明 PNG，让存在的条目能正常解码缩略图。
    final existing = File('${directory.path}/a.png')
      ..writeAsBytesSync(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
        ),
      );
    const channel = MethodChannel('test/screenshot-history-page');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // 假主引擎：一条存在、一条缺失的截图历史，删除、清空与开关直接改写这份状态。
    final rows = <Map<String, Object>>[
      {
        'id': 1,
        'path': existing.path,
        'width': 1,
        'height': 1,
        'capturedAt': 2,
        'exists': true,
      },
      {
        'id': 2,
        'path': '${directory.path}/missing.png',
        'width': 800,
        'height': 600,
        'capturedAt': 1,
        'exists': false,
      },
    ];
    var recording = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final arguments = call.arguments as Map?;
      switch (call.method) {
        case MethodNames.screenshotHistoryList:
          return rows;
        case MethodNames.screenshotHistoryRecording:
          return recording;
        case MethodNames.setScreenshotHistoryRecording:
          recording = arguments!['enabled'] as bool;
          return null;
        case MethodNames.deleteScreenshotHistory:
          rows.removeWhere((row) => row['id'] == arguments!['id']);
          return null;
        case MethodNames.clearScreenshotHistory:
          rows.clear();
          return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: ScreenshotHistoryPage(channel: channel, version: 0),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('800 × 600'), findsOneWidget);
    expect(find.text('图片文件已缺失'), findsOneWidget);
    expect(find.byTooltip('打开'), findsOneWidget);
    expect(find.byTooltip('复制图片'), findsOneWidget);
    expect(find.byTooltip('删除截图'), findsNWidgets(2));

    await tester.tap(find.byTooltip('删除截图').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('图片文件已缺失'), findsOneWidget);

    await tester.tap(find.byTooltip('删除截图').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.text('图片文件已缺失'), findsNothing);
    expect(find.text('1 × 1'), findsOneWidget);

    await tester.tap(find.text('清空截图历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('1 × 1'), findsOneWidget);

    await tester.tap(find.text('清空截图历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();
    expect(find.byType(HistoryEmptyState), findsOneWidget);
    expect(find.text('还没有截图记录'), findsOneWidget);
    expect(find.byType(NativeGlassKeycaps), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '清空截图历史'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byType(NativeGlassSwitch));
    await tester.pumpAndSettle();
    expect(
      tester.widget<NativeGlassSwitch>(find.byType(NativeGlassSwitch)).value,
      isFalse,
    );
    expect(find.text('还没有截图记录'), findsOneWidget);
  });

  testWidgets('勾选决定拼接、拆分与比较是否可用；结果加入历史后清空勾选，比较显示差异摘要', (tester) async {
    // 边界：缺失图片不可勾选；1 张只能拆分，2 张可拼接与比较，3 张只能拼接；
    // 拼接按截图时间先后传路径；比较差异为 0 与非 0 时摘要不同（#109）。
    // 窗口足够高，五张卡片全部构建，缺失图片的卡片也在可见范围内。
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync(
      'screenshot-compose-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final pixel = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
    );
    Map<String, Object> row(int id, int capturedAt, {bool exists = true}) {
      final path = '${directory.path}/$id.png';
      if (exists) File(path).writeAsBytesSync(pixel);
      return {
        'id': id,
        'path': path,
        'width': 100,
        'height': 100,
        'capturedAt': capturedAt,
        'exists': exists,
      };
    }

    // 假主引擎与原生：列表倒序；加入历史时把每张结果追加为新记录；比较返回给定差异。
    final rows = [row(3, 30), row(2, 20), row(1, 10), row(9, 5, exists: false)];
    List<Object?>? stitched;
    var different = 0;
    const channel = MethodChannel('test/screenshot-compose');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final arguments = call.arguments as Map?;
      switch (call.method) {
        case MethodNames.screenshotHistoryList:
          return rows;
        case MethodNames.screenshotHistoryRecording:
          return false;
        case MethodNames.stitchScreenshots:
          stitched = arguments!['paths'] as List<Object?>;
          return Uint8List.fromList(pixel);
        case MethodNames.addScreenshotHistory:
          for (final _ in arguments!['images'] as List) {
            rows.insert(0, row(100 + rows.length, 99));
          }
          return null;
        case MethodNames.compareScreenshots:
          return {
            'mask': Uint8List.fromList(pixel),
            'different': different,
            'total': 4,
          };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: ScreenshotHistoryPage(channel: channel, version: 0),
        ),
      ),
    );
    await tester.pumpAndSettle();

    /// label 为操作按钮文字；返回该按钮当前是否可用。
    bool enabled(String label) =>
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, label))
            .onPressed !=
        null;
    final boxes = find.byType(Checkbox);
    expect(tester.widget<Checkbox>(boxes.last).onChanged, isNull);
    expect(find.text('已选 0 张'), findsOneWidget);
    expect(
      [enabled('拼接'), enabled('拆分'), enabled('比较')],
      [false, false, false],
    );

    await tester.tap(boxes.at(0));
    await tester.pump();
    expect([enabled('拼接'), enabled('拆分'), enabled('比较')], [false, true, false]);
    await tester.tap(boxes.at(2));
    await tester.pump();
    expect([enabled('拼接'), enabled('拆分'), enabled('比较')], [true, false, true]);
    await tester.tap(boxes.at(1));
    await tester.pump();
    expect(find.text('已选 3 张'), findsOneWidget);
    expect([enabled('拼接'), enabled('拆分'), enabled('比较')], [true, false, false]);

    await tester.tap(find.widgetWithText(TextButton, '拼接'));
    await tester.pumpAndSettle();
    expect(find.text('拼接 3 张截图'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '拼接'));
    await tester.pumpAndSettle();
    expect(stitched, [
      '${directory.path}/1.png',
      '${directory.path}/2.png',
      '${directory.path}/3.png',
    ]);
    expect(find.byType(NativeGlassBanner), findsNothing);
    expect(find.text('已选 0 张'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(5));

    // 新结果排在最前；勾选原来的第 3 张与第 1 张比较。
    for (final index in [1, 3]) {
      await tester.tap(find.byType(Checkbox).at(index));
      await tester.pump();
    }
    await tester.tap(find.widgetWithText(TextButton, '比较'));
    await tester.pumpAndSettle();
    expect(find.text('两张截图像素完全一致'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '完成'));
    await tester.pumpAndSettle();
    different = 1;
    await tester.tap(find.widgetWithText(TextButton, '比较'));
    await tester.pumpAndSettle();
    expect(find.text('差异像素 1 / 总像素 4（25.00%）'), findsOneWidget);
  });

  testWidgets('截图历史拼接、拆分、比较等待期间仅对应按钮显示进度环，完成后收起（#142）', (tester) async {
    // 作用：验证后台合成/逐像素对比挂起时只激活发起操作的按钮进度环，并阻止同时触发其他动作。
    // 边界：勾选 2 张后点「比较」，compareScreenshots 未返回前仅「比较」active=true、「拼接」active=false，返回后全部归 false。
    final directory = Directory.systemTemp.createTempSync(
      'screenshot-compose-busy-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final pixel = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
    );
    final rows = [
      for (final id in [1, 2])
        {
          'id': id,
          'path': '${directory.path}/$id.png',
          'width': 1,
          'height': 1,
          'capturedAt': id * 10,
          'exists': true,
        },
    ];
    for (final row in rows) {
      File(row['path']! as String).writeAsBytesSync(pixel);
    }
    final pendingCompare = Completer<Map<String, Object?>>();
    const channel = MethodChannel('test/screenshot-compose-busy');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.screenshotHistoryList:
          return rows;
        case MethodNames.screenshotHistoryRecording:
          return false;
        case MethodNames.compareScreenshots:
          return pendingCompare.future;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: ScreenshotHistoryPage(channel: channel, version: 0),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final index in [0, 1]) {
      await tester.tap(find.byType(Checkbox).at(index));
      await tester.pump();
    }
    BusyRing ringFor(String label) => tester.widget<BusyRing>(
      find
          .ancestor(
            of: find.widgetWithText(TextButton, label),
            matching: find.byType(BusyRing),
          )
          .first,
    );

    await tester.tap(find.widgetWithText(TextButton, '比较'));
    await tester.pump();
    expect(ringFor('比较').active, isTrue);
    expect(ringFor('拼接').active, isFalse);

    pendingCompare.complete({
      'mask': Uint8List.fromList(pixel),
      'different': 0,
      'total': 1,
    });
    await tester.pumpAndSettle();
    expect(ringFor('比较').active, isFalse);
    expect(find.text('两张截图像素完全一致'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('高度不足 2px 的截图禁用拆分，SplitDialog 展示错误横幅并禁用确认', (tester) async {
    // 作用：验证 1px 高截图在列表选择后「拆分」仍禁用，且直接打开 SplitDialog(height: 1) 不崩溃并禁用确认。
    // 边界：record.height == 1 (< 2) 时，列表页拆分按钮与弹窗内「拆分」FilledButton onPressed 均为 null。
    final directory = Directory.systemTemp.createTempSync(
      'screenshot-split-min-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final pixel = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
    );
    final file = File('${directory.path}/thin.png')..writeAsBytesSync(pixel);
    const channel = MethodChannel('test/screenshot-split-min');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.screenshotHistoryList:
          return [
            {
              'id': 1,
              'path': file.path,
              'width': 100,
              'height': 1,
              'capturedAt': 10,
              'exists': true,
            },
          ];
        case MethodNames.screenshotHistoryRecording:
          return true;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: ScreenshotHistoryPage(channel: channel, version: 0),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '拆分'))
          .onPressed,
      isNull,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: const Scaffold(body: SplitDialog(height: 1)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('截图高度不足 2 像素，无法拆分。'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '拆分'))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('ScreenshotCompareDialog 在 total 为 0 时安全降级并支持双侧缩放浏览', (tester) async {
    // 作用：验证比较弹窗在 total == 0 时避免除零异常，并为较早/较晚截图提供时间标识与 InteractiveViewer。
    // 边界：total = 0 返回「无法统计差异像素」而非 NaN/Infinity。
    final directory = Directory.systemTemp.createTempSync(
      'screenshot-compare-zero-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final pixel = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
    );
    final first = File('${directory.path}/1.png')..writeAsBytesSync(pixel);
    final second = File('${directory.path}/2.png')..writeAsBytesSync(pixel);
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: ScreenshotCompareDialog(
            first: ScreenshotRecord(
              id: 1,
              path: first.path,
              width: 100,
              height: 50,
              capturedAt: 1000,
              exists: true,
            ),
            second: ScreenshotRecord(
              id: 2,
              path: second.path,
              width: 120,
              height: 60,
              capturedAt: 2000,
              exists: true,
            ),
            mask: Uint8List.fromList(pixel),
            different: 0,
            total: 0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('无法统计差异像素'), findsOneWidget);
    expect(find.textContaining('较早 · '), findsOneWidget);
    expect(find.textContaining('较晚 · '), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('截图历史首次加载失败可重试恢复，复制图片仅显示对勾确认不弹非错误横幅', (tester) async {
    // 作用：验证首次读取抛异常时呈现重试页而非永久转圈，恢复并复制图片后仅触发图标确认而不显示成功横幅。
    // 边界：screenshotHistoryList 首次抛 PlatformException 展示「重试加载」，恢复后复制触发 trigger=1 且无 NativeGlassBanner。
    final directory = Directory.systemTemp.createTempSync(
      'screenshot-retry-copy-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final pixel = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
    );
    final file = File('${directory.path}/a.png')..writeAsBytesSync(pixel);
    const channel = MethodChannel('test/screenshot-retry-copy');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var failLoad = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.screenshotHistoryList:
          if (failLoad) {
            throw PlatformException(code: 'io_error', message: '截图历史索引不可读');
          }
          return [
            {
              'id': 1,
              'path': file.path,
              'width': 100,
              'height': 80,
              'capturedAt': 100,
              'exists': true,
            },
          ];
        case MethodNames.screenshotHistoryRecording:
          return true;
        case MethodNames.copyImageFile:
          return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: ScreenshotHistoryPage(channel: channel, version: 0),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('截图历史索引不可读'), findsOneWidget);

    failLoad = false;
    await tester.tap(find.text('重试加载'));
    await tester.pumpAndSettle();
    expect(find.text('100 × 80'), findsOneWidget);

    expect(tester.widget<CopyConfirmIcon>(find.byType(CopyConfirmIcon)).trigger, 0);
    await tester.tap(find.byTooltip('复制图片'));
    await tester.pump();
    expect(find.byType(NativeGlassBanner), findsNothing);
    expect(tester.widget<CopyConfirmIcon>(find.byType(CopyConfirmIcon)).trigger, 1);
    expect(tester.takeException(), isNull);
  });
}
