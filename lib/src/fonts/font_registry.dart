import 'dart:io';

import 'package:flutter/services.dart';

import '../common/constants/font_sets.dart';

abstract final class FontRegistry {
  static final _loaded = <FontFile>{...FontFile.bundled};

  static Future<bool> ensure(FontSet set, String directory) async {
    try {
      for (final file in set.files.difference(_loaded)) {
        final bytes = await File('$directory/${file.fileName}').readAsBytes();
        await (FontLoader(
          file.family,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        _loaded.add(file);
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
