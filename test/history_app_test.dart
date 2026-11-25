import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:transnap/src/common/constants/appearance_modes.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/preference_keys.dart';
import 'package:transnap/src/common/constants/shortcut_keys.dart';
import 'package:transnap/src/common/widgets/app_motion.dart';
import 'package:transnap/src/common/widgets/native_glass.dart';
import 'package:transnap/src/history/history_app.dart';
import 'package:transnap/src/history/history_empty_state.dart';
import 'package:transnap/src/history/history_list_card.dart';
import 'package:transnap/src/history/history_requests.dart';
import 'package:transnap/src/history/translation_history.dart';
import 'package:transnap/src/history/vocabulary_page.dart';
import 'support/line_icons.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:transnap/src/common/constants/glass_metrics.dart';

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
  const channel = MethodChannel('test/history-window');
  late Database database;
  late TranslationHistoryStore store;

  setUp(() {
    database = sqlite3.openInMemory();
    store = TranslationHistoryStore(
      database,
      now: () => DateTime.fromMillisecondsSinceEpoch(0),
      onChanged: () {
        unawaited(
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .handlePlatformMessage(
                channel.name,
                const StandardMethodCodec().encodeMethodCall(
                  const MethodCall(MethodNames.historyChanged),
                ),
                (_) {},
              ),
        );
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          try {
            return handleHistoryRequest(store, call);
          } on SqliteException catch (error) {
            throw PlatformException(
              code: 'history_storage',
              message: error.message,
            );
          }
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    database.close();
  });

  testWidgets('历史随外观切换保持来源和正文可读，标题栏居中分段且收到新增事件自动刷新', (tester) async {
    final completedAt = DateTime(2026, 9, 19, 9, 30).millisecondsSinceEpoch;
    store.insert(
      sourceText: 'old source',
      translatedText: 'old translation',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: completedAt,
      sourceLabel: 'Safari',
    );
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate((widget) => widget is NativeGlassSegments),
      findsOneWidget,
    );
    expect(find.text('翻译历史'), findsOneWidget);

    for (final mode in [AppearanceModes.dark, AppearanceModes.light]) {
      GlassAppearance.current.value = GlassAppearance(mode: mode);
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.text('Safari · 09:30'))).brightness,
        mode == AppearanceModes.light ? Brightness.light : Brightness.dark,
      );
      final expected = mode == AppearanceModes.light
          ? Colors.black
          : Colors.white;
      final translation = tester.widget<SelectableText>(
        find.ancestor(
          of: find.text('old translation'),
          matching: find.byType(SelectableText),
        ),
      );
      expect(translation.style!.color, expected);
    }
    store.insert(
      sourceText: 'new source',
      translatedText: 'new translation',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: completedAt + 60000,
      sourceLabel: 'Notes',
    );
    await tester.pumpAndSettle();
    expect(find.text('Notes · 09:31'), findsOneWidget);
    expect(find.text('new translation'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    GlassAppearance.current.value = const GlassAppearance();
  });

  testWidgets('分段在 38pt 标题栏带内居中，空白处拖动转给原生窗口（#67）', (tester) async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == MethodNames.startWindowDrag) return null;
          return handleHistoryRequest(store, call);
        });
    tester.view.physicalSize = const Size(520, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    store.insert(
      sourceText: 'hello',
      translatedText: '你好',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: 1,
      sourceLabel: 'Notes',
    );
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    final segments = find.byWidgetPredicate(
      (widget) => widget is NativeGlassSegments,
    );
    expect(tester.getCenter(segments).dy, GlassMetrics.compactTitlebarHeight / 2);
    expect(tester.getCenter(segments).dx, 260);
    expect(find.byType(NativeGlassSwitch), findsNothing);

    await tester.dragFrom(const Offset(90, 19), const Offset(40, 30));
    await tester.pumpAndSettle();
    expect(
      calls.where((method) => method == MethodNames.startWindowDrag),
      hasLength(1),
    );

    await tester.tap(find.byKey(const ValueKey('history-filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notes').last);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(
        find.ancestor(
          of: findLineIcon(LucideIcons.x),
          matching: find.byType(InkWell),
        ).first,
      ),
      const Size.square(GlassMetrics.minTouchTarget),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('按日期分组共用一张卡片，译文在原文上方，滚动可读第三页', (tester) async {
    tester.view.physicalSize = const Size(520, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (var i = 0; i < 23; i++) {
      store.insert(
        sourceText: 'source-$i',
        translatedText: '译文-$i',
        detectedLanguage: 'en',
        targetLanguage: 'zh-CN',
        providerId: 'google',
        completedAt: DateTime(2026, 9, 19, 9, 30, i).millisecondsSinceEpoch,
        sourceLabel: i == 22 ? '截图' : 'Safari',
      );
    }
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.text('2026-09-19'), findsOneWidget);
    expect(find.byType(HistoryGroupCard), findsOneWidget);
    expect(find.text('截图 · 09:30'), findsOneWidget);
    expect(find.text('Safari · 09:30'), findsWidgets);
    expect(find.text('译文'), findsNothing);
    expect(find.text('原文'), findsNothing);
    expect(
      tester.getTopLeft(find.text('译文-22')).dy,
      lessThan(tester.getTopLeft(find.text('source-22')).dy),
    );
    await tester.scrollUntilVisible(
      find.text('source-0'),
      400,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 60,
    );
    await tester.pumpAndSettle();
    expect(find.text('source-0'), findsOneWidget);
    expect(find.text('译文-0'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('已显示全部历史'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长文及窄窗口可阅读', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    store.insert(
      sourceText: '原文第一段\n\n${'long text ' * 60}',
      translatedText: '完整译文\n保留换行',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
      providerId: 'google',
      completedAt: 1000,
    );
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.textContaining('未记录来源 · '), findsOneWidget);
    expect(find.text('完整译文\n保留换行'), findsOneWidget);
    expect(store.page(), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('刷新失败保留可见记录，恢复后重试首批替换而不重复追加', (tester) async {
    store.insert(
      sourceText: 'source',
      translatedText: '译文',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: 1,
    );
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    database.execute(
      'ALTER TABLE translation_history RENAME TO unavailable_history',
    );
    await tester.tap(find.byKey(const ValueKey('history-more-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('译文'), findsWidgets);
    expect(find.text('source'), findsOneWidget);
    database.execute(
      'ALTER TABLE unavailable_history RENAME TO translation_history',
    );
    database.execute("UPDATE translation_history SET translated_text = '刷新结果'");
    await tester.ensureVisible(find.text('重试加载'));
    await tester.tap(find.text('重试加载'));
    await tester.pumpAndSettle();
    expect(find.text('刷新结果'), findsOneWidget);
    expect(find.text('source'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('悬停出现复制删除，筛选标签可单独移除，清空全部经「⋯」菜单确认覆盖全部记录', (tester) async {
    for (var index = 0; index < 11; index++) {
      store.insert(
        sourceText: 'source-$index',
        translatedText: '译文-$index',
        detectedLanguage: 'en',
        targetLanguage: 'zh',
        providerId: 'test',
        completedAt: index + 1,
        sourceLabel: 'Safari',
      );
    }
    store.insert(
      sourceText: 'unique',
      translatedText: '目标译文',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: 100,
      sourceLabel: 'Notes',
    );
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('history-filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();
    expect(find.text('来源：Notes'), findsOneWidget);
    expect(find.text('unique'), findsOneWidget);
    expect(find.text('source-10'), findsNothing);

    final mouse = await _startMouse(tester);
    await _hoverRow(tester, mouse, find.text('unique'));
    await tester.tap(find.byTooltip('删除翻译记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.page(limit: 20), hasLength(12));
    await tester.tap(find.byTooltip('删除翻译记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(store.page(limit: 20), hasLength(11));

    await tester.tap(find.byTooltip('移除来源：Notes筛选'));
    await tester.pumpAndSettle();
    expect(find.text('来源：Notes'), findsNothing);
    expect(find.text('source-10'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('history-search')),
      '译文-10',
    );
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    expect(find.text('source-10'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('history-more-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空全部'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不受当前筛选范围限制'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.page(limit: 20), hasLength(11));

    await tester.tap(find.byKey(const ValueKey('history-more-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空全部'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(store.page(), isEmpty);
    expect(find.byType(HistoryEmptyState), findsOneWidget);
    expect(find.text('还没有翻译记录'), findsOneWidget);
  });

  testWidgets('分页失败后重试原游标，保留已加载记录并追加剩余记录', (tester) async {
    for (var index = 0; index < 11; index++) {
      store.insert(
        sourceText: 'source-$index',
        translatedText: 'result-$index',
        detectedLanguage: 'en',
        targetLanguage: 'zh',
        providerId: 'test',
        completedAt: index + 1,
      );
    }
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    database.execute(
      'ALTER TABLE translation_history RENAME TO unavailable_history',
    );
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -5000));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('重试加载'));
    database.execute(
      'ALTER TABLE unavailable_history RENAME TO translation_history',
    );
    await tester.tap(find.text('重试加载'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(find.text('source-0'), findsOneWidget);
    expect(find.text('已显示全部历史'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 5000));
    await tester.pumpAndSettle();
    expect(find.text('source-10'), findsOneWidget);
  });

  testWidgets('首次默认期限显示计数，未确认状态在「⋯」菜单标注，选择永久保留后持久生效', (tester) async {
    store.insert(
      sourceText: 'old',
      translatedText: '旧记录',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: 1,
    );
    database.execute("DELETE FROM history_meta WHERE key LIKE 'retention_%'");
    store = TranslationHistoryStore(database, now: () => DateTime(2026, 11, 3));
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.textContaining('将清理 1 条记录'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.retentionConfirmed, isFalse);
    expect(store.page(), hasLength(1));
    expect(find.text('保留期限尚未确认，现有记录不会自动清理。'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('history-more-button')));
    await tester.pumpAndSettle();
    expect(find.text('保留期限（未确认）'), findsOneWidget);
    expect(find.text('30 天（未确认）'), findsOneWidget);
    await tester.tap(find.text('90 天'));
    await tester.pumpAndSettle();
    expect(find.textContaining('最近 90 天'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.retentionDays, 30);

    await tester.tap(find.byKey(const ValueKey('history-more-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('永久保留'));
    await tester.pumpAndSettle();
    expect(store.retentionDays, 0);
    expect(store.retentionConfirmed, isTrue);
    expect(store.page(), hasLength(1));
    expect(find.text('旧记录'), findsOneWidget);
  });

  testWidgets('搜索防抖生效，支持输入框内清除并区分无匹配与空列表', (tester) async {
    store.insert(
      sourceText: 'hello world',
      translatedText: '你好世界',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: 1000,
      sourceLabel: 'Notes',
    );
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('history-search-clear')), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('history-search')),
      '不存在的词',
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('hello world'), findsOneWidget);
    expect(find.byKey(const ValueKey('history-search-clear')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的翻译历史'), findsOneWidget);
    expect(find.text('还没有翻译记录'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('history-search-clear')));
    await tester.pumpAndSettle();
    expect(find.text('hello world'), findsOneWidget);
  });

  testWidgets('分段切换同步窗口标题、延迟加载并保持搜索状态，支持悬停复制、键帽空状态与日期选择器', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final clipboard = <String>[];
    final windowTitles = <String>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.setWindowTitle) {
        windowTitles.add((call.arguments as Map)['title'] as String);
        return null;
      }
      if (call.method == MethodNames.getSettings) {
        return {
          PreferenceKeys.shortcutModifiers:
              ShortcutKeys.command | ShortcutKeys.shift,
          PreferenceKeys.shortcutLabel: 'T',
          PreferenceKeys.screenshotShortcutModifiers:
              ShortcutKeys.command | ShortcutKeys.option,
          PreferenceKeys.screenshotShortcutLabel: 'X',
        };
      }
      if (call.method == MethodNames.vocabularyList ||
          call.method == MethodNames.screenshotHistoryList) {
        return const <Map<String, Object>>[];
      }
      if (call.method == MethodNames.screenshotHistoryRecording) {
        return true;
      }
      try {
        return handleHistoryRequest(store, call);
      } on SqliteException catch (error) {
        throw PlatformException(
          code: 'history_storage',
          message: error.message,
        );
      }
    });
    store.insert(
      sourceText: 'keep-filter',
      translatedText: '保持筛选结果',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: 2000,
      sourceLabel: 'Safari',
    );
    final itemId = store.page(limit: 1).single.id;
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.byType(VocabularyPage), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('history-search')),
      'keep-filter',
    );
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();

    await tester.tap(find.text('生词本').first);
    await tester.pumpAndSettle();
    expect(find.byType(VocabularyPage), findsOneWidget);
    expect(find.text('记录'), findsNothing);
    expect(find.text('还没有生词'), findsOneWidget);

    await tester.tap(find.text('截图历史').first);
    await tester.pumpAndSettle();
    expect(find.text('还没有截图记录'), findsOneWidget);
    final keycaps = tester.widget<NativeGlassKeycaps>(
      find.byType(NativeGlassKeycaps),
    );
    expect(keycaps.tokens, ['⌥', '⌘', 'X']);

    await tester.tap(find.text('翻译历史').first);
    await tester.pumpAndSettle();
    expect(windowTitles, ['生词本', '截图历史', '翻译历史']);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('history-search')))
          .controller!
          .text,
      'keep-filter',
    );

    final mouse = await _startMouse(tester);
    final rowFinder = find.byKey(ValueKey('history-$itemId'));
    final rowOpacity = find.descendant(
      of: rowFinder,
      matching: find.byType(AnimatedOpacity),
    );
    expect(tester.widget<AnimatedOpacity>(rowOpacity).opacity, 0);
    await _hoverRow(tester, mouse, rowFinder);
    expect(tester.widget<AnimatedOpacity>(rowOpacity).opacity, 1);

    expect(
      tester.widget<CopyConfirmIcon>(find.byType(CopyConfirmIcon).first).trigger,
      0,
    );
    await tester.tap(find.byTooltip('复制译文').first);
    await tester.pumpAndSettle();
    expect(clipboard, ['保持筛选结果']);
    expect(
      tester.widget<CopyConfirmIcon>(find.byType(CopyConfirmIcon).first).trigger,
      1,
    );

    await tester.tap(find.byKey(const ValueKey('history-filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('起始日期…'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });
}
