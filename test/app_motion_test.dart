import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:motor/motor.dart';
import 'package:transnap/src/common/constants/motion_metrics.dart';
import 'package:transnap/src/common/constants/translation_phase.dart';
import 'package:transnap/src/common/widgets/app_motion.dart';
import 'package:transnap/src/common/widgets/native_glass.dart';
import 'support/line_icons.dart';

/// 无参数；验证公共动效基座的无障碍降级、光学高光安全回退、五组纯 Dart 矢量状态机与侧边栏弹簧滑块（#142）。
void main() {
  testWidgets(
    '减少动态效果时 BouncyPresence、GentleReveal 与 OpticalPrismOverlay 瞬时降级且无异常',
    (tester) async {
      // 边界：disableAnimations 为 true 时跳过电机/链式包装并直出内容，OpticalPrismOverlay 仍能稳定绘制。
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
    // 边界：sweepTrigger 递增后 1100ms 扫光完成并自然收敛，pumpAndSettle 不超时且不改变子组件文本可见性。
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
    // 边界：朗读空闲保留 LucideIcons.volume2；复制触发后先变为对勾绘制，1000ms 结束复原为 LucideIcons.copy；
    // 图标之间 160ms 交叉过渡，过渡期间新旧图标并存，过渡结束（等待 200ms）后旧图标移除。
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
    // 交叉过渡进行中旧图标仍在淡出；200ms 后过渡结束，旧图标移除。
    await tester.pump(const Duration(milliseconds: 200));
    expect(findLineIcon(LucideIcons.volume2), findsNothing);
    expect(findLineIcon(LucideIcons.bookmarkPlus), findsNothing);
    expect(findLineIcon(LucideIcons.copy), findsNothing);

    // 等满复制确认停留时长后复原，再等交叉过渡结束。
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
    // 边界：staggerIndex=2（160ms 延迟）在延迟到期前卸载后，FakeAsync 中不得残留任何 Timer。
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
    // 边界：从一级分组「通用」切到二级子页「录制」后，语义选中状态迁移到「录制」，滑块高度从 32pt 过渡到 28pt。
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
        // 侧边栏滑块读取主题中的系统强调色（#142）。
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

    // 验证选中滑块与侧边栏左右各留 6pt 内边距，并在垂直方向与选中行完全对齐（#142）。
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
    // 作用：流式译文逐字显影时已显示的字不再闪烁。
    // 边界：「你好」显影中追加「世界」后，前缀 2 字合为一段、只有 2 个新字逐字绘制；
    // 换成不以原文开头的「再见」时 0 个前缀字；单字 260ms 加错峰后（< 1s）回到单个纯文本片段。
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
    // 作用：验证通用组件 LiquidSplit 可无前置 lead、可开启 scrollable 并正确在动画期放开裁剪、
    // 且展开中转 collapsing: true 不跳变并快速回调 onCollapsed，数量变化不越界。
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

    // 动画期间滚动容器放开裁剪（Clip.none），避免飞出锚点处被裁切，且粘连液滴正在绘制。
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

    // 展开未结束即反向快速收起：首帧位置接续当前中途位移，并在 220ms 内完成通知。
    setHostState(() => collapsing = true);
    await tester.pump();
    expect(
      tester.getCenter(find.byKey(const Key('item-1'))).dx,
      closeTo(midX, 0.5),
    );
    await tester.pump(const Duration(milliseconds: 220));
    expect(collapsedCount, 1);

    // 验证快节奏展开（240ms/0.78）：接近落位（约 240ms）时蓝色液滴已淡出移除，<= 420ms 内彻底停表。
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

    // 收起中途重新展开不应触发滞后 onCollapsed，按钮数变化也保持安全不越界。
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
    // 作用：验证开启系统「减少动态效果」时复制操作依然给出静态视觉确认且计时结束后正常还原、卸载不漏 Timer。
    // 边界：trigger 从 0 -> 1 后立即呈现绿色 CustomPaint 对勾（无 Copy 图标）；满 copyConfirmDuration 后切回 LucideIcons.copy。
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

    // 边界：再次触发后未到期前直接卸载组件，FakeAsync 中不得残留待处理 Timer。
    setHostState(() => trigger = 2);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('CharReveal 包含复合 Emoji 追加与切片不越界（U-27）', (tester) async {
    // 作用：验证流式译文含 UTF-16 代理对 / ZWJ Emoji 时按真实字形计数切片，不出现乱码拆字或越界。
    // 边界：前缀「🚀」占 2 个 UTF-16 code units 但为 1 个字形，追加「完成」后前缀仍完整保留 1 个「🚀」、后缀只显影 2 个新字。
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
