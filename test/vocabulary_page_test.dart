import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/widgets/app_motion.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/history/history_empty_state.dart';
import 'package:translate_app/src/history/history_list_card.dart';
import 'package:translate_app/src/history/vocabulary_page.dart';

/// tester 为测试驱动；创建并登记一个复用的鼠标指针用于触发悬停状态。
Future<TestGesture> _startMouse(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  return gesture;
}

/// tester 为测试驱动，mouse 为已登记鼠标，finder 为目标条目；移动鼠标到条目中心以显示悬停按钮。
Future<void> _hoverRow(
  WidgetTester tester,
  TestGesture mouse,
  Finder finder,
) async {
  await mouse.moveTo(tester.getCenter(finder));
  await tester.pumpAndSettle();
}

/// 无参数；用假历史通道验证生词本分段的展示、悬停操作、删除确认、失败重试与导出状态。
void main() {
  testWidgets('生词条目共用分组卡片且悬停显示复制删除，删除需确认后消失，导出成功不弹非错误横幅', (tester) async {
    // 作用：验证生词本样式对齐历史列表、悬停按钮显隐、删除确认防误触、CSV 导出静默完成与删空状态。
    // 边界：静息时按钮不可点击（透明度 0）；悬停后出现；取消删除保留原词，删空后显示统一空状态并禁用导出。
    const channel = MethodChannel('test/vocabulary-page');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // 假主引擎：两条生词，删除即从列表移除；保存面板返回用户选择的路径。
    final rows = <Map<String, Object>>[
      {
        'word': 'serendipity',
        'translation': '机缘凑巧',
        'definition': 'noun 机缘凑巧',
        'addedAt': 2,
      },
      {
        'word': 'pear',
        'translation': '梨',
        'definition': 'noun 梨',
        'addedAt': 1,
      },
    ];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.vocabularyList:
          return rows;
        case MethodNames.deleteVocabulary:
          rows.removeWhere(
            (row) => row['word'] == (call.arguments as Map)['word'],
          );
          return null;
        case MethodNames.vocabularyCsv:
          return '"pear","梨","noun 梨"\n';
        case MethodNames.saveTextFile:
          return '/Users/test/TranslateApp 生词本.csv';
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: VocabularyPage(channel: channel, version: 0)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(HistoryGroupCard), findsOneWidget);
    expect(find.text('serendipity'), findsOneWidget);
    expect(find.text('机缘凑巧'), findsOneWidget);
    expect(find.text('noun 梨'), findsOneWidget);
    // 静息状态下悬停操作区透明度为 0 且不逐行挂载 NativeGlassSurface。
    final firstActions = find.descendant(
      of: find.byKey(const ValueKey('vocabulary-serendipity')),
      matching: find.byType(AnimatedOpacity),
    );
    expect(tester.widget<AnimatedOpacity>(firstActions).opacity, 0);
    expect(
      find.descendant(
        of: find.byType(HistoryGroupCard),
        matching: find.byType(NativeGlassSurface),
      ),
      findsNothing,
    );

    final mouse = await _startMouse(tester);
    await _hoverRow(
      tester,
      mouse,
      find.byKey(const ValueKey('vocabulary-serendipity')),
    );
    expect(tester.widget<AnimatedOpacity>(firstActions).opacity, 1);

    await tester.tap(find.byTooltip('删除生词').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('serendipity'), findsOneWidget);

    await tester.tap(find.byTooltip('删除生词').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.text('serendipity'), findsNothing);
    expect(find.text('pear'), findsOneWidget);

    await tester.tap(find.text('导出 CSV'));
    await tester.pumpAndSettle();
    expect(find.byType(NativeGlassBanner), findsNothing);

    // 边界：删到为空后显示统一空状态，导出按钮禁用。
    await _hoverRow(tester, mouse, find.byKey(const ValueKey('vocabulary-pear')));
    await tester.tap(find.byTooltip('删除生词'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.byType(HistoryEmptyState), findsOneWidget);
    expect(find.text('还没有生词'), findsOneWidget);
    expect(find.text('查词后在译文卡片点「加入生词本」'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '导出 CSV'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('生词本导出等待期间按钮显示进度环，完成后收起（#142）', (tester) async {
    // 作用：验证生词本点击「导出 CSV」后在系统保存返回前显示进度环，结束后关闭。
    // 边界：saveTextFile 挂起时 BusyRing.active=true，完成后恢复 false。
    const channel = MethodChannel('test/vocabulary-busy');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final pending = Completer<String?>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.vocabularyList:
          return [
            {
              'word': 'pear',
              'translation': '梨',
              'definition': 'noun 梨',
              'addedAt': 1,
            },
          ];
        case MethodNames.vocabularyCsv:
          return '"pear","梨","noun 梨"\n';
        case MethodNames.saveTextFile:
          return pending.future;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: VocabularyPage(channel: channel, version: 0)),
      ),
    );
    await tester.pumpAndSettle();

    BusyRing ring() => tester.widget<BusyRing>(
      find
          .ancestor(of: find.text('导出 CSV'), matching: find.byType(BusyRing))
          .first,
    );
    expect(ring().active, isFalse);

    await tester.tap(find.text('导出 CSV'));
    await tester.pump();
    expect(ring().active, isTrue);

    pending.complete('/Users/test/pear.csv');
    await tester.pumpAndSettle();
    expect(ring().active, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('生词本首次加载失败展示错误横幅与重试按钮，恢复后正常加载', (tester) async {
    // 作用：验证首次读取抛 PlatformException 时退出转圈并提供「重试加载」入口。
    // 边界：_entries == null 且 _loadError 非空时渲染 NativeGlassBanner 与「重试加载」。
    const channel = MethodChannel('test/vocabulary-load-error');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var failLoad = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.vocabularyList) {
        if (failLoad) {
          throw PlatformException(code: 'db_error', message: '生词库连接失败');
        }
        return [
          {
            'word': 'apple',
            'translation': '苹果',
            'definition': 'noun 苹果',
            'addedAt': 1,
          },
        ];
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: VocabularyPage(channel: channel, version: 0)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(NativeGlassBanner), findsOneWidget);
    expect(find.text('生词库连接失败'), findsOneWidget);

    failLoad = false;
    await tester.tap(find.text('重试加载'));
    await tester.pumpAndSettle();
    expect(find.text('apple'), findsOneWidget);
    expect(find.text('生词库连接失败'), findsNothing);
  });

  testWidgets('生词本结构化释义渲染、快捷复制按钮与删除失败提示正常', (tester) async {
    // 作用：验证词典分节释义渲染、悬停后快捷复制触发图标确认以及删除异常错误横幅反馈。
    // 边界：删除失败保留条目并通过 NativeGlassBanner 展示错误文案。
    const channel = MethodChannel('test/vocabulary-copy-delete-err');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final clipboard = <String>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.vocabularyList:
          return [
            {
              'word': 'pear',
              'translation': '梨',
              'definition': 'pear | pɛr | A. noun ① 梨子 ▸ sweet pear',
              'addedAt': 1,
            },
          ];
        case MethodNames.deleteVocabulary:
          throw PlatformException(code: 'delete_failed', message: '删除失败，磁盘只读');
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: VocabularyPage(channel: channel, version: 0)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('A. noun'), findsOneWidget);
    expect(find.text('① 梨子'), findsOneWidget);
    expect(find.text('sweet pear'), findsOneWidget);

    final mouse = await _startMouse(tester);
    await _hoverRow(tester, mouse, find.byKey(const ValueKey('vocabulary-pear')));
    expect(tester.widget<CopyConfirmIcon>(find.byType(CopyConfirmIcon)).trigger, 0);
    await tester.tap(find.byTooltip('复制生词'));
    await tester.pumpAndSettle();
    expect(clipboard, ['pear\n梨\npear | pɛr | A. noun ① 梨子 ▸ sweet pear']);
    expect(tester.widget<CopyConfirmIcon>(find.byType(CopyConfirmIcon)).trigger, 1);

    await tester.tap(find.byTooltip('删除生词'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除失败，磁盘只读'), findsOneWidget);
    expect(find.text('pear'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
