abstract final class SelectionGestureTypes {
  static const drag = 'drag';

  static const doubleClick = 'doubleClick';

  static const tripleClick = 'tripleClick';

  static const selectAll = 'selectAll';

  static const keyboard = 'keyboard';

  static const hotkey = 'hotkey';

  static const inputHotkey = 'inputHotkey';
}

abstract final class SelectionReadFailures {
  static const secureField = 'secureField';
}

abstract final class SelectionContextKinds {
  static const text = 'text';

  static const nonText = 'nonText';

  static const web = 'web';

  static const other = 'other';
}

abstract final class SelectionPointerKinds {
  static const down = 'down';

  static const up = 'up';
}

abstract final class SelectionKeys {
  static const selectAll = 'SelectAll';

  static const navigation = {
    'Home',
    'End',
    'PageUp',
    'PageDown',
    'ArrowLeft',
    'ArrowRight',
    'ArrowUp',
    'ArrowDown',
  };
}

abstract final class PasteTargetActions {
  static const paste = 'paste';

  static const search = 'search';

  static const focusCandidate = 'focusCandidate';

  static const none = 'none';
}
