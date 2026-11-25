import 'package:transnap/src/common/constants/selection_gesture_types.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/bridge_event_types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/platform/platform_event.dart';

void main() {
  test('parses selectionCaptured with sessionId', () {
    final event = PlatformEvent.fromMap({
      'type': BridgeEventTypes.selectionCaptured,
      'sessionId': 's1',
      'text': 'hello',
      'gesture': SelectionGestureTypes.drag,
      'x': 10,
      'y': 20,
    });
    expect(event, isA<SelectionCaptured>());
    final captured = event as SelectionCaptured;
    expect(captured.sessionId, 's1');
    expect(captured.text, 'hello');
    expect(captured.gesture, SelectionGestureTypes.drag);
    expect(captured.x, 10);
    expect(captured.y, 20);
  });

  test('parses escapePressed', () {
    final event = PlatformEvent.fromMap({
      'type': MethodNames.escapePressed,
      'sessionId': 's2',
    });
    expect(event, isA<EscapePressed>());
    expect(event.sessionId, 's2');
  });
}
