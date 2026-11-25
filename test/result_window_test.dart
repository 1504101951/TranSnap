import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/widgets/result_window.dart';

void main() {
  testWidgets('上弹托盘三角在托盘实际宽度内对准锚点中心，超出时贴近末端（#67）', (tester) async {
    // 作用：验证三角位置由托盘实际宽度夹紧，而不是固定上限 400。
    // 边界：托盘内 16 个 28pt 方块加内边距 2×2 宽 452；锚点中心 430 时三角中心为 430（超过旧上限 406）；
    // 锚点中心 600 超出托盘时三角左缘夹到 452 − 8 − 12 = 432，中心 438。
    Future<double> caretCenter(double anchor) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 40),
              child: ResultUpwardTray(
                anchorCenterX: anchor,
                children: [
                  for (var i = 0; i < 16; i++)
                    const SizedBox(width: 28, height: 28),
                ],
              ),
            ),
          ),
        ),
      );
      final caret = find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.size == const Size(12, 4),
      );
      return tester.getCenter(caret).dx;
    }

    expect(await caretCenter(430), 430);
    expect(await caretCenter(600), 438);
  });
}
