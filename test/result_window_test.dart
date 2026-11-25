import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/widgets/result_window.dart';

void main() {
  testWidgets('上弹托盘三角在托盘实际宽度内对准锚点中心，超出时贴近末端（#67）', (tester) async {
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
