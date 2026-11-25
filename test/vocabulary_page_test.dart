import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/widgets/app_motion.dart';
import 'package:transnap/src/common/widgets/native_glass.dart';
import 'package:transnap/src/history/history_empty_state.dart';
import 'package:transnap/src/history/history_list_card.dart';
import 'package:transnap/src/history/vocabulary_page.dart';

Future<TestGesture> _startMouse(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  return gesture;
}

Future<void> _hoverRow(
  WidgetTester tester,
  TestGesture mouse,
  Finder finder,
) async {
  await mouse.moveTo(tester.getCenter(finder));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('生词条目共用分组卡片且悬停显示复制删除，删除需确认后消失，导出成功不弹非错误横幅', (tester) async {
    const channel = MethodChannel('test/vocabulary-page');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
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
          return '/Users/test/TranSnap 生词本.csv';
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
