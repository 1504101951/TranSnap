import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:motor/motor.dart';
import 'package:transnap/src/common/constants/motion_metrics.dart';
import 'package:transnap/src/common/constants/translation_phase.dart';
import 'package:transnap/src/common/widgets/app_motion.dart';
import 'package:transnap/src/common/widgets/native_glass.dart';
import 'support/line_icons.dart';

void main() {
  testWidgets(
    '减少动态效果时 BouncyPresence、GentleReveal 与 OpticalPrismOverlay 瞬时降级且无异常',
    (tester) async {
      await tester.pumpWidget(
        const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            home: Scaffold(
              body: BouncyPresence(
                child: GentleReveal(
                  staggerIndex: 2,
                  child: OpticalPrismOverlay(
                    sweepTrigger: 1,
                    child: SizedBox(
                      width: 240,
                      height: 120,
                      child: Text('无障碍降级'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('无障碍降级'), findsOneWidget);
      expect(find.byType(SingleMotionBuilder), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('BouncyPresence、GentleReveal 与 OpticalPrismOverlay 扫光均可正常收敛', (
    tester,
  ) async {
    var sweep = 0;
    late StateSetter setHostState;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setHostState = setState;
              return BouncyPresence(
                child: GentleReveal(
                  staggerIndex: 1,
                  child: OpticalPrismOverlay(
                    sweepTrigger: sweep,
                    child: const SizedBox(
                      width: 260,
                      height: 140,
                      child: Text('光学棱镜'),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    setHostState(() => sweep = 1);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('光学棱镜'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('五组纯 Dart 矢量状态机：状态切换正确，图标交叉过渡后旧图标移除，复制确认 1 秒复原且无残留计时器', (
    tester,
  ) async {
    var phase = TranslationPhase.translating;
    var speaking = false;
    var saved = false;
    var copyTrigger = 0;
    int? countdown = 3;
    var recActive = false;
    var elapsed = 0;
    late StateSetter update;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Row(
                children: [
                  TranslationStatusIcon(phase: phase),
                  SpeechWaveIcon(speaking: speaking),
                  VocabularyBookmarkIcon(saved: saved),
                  CopyConfirmIcon(trigger: copyTrigger),
                  RecordingPulseIcon(
                    countdown: countdown,
                    active: recActive,
                    pulseKey: elapsed,
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    expect(findLineIcon(LucideIcons.volume2), findsOneWidget);
    expect(findLineIcon(LucideIcons.bookmarkPlus), findsOneWidget);
    expect(findLineIcon(LucideIcons.copy), findsOneWidget);
    expect(find.text('3'), findsOneWidget);

    update(() {
      phase = TranslationPhase.completed;
      speaking = true;
      saved = true;
      copyTrigger = 1;
      countdown = null;
      recActive = true;
      elapsed = 1;
    });
    await tester.pump();
    expect(findLineIcon(LucideIcons.bookmarkCheck), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    expect(findLineIcon(LucideIcons.volume2), findsNothing);
    expect(findLineIcon(LucideIcons.bookmarkPlus), findsNothing);
    expect(findLineIcon(LucideIcons.copy), findsNothing);

    await tester.pump(MotionMetrics.copyConfirmDuration);
    await tester.pump(const Duration(milliseconds: 200));
    expect(findLineIcon(LucideIcons.copy), findsOneWidget);

    update(() {
      phase = TranslationPhase.failed;
      speaking = false;
      elapsed = 2;
    });
    await tester.pumpAndSettle();
    expect(findLineIcon(LucideIcons.volume2), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GentleReveal 带错峰延迟时单帧直接卸载不泄漏待处理 Timer', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GentleReveal(staggerIndex: 2, child: Text('延迟段落')),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('NativeGlassSidebar 切换选中项时由 Bouncy 弹簧滑块跟进并保持单一选中语义', (
    tester,
  ) async {
    var current = 'general';
    const sections = <NativeGlassSidebarSection<String>>[
      (title: '通用', icon: LucideIcons.sliders, value: 'general', children: {}),
      (
        title: '截图',
        icon: LucideIcons.scan,
        value: null,
        children: {'save': '保存与导出', 'recording': '录制'},
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => NativeGlassSidebar<String>(
              value: current,
              sections: sections,
              onChanged: (next) => setState(() => current = next),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('录制'));
    await tester.pumpAndSettle();
    expect(current, 'recording');
    final semantics = tester.widgetList<Semantics>(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.selected == true,
      ),
    );
    expect(semantics, hasLength(1));

    final sidebarRect = tester.getRect(find.byType(NativeGlassSidebar<String>));
    final indicatorRect = tester.getRect(
      find.byKey(const ValueKey('native-glass-sidebar-indicator')),
    );
    final selectedRowRect = tester.getRect(
      find.ancestor(
        of: find.text('录制'),
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.selected == true,
        ),
      ),
    );
    expect(
      indicatorRect.left,
      moreOrLessEquals(sidebarRect.left + 6, epsilon: 0.01),
    );
    expect(
      indicatorRect.right,
      moreOrLessEquals(sidebarRect.right - 6, epsilon: 0.01),
    );
    expect(
      indicatorRect.top,
      moreOrLessEquals(selectedRowRect.top, epsilon: 0.01),
    );
    expect(
      indicatorRect.height,
      moreOrLessEquals(selectedRowRect.height, epsilon: 0.01),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('CharReveal 追加文字只显影新到达的字，替换文字整段重新显影，结束后为整段纯文本（#142）', (
    tester,
  ) async {
    late TextSpan span;
    Widget host(String text) => MaterialApp(
      home: CharReveal(
        text: text,
        style: const TextStyle(color: Colors.black),
        builder: (context, value) {
          span = value;
          return Text.rich(value);
        },
      ),
    );
    await tester.pumpWidget(host('你好'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(host('你好世界'));
    await tester.pump(const Duration(milliseconds: 16));
    expect((span.children!.first as TextSpan).text, '你好');
    expect(span.children!.length, 1 + 2);
    await tester.pumpWidget(host('再见'));
    await tester.pump(const Duration(milliseconds: 16));
    expect((span.children!.first as TextSpan).text, '');
    expect(span.children!.length, 1 + 2);
    await tester.pump(const Duration(seconds: 1));
    expect(span.children, isNull);
    expect(span.text, '再见');
  });

  testWidgets('LiquidSplit 支持可选 lead、可滚动裁剪切换、中途打断反向收敛及长度动态变更（#67、#142）', (
    tester,
  ) async {
    final anchorKey = GlobalKey();
    var collapsing = false;
    var itemCount = 2;
    var collapsedCount = 0;
    late StateSetter setHostState;

    Widget buildHost() => MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) {
            setHostState = setState;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox.square(
                  dimension: 32,
                  child: DecoratedBox(
                    key: anchorKey,
                    decoration: const BoxDecoration(color: Colors.blue),
                  ),
                ),
                LiquidSplit(
                  flexKey: const Key('test-liquid-scroll'),
                  axis: Axis.horizontal,
                  scrollable: true,
                  items: [
                    for (var i = 0; i < itemCount; i++)
                      SizedBox.square(
                        key: Key('item-$i'),
                        dimension: 32,
                        child: Text('$i'),
                      ),
                  ],
                  anchor: anchorKey,
                  color: Colors.blue,
                  collapsing: collapsing,
                  onCollapsed: () => setState(() => collapsedCount += 1),
                ),
              ],
            );
          },
        ),
      ),
    );

    await tester.pumpWidget(buildHost());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 40));

    expect(
      tester
          .widget<SingleChildScrollView>(
            find.byKey(const Key('test-liquid-scroll')),
          )
          .clipBehavior,
      Clip.none,
    );
    expect(find.byType(ImageFiltered), findsOneWidget);
    final midX = tester.getCenter(find.byKey(const Key('item-1'))).dx;

    setHostState(() => collapsing = true);
    await tester.pump();
    expect(
      tester.getCenter(find.byKey(const Key('item-1'))).dx,
      closeTo(midX, 0.5),
    );
    await tester.pump(const Duration(milliseconds: 220));
    expect(collapsedCount, 1);

    setHostState(() => collapsing = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 240));
    expect(find.byType(ImageFiltered), findsNothing);
    await tester.pump(const Duration(milliseconds: 180));
    expect(
      tester
          .widget<SingleChildScrollView>(
            find.byKey(const Key('test-liquid-scroll')),
          )
          .clipBehavior,
      Clip.hardEdge,
    );

    setHostState(() => collapsing = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 24));
    setHostState(() {
      collapsing = false;
      itemCount = 3;
    });
    await tester.pumpAndSettle();
    expect(collapsedCount, 1);
    expect(
      tester
          .widget<SingleChildScrollView>(
            find.byKey(const Key('test-liquid-scroll')),
          )
          .clipBehavior,
      Clip.hardEdge,
    );
    expect(find.byKey(const Key('item-2')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('CopyConfirmIcon 在减弱动态效果下仍显示静态绿色对勾并于 1.3s 后复原（U-10）', (
    tester,
  ) async {
    var trigger = 0;
    late StateSetter setHostState;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          theme: NativeGlassTheme.data(Brightness.light),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setHostState = setState;
                return CopyConfirmIcon(trigger: trigger);
              },
            ),
          ),
        ),
      ),
    );
    expect(findLineIcon(LucideIcons.copy), findsOneWidget);

    setHostState(() => trigger = 1);
    await tester.pump();
    expect(findLineIcon(LucideIcons.copy), findsNothing);
    expect(find.bySemanticsLabel('已复制'), findsOneWidget);

    await tester.pump(MotionMetrics.copyConfirmDuration);
    await tester.pump();
    expect(findLineIcon(LucideIcons.copy), findsOneWidget);

    setHostState(() => trigger = 2);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('CharReveal 包含复合 Emoji 追加与切片不越界（U-27）', (tester) async {
    late TextSpan span;
    Widget host(String text) => MaterialApp(
      home: CharReveal(
        text: text,
        style: const TextStyle(color: Colors.black),
        builder: (context, value) {
          span = value;
          return Text.rich(value);
        },
      ),
    );
    await tester.pumpWidget(host('🚀'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pumpWidget(host('🚀完成'));
    await tester.pump(const Duration(milliseconds: 16));
    expect((span.children!.first as TextSpan).text, '🚀');
    expect(span.children!.length, 1 + 2);
    await tester.pump(const Duration(seconds: 1));
    expect(span.text, '🚀完成');
    expect(tester.takeException(), isNull);
  });
}
