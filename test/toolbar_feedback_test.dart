import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:transnap/src/common/constants/glass_metrics.dart';
import 'package:transnap/src/common/widgets/native_glass.dart';
import 'package:transnap/src/common/widgets/toolbar_feedback.dart';
import 'support/line_icons.dart';

void main() {
  testWidgets('报错气泡显示语义图标与关闭钮，悬停回调准确触发（U-15、#144）', (tester) async {
    var hovered = false;
    var dismissed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: SizedBox(
            width: 480,
            height: 320,
            child: Stack(
              children: [
                ToolbarFeedback(
                  toolbar: const Rect.fromLTWH(80, 140, 240, 48),
                  message: '保存失败：磁盘空间不足',
                  isError: true,
                  onHoverChanged: (value) => hovered = value,
                  onDismiss: () => dismissed += 1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(findLineIcon(LucideIcons.circleAlert), findsOneWidget);
    expect(find.byKey(const Key('toolbar-feedback-dismiss')), findsOneWidget);
    expect(GlassMetrics.errorFeedbackDuration, const Duration(milliseconds: 2000));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('保存失败：磁盘空间不足')));
    await tester.pump();
    expect(hovered, isTrue);

    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(hovered, isFalse);
    await mouse.removePointer();

    await tester.tap(find.byKey(const Key('toolbar-feedback-dismiss')));
    await tester.pump();
    expect(dismissed, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('极窄视口与 liveRegion=false 不抛异常且关闭即时播报语义（U-15、U-24）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: const Scaffold(
          body: SizedBox(
            width: 40,
            height: 80,
            child: Stack(
              children: [
                ToolbarFeedback(
                  toolbar: Rect.fromLTWH(0, 20, 40, 40),
                  message: '正在转换 42%',
                  liveRegion: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    final semantics = find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.liveRegion == true,
    );
    expect(semantics, findsNothing);
  });
}
