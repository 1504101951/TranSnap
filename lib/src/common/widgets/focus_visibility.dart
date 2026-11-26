import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

abstract final class FocusVisibility {
  static bool _fromKeyboard = false;
  static bool _routed = false;

  static bool get fromKeyboard => _fromKeyboard;

  static void install() {
    HardwareKeyboard.instance
      ..removeHandler(_handleKey)
      ..addHandler(_handleKey);
    if (_routed) return;
    _routed = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handlePointer);
  }

  static bool _handleKey(KeyEvent event) {
    if (event is KeyDownEvent) _fromKeyboard = true;
    return false;
  }

  static void _handlePointer(PointerEvent event) {
    if (event is PointerDownEvent) _fromKeyboard = false;
  }
}
