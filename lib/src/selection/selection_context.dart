import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../common/constants/method_names.dart';
import '../common/constants/selection_gesture_types.dart';

abstract final class SelectionContext {
  static const invisibleCharacters = {'​', '‌', '‍', '﻿', '­'};

  static const listMarkerCharacters = {
    '•',
    '◦',
    '▪',
    '▫',
    '‣',
    '⁃',
    '●',
    '○',
    '■',
    '□',
  };

  static const _whitespace = {
    0x09,
    0x0A,
    0x0B,
    0x0C,
    0x0D,
    0x20,
    0x85,
    0xA0,
    0x1680,
    0x2000,
    0x2001,
    0x2002,
    0x2003,
    0x2004,
    0x2005,
    0x2006,
    0x2007,
    0x2008,
    0x2009,
    0x200A,
    0x2028,
    0x2029,
    0x202F,
    0x205F,
    0x3000,
  };

  static bool shouldCopy({
    required List<String> context,
    required String? text,
    required bool allowCopy,
  }) =>
      allowCopy &&
      !context.contains(SelectionContextKinds.nonText) &&
      (text == null ||
          !_hasContent(text) ||
          context.contains(SelectionContextKinds.web) ||
          _hasInlineListMarker(text));

  static bool acceptsCopied({
    required List<String> context,
    required String? text,
    required String copied,
  }) {
    if (!_hasContent(copied)) return false;
    if (text == null || context.contains(SelectionContextKinds.web)) {
      return true;
    }
    return matchesCopiedSelection(text, copied);
  }

  static bool matchesCopiedSelection(String text, String copied) {
    final strippedText = _strip(text);
    final strippedCopied = _strip(copied);
    if (strippedCopied.isEmpty) return false;
    if (listEquals(strippedText, strippedCopied)) return true;
    final normalizedText = _withoutMarkers(strippedText);
    final normalizedCopied = _withoutMarkers(strippedCopied);
    if (normalizedText.isEmpty || normalizedCopied.isEmpty) return false;
    if (listEquals(normalizedText, normalizedCopied)) return true;
    final (shorter, longer) = normalizedText.length <= normalizedCopied.length
        ? (normalizedText, normalizedCopied)
        : (normalizedCopied, normalizedText);
    if (shorter.length * 2 < longer.length) return false;
    var index = 0;
    for (final character in shorter) {
      final found = longer.indexOf(character, index);
      if (found < 0) return false;
      index = found + 1;
    }
    return true;
  }

  static bool _hasInlineListMarker(String text) {
    var afterContent = false;
    for (final character in text.characters) {
      if (character == '\n' || character == '\r') {
        afterContent = false;
      } else if (afterContent && listMarkerCharacters.contains(character)) {
        return true;
      } else if (!_isWhitespace(character)) {
        afterContent = true;
      }
    }
    return false;
  }

  static bool _hasContent(String text) =>
      text.characters.any((character) => !_isWhitespace(character));

  static bool _isWhitespace(String character) =>
      _whitespace.contains(character.runes.first);

  static List<String> _strip(String text) => [
    for (final character in text.characters)
      if (!_isWhitespace(character) && !invisibleCharacters.contains(character))
        character,
  ];

  static List<String> _withoutMarkers(List<String> characters) => [
    for (final character in characters)
      if (!listMarkerCharacters.contains(character)) character,
  ];
}

bool handleSelectionContextRequest(MethodCall call) {
  final arguments = Map<Object?, Object?>.from(call.arguments as Map);
  final context = (arguments['context'] as List).cast<String>();
  final text = arguments['text'] as String?;
  return switch (call.method) {
    MethodNames.shouldCopySelection => SelectionContext.shouldCopy(
      context: context,
      text: text,
      allowCopy: arguments['allowCopy'] as bool,
    ),
    MethodNames.acceptsCopiedSelection => SelectionContext.acceptsCopied(
      context: context,
      text: text,
      copied: arguments['copied'] as String,
    ),
    _ => throw MissingPluginException('未知选区规则：${call.method}'),
  };
}
