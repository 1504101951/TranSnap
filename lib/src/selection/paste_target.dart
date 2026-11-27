import 'package:flutter/services.dart';

import '../common/constants/selection_gesture_types.dart';

abstract final class PasteTarget {
  static String decide({
    required bool hasFocus,
    required bool focusIsSelection,
    required bool focusIsTextInput,
    required bool focusIsSecure,
    int? candidates,
  }) {
    if (!hasFocus || focusIsSelection || focusIsTextInput && !focusIsSecure) {
      return PasteTargetActions.paste;
    }
    if (candidates == null) return PasteTargetActions.search;
    return candidates == 1
        ? PasteTargetActions.focusCandidate
        : PasteTargetActions.none;
  }

  static String handle(MethodCall call) {
    final facts = Map<Object?, Object?>.from(call.arguments as Map);
    return decide(
      hasFocus: facts['hasFocus'] as bool,
      focusIsSelection: facts['focusIsSelection'] as bool,
      focusIsTextInput: facts['focusIsTextInput'] as bool,
      focusIsSecure: facts['focusIsSecure'] as bool,
      candidates: facts['candidates'] as int?,
    );
  }
}
