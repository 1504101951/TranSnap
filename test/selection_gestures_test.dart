import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/selection_gesture_types.dart';
import 'package:transnap/src/selection/selection_gestures.dart';

void main() {
  String? click(
    SelectionGestureDetector detector, {
    required (double, double) from,
    required (double, double) to,
    int clickCount = 1,
  }) {
    expect(
      detector.pointer(
        kind: SelectionPointerKinds.down,
        clickCount: clickCount,
        x: from.$1,
        y: from.$2,
      ),
      isNull,
    );
    return detector.pointer(
      kind: SelectionPointerKinds.up,
      clickCount: clickCount,
      x: to.$1,
      y: to.$2,
    );
  }

  test('按下到抬起的位移以 4pt 为界：不小于 4pt 为拖选，小于 4pt 按点击次数判定', () {
    final detector = SelectionGestureDetector();
    expect(
      click(detector, from: (10, 10), to: (14, 10)),
      SelectionGestureTypes.drag,
    );
    expect(
      click(detector, from: (10, 10), to: (10, 6)),
      SelectionGestureTypes.drag,
    );
    expect(click(detector, from: (10, 10), to: (13.99, 10)), isNull);
    expect(
      click(detector, from: (10, 10), to: (10, 10), clickCount: 2),
      SelectionGestureTypes.doubleClick,
    );
    expect(
      click(detector, from: (10, 10), to: (11, 11), clickCount: 3),
      SelectionGestureTypes.tripleClick,
    );
    expect(
      click(detector, from: (10, 10), to: (10, 10), clickCount: 4),
      SelectionGestureTypes.tripleClick,
    );
  });

  test('抬起后清除按下位置，没有对应按下的抬起只按点击次数判定', () {
    final detector = SelectionGestureDetector();
    expect(click(detector, from: (0, 0), to: (1, 0)), isNull);
    expect(
      detector.pointer(
        kind: SelectionPointerKinds.up,
        clickCount: 1,
        x: 100,
        y: 100,
      ),
      isNull,
    );
    expect(
      detector.pointer(
        kind: SelectionPointerKinds.up,
        clickCount: 2,
        x: 100,
        y: 100,
      ),
      SelectionGestureTypes.doubleClick,
    );
  });

  test('键盘：平台全选组合为全选手势，Shift 搭配导航键为键盘选区，其余按键不是选区手势', () {
    expect(
      SelectionGestureDetector.keyboard(SelectionKeys.selectAll, ['meta']),
      SelectionGestureTypes.selectAll,
    );
    for (final key in SelectionKeys.navigation) {
      expect(
        SelectionGestureDetector.keyboard(key, ['shift']),
        SelectionGestureTypes.keyboard,
      );
      expect(
        SelectionGestureDetector.keyboard(key, ['shift', 'alt']),
        SelectionGestureTypes.keyboard,
      );
      expect(SelectionGestureDetector.keyboard(key, []), isNull);
    }
    expect(
      SelectionGestureDetector.keyboard('KeyA', ['meta', 'shift']),
      isNull,
    );
    expect(SelectionGestureDetector.keyboard('KeyA', ['shift']), isNull);
    expect(SelectionGestureDetector.keyboard('KeyC', ['meta']), isNull);
  });

  test('原生请求按方法名分发：指针事件经同一识别器保留按下位置，按键直接判定，未知方法报错', () {
    final detector = SelectionGestureDetector();
    MethodCall pointer(String kind, double x) => MethodCall(
      MethodNames.selectionPointer,
      {'kind': kind, 'clickCount': 1, 'x': x, 'y': 0},
    );
    expect(detector.handle(pointer(SelectionPointerKinds.down, 0)), isNull);
    expect(
      detector.handle(pointer(SelectionPointerKinds.up, 20)),
      SelectionGestureTypes.drag,
    );
    expect(
      detector.handle(
        const MethodCall(MethodNames.selectionKey, {
          'key': 'ArrowLeft',
          'modifiers': ['shift'],
        }),
      ),
      SelectionGestureTypes.keyboard,
    );
    expect(
      () => detector.handle(const MethodCall('unknown', {})),
      throwsA(isA<MissingPluginException>()),
    );
  });
}
