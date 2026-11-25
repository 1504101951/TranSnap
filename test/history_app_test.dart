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

/// 无参数；用真实 SQLite 驱动窗口，验证分组卡片、筛选标签、标题同步、空状态及保存失败反馈。
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
        // 用原生转发的同一协议连接真实SQLite写入与历史窗口，不手工重建窗口。
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
    // 仅替代原生转发层；查询、游标和开关均使用真实数据库结果。
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
    // 作用：验证明暗外观下卡片正文可读性、标题栏居中分段与右侧记录开关位置，以及 historyChanged 自动刷新。
    // 边界：切换亮暗外观时译文使用高对比主色，来源 · 时间使用次要色；新插入记录即时出现。
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
    // 标题栏居中放分段、右侧放「记录」开关，不另外显示标题文字。
    expect(
      find.byWidgetPredicate((widget) => widget is NativeGlassSegments),
      findsOneWidget,
    );
    expect(find.text('翻译历史'), findsOneWidget);
    expect(find.text('记录'), findsOneWidget);
    expect(find.byType(NativeGlassSwitch), findsOneWidget);

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

  testWidgets('分段与记录开关在 38pt 标题栏带内同排，空白处拖动转给原生窗口，窄窗口开关移到带下（#67）', (tester) async {
    // 作用：验证窗口通顶后标题栏带的布局与拖动转发，以及筛选小标签移除按钮的命中尺寸。
    // 边界：520pt 宽时分段与开关的垂直中心都在 19（38 的一半），开关右缘距窗口右缘 16；
    // 在标题栏带左侧空白处拖动发出一次 startWindowDrag；480pt 宽（小于 520）时开关顶边低于 38；
    // 筛选小标签的移除按钮命中区为 24×24。
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
    final toggle = find.byType(NativeGlassSwitch);
    expect(tester.getCenter(segments).dy, GlassMetrics.compactTitlebarHeight / 2);
    expect(tester.getCenter(segments).dx, 260);
    expect(tester.getCenter(toggle).dy, GlassMetrics.compactTitlebarHeight / 2);
    expect(tester.getRect(toggle).right, 520 - GlassMetrics.space16);

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

    tester.view.physicalSize = const Size(480, 640);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(toggle).top,
      greaterThan(GlassMetrics.compactTitlebarHeight),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('按日期分组共用一张卡片，译文在原文上方，滚动可读第三页', (tester) async {
    // 作用：验证按日期分组、同组共用 HistoryGroupCard、「来源 · HH:mm」在右上、译文 14/20 在上及触底分页。
    // 边界：23 条跨越两次 10 条边界；520×640 与实际历史窗口一致，滚动后可见第 3 页记录及末尾提示。
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

  testWidgets('长文及窄窗口可阅读，关闭记录将文字改为「记录 · 已暂停」且不显示非错误横幅', (tester) async {
    // 作用：验证 320pt 窄窗口无溢出、只读数据库触发保存失败不改开关状态，关闭记录后文案合并进开关旁且不弹非错误横幅。
    // 边界：320×640 触发窄窗口标题栏换行；只读 SQLite 真实触发错误横幅；成功后「记录 · 已暂停」出现且无非错误横幅。
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
    database.execute('PRAGMA query_only = ON');
    await tester.tap(find.byType(NativeGlassSwitch));
    await tester.pumpAndSettle();
    expect(
      tester.widget<NativeGlassSwitch>(find.byType(NativeGlassSwitch)).value,
      isTrue,
    );
    expect(find.textContaining('readonly'), findsOneWidget);
    database.execute('PRAGMA query_only = OFF');
    await tester.tap(find.byType(NativeGlassSwitch));
    await tester.pumpAndSettle();
    expect(store.recordingEnabled, isFalse);
    expect(find.text('记录 · 已暂停'), findsOneWidget);
    expect(find.text('已暂停记录；已有历史仍保留。'), findsNothing);
    expect(find.text('完整译文\n保留换行'), findsOneWidget);
    expect(store.page(), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('刷新失败保留可见记录，恢复后重试首批替换而不重复追加', (tester) async {
    // 作用：验证经「⋯」菜单触发刷新失败时保留既有列表并提示错误横幅，恢复后可重试替换。
    // 边界：首批不足10条时已到末页；重命名真实表令刷新失败，重试仍需绕过末页状态。
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
    // 作用：验证静息隐藏操作按钮、悬停显示复制删除、筛选生成可移除标签及「⋯」清空全部确认。
    // 边界：11条跨页记录加1个其他来源；逐个移除标签恢复全量，清空全部仍覆盖全部11条。
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

    // 按来源筛选并在管理行下方显示可移除标签。
    await tester.tap(find.byKey(const ValueKey('history-filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Notes'));
    await tester.pumpAndSettle();
    expect(find.text('来源：Notes'), findsOneWidget);
    expect(find.text('unique'), findsOneWidget);
    expect(find.text('source-10'), findsNothing);

    // 悬停条目后才可点击删除，取消不修改数据，确认后删除。
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

    // 点选标签上的关闭图标移除来源筛选，列表恢复 Safari 记录。
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
    // 作用：验证 11 条记录跨 10 条分页失败后保留前 10 条，恢复数据库表后点击「重试加载」追加第 11 条。
    // 边界：SQLite 真实缺表触发分页异常，恢复后不重新覆盖已加载的前 10 条。
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
    // 作用：验证未确认保留期限时不再显示非错误横幅，而是在「⋯」菜单明确标注，且可在菜单内修改。
    // 边界：过期 1 条且偏好未确认；首次弹窗取消不删，菜单可见「保留期限（未确认）」，改为永久保留后标注消失。
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

  testWidgets('历史窗口切换记录历史等待期间开关外圈显示进度环，完成后收起（#142）', (tester) async {
    // 作用：验证 setHistoryRecording 事务进行中时，记录开关的 BusyRing.active 为真、结束后为假。
    // 边界：切换期间异步保存挂起，BusyRing.active=true；释放并回包后恢复为 false。
    final pending = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == MethodNames.setHistoryRecording) {
            await pending.future;
          }
          return handleHistoryRequest(store, call);
        });
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();

    final toggle = find.byType(NativeGlassSwitch);
    BusyRing ring() => tester.widget<BusyRing>(
      find.descendant(of: toggle, matching: find.byType(BusyRing)).first,
    );
    expect(ring().active, isFalse);

    await tester.tap(toggle);
    await tester.pump();
    expect(ring().active, isTrue);

    pending.complete();
    await tester.pumpAndSettle();
    expect(ring().active, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('搜索防抖生效，支持输入框内清除并区分无匹配与空列表', (tester) async {
    // 作用：验证 200ms 搜索防抖、清除按钮显隐及无筛选结果与空列表文案区分。
    // 边界：未满 200ms 不触发远端查询；筛选无结果时显示「没有匹配的翻译历史」而非空状态。
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
    // 作用：验证标题栏分段切换发送 setWindowTitle、空状态展示当前设置键帽快捷键、悬停后复制及筛选菜单打开系统日期选择。
    // 边界：停留在翻译历史时不挂载 VocabularyPage；切换分段后依次发送对应标题且不带 App 名。
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

    // 切去生词本时隐藏记录开关并同步窗口标题为「生词本」。
    await tester.tap(find.text('生词本').first);
    await tester.pumpAndSettle();
    expect(find.byType(VocabularyPage), findsOneWidget);
    expect(find.text('记录'), findsNothing);
    expect(find.text('还没有生词'), findsOneWidget);

    // 切去截图历史时传入当前区域截图快捷键键帽并同步窗口标题为「截图历史」。
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

    // 静息时复制按钮不可见（透明度 0），悬停后点击复制译文触发确认动效。
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

    // 从「筛选」菜单打开起始日期系统选择器，选择后不崩且关闭弹窗。
    await tester.tap(find.byKey(const ValueKey('history-filter-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('起始日期…'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });
}
