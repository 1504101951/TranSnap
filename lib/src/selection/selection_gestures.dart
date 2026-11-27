import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../common/constants/method_names.dart';
import '../common/constants/selection_gesture_types.dart';
import '../common/constants/shortcut_keys.dart';

class SelectionGestureDetector {
  static const dragThreshold = 4.0;

  ({double x, double y})? _origin;

  String? pointer({
    required String kind,
    required int clickCount,
    required double x,
    required double y,
  }) {
    if (kind == SelectionPointerKinds.down) {
      _origin = (x: x, y: y);
      return null;
    }
    final origin = _origin;
    _origin = null;
    if (origin != null &&
        math.sqrt(math.pow(x - origin.x, 2) + math.pow(y - origin.y, 2)) >=
            dragThreshold) {
      return SelectionGestureTypes.drag;
    }
    if (clickCount == 2) return SelectionGestureTypes.doubleClick;
    if (clickCount >= 3) return SelectionGestureTypes.tripleClick;
    return null;
  }

  static String? keyboard(String key, List<String> modifiers) {
    if (key == SelectionKeys.selectAll) return SelectionGestureTypes.selectAll;
    final shift = ShortcutModifiers.names[ShortcutModifiers.shift];
    return modifiers.contains(shift) && SelectionKeys.navigation.contains(key)
        ? SelectionGestureTypes.keyboard
        : null;
  }

  String? handle(MethodCall call) {
    final arguments = Map<Object?, Object?>.from(call.arguments as Map);
    return switch (call.method) {
      MethodNames.selectionPointer => pointer(
        kind: arguments['kind'] as String,
        clickCount: arguments['clickCount'] as int,
        x: (arguments['x'] as num).toDouble(),
        y: (arguments['y'] as num).toDouble(),
      ),
      MethodNames.selectionKey => keyboard(
        arguments['key'] as String,
        (arguments['modifiers'] as List).cast<String>(),
      ),
      _ => throw MissingPluginException('未知选区手势：${call.method}'),
    };
  }
}
