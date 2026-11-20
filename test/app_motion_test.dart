import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motor/motor.dart';
import 'package:translate_app/src/common/constants/motion_metrics.dart';
import 'package:translate_app/src/common/constants/translation_phase.dart';
import 'package:translate_app/src/common/widgets/app_motion.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';

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

  testWidgets('五组纯 Dart 矢量状态机：状态切换正确，复制确认 1.3 秒自动回弹且无残留计时器', (tester) async {
    // 边界：朗读空闲保留 Icons.volume_up_rounded；复制触发后先变为对勾绘制，1.3s 结束自动恢复 Icons.copy_rounded。
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
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
    expect(find.byIcon(Icons.bookmark_add_outlined), findsOneWidget);
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
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
    expect(find.byIcon(Icons.volume_up_rounded), findsNothing);
    expect(find.byIcon(Icons.bookmark_added), findsOneWidget);
    expect(find.byIcon(Icons.copy_rounded), findsNothing);

    // 先推进一帧以锚定 Ticker 起始时间戳，再等待 1.3s 确认回弹完成并自然收敛。
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(MotionMetrics.copyConfirmDuration);
    await tester.pump();
    expect(find.byIcon(Icons.copy_rounded), findsOneWidget);

    update(() {
      phase = TranslationPhase.failed;
      speaking = false;
      elapsed = 2;
    });
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
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
      (title: '通用', icon: Icons.tune, value: 'general', children: {}),
      (
        title: '截图',
        icon: Icons.screenshot,
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
}
