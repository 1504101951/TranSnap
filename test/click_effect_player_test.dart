import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/screenshot_enums.dart';
import 'package:transnap/src/settings/click_effect_player.dart';

void main() {
  test('自动循环时间轴按每段 1.6 秒依次映射到左键、右键、拖动，单一动作时只映射该动作（#143）', () {
    expect(ClickEffectDemo.frameAt(0, null).action, ClickDemoAction.left);
    final right = ClickEffectDemo.frameAt(2.0, null);
    expect(right.action, ClickDemoAction.right);
    expect(right.time, closeTo(0.4, 1e-9));
    final drag = ClickEffectDemo.frameAt(4.8, null);
    expect(drag.action, ClickDemoAction.drag);
    expect(drag.time, closeTo(1.6, 1e-9));
    final only = ClickEffectDemo.frameAt(1.2, ClickDemoAction.right);
    expect(only.action, ClickDemoAction.right);
    expect(only.time, 1.2);
    expect(ClickEffectDemo.cycleSeconds(null), closeTo(4.8, 1e-9));
    expect(ClickEffectDemo.cycleSeconds(ClickDemoAction.drag), 1.6);
  });

  testWidgets('播放器自动循环高亮当前动作，点动作只循环该动作，暂停后停在当前动作，点样式回调所选样式（#143）', (
    tester,
  ) async {
    RecordingClickEffect? chosen;
    FontWeight? weightOf(ClickDemoAction action) => tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(Key('click-demo-${action.name}')),
            matching: find.text(action.label),
          ),
        )
        .style
        ?.fontWeight;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ClickEffectPlayer(
              effect: RecordingClickEffect.optical,
              onChanged: (value) => chosen = value,
            ),
          ),
        ),
      ),
    );
    expect(
      tester.getSize(find.byKey(const Key('click-effect-stage'))),
      ClickEffectDemo.stageSize,
    );
    expect(weightOf(ClickDemoAction.left), FontWeight.w600);
    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pump(const Duration(milliseconds: 16));
    expect(weightOf(ClickDemoAction.right), FontWeight.w600);
    expect(weightOf(ClickDemoAction.left), FontWeight.w400);

    await tester.tap(find.byKey(const Key('click-demo-drag')));
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 700));
      expect(weightOf(ClickDemoAction.drag), FontWeight.w600);
    }

    await tester.tap(find.byTooltip('暂停'));
    await tester.pump();
    expect(find.byTooltip('播放'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(weightOf(ClickDemoAction.drag), FontWeight.w600);

    await tester.tap(find.byKey(const Key('click-effect-prism')));
    expect(chosen, RecordingClickEffect.prism);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('减少动态效果时不自动循环，点动作播放一次后停在静态帧（#143）', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ClickEffectPlayer(
            effect: RecordingClickEffect.optical,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.byTooltip('播放'), findsOneWidget);
    await tester.tap(find.byKey(const Key('click-demo-right')));
    await tester.pump();
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
    expect(find.byTooltip('播放'), findsOneWidget);
  });
}
