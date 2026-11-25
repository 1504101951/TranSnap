import 'dart:io';

import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';

import '../common/constants/method_names.dart';

class ScreenshotRecord {
  const ScreenshotRecord({
    required this.id,
    required this.path,
    required this.width,
    required this.height,
    required this.capturedAt,
    required this.exists,
  });

  factory ScreenshotRecord.fromMap(Map<Object?, Object?> map) =>
      ScreenshotRecord(
        id: map['id'] as int,
        path: map['path'] as String,
        width: map['width'] as int,
        height: map['height'] as int,
        capturedAt: map['capturedAt'] as int,
        exists: map['exists'] as bool,
      );

  final int id;
  final String path;
  final int width;
  final int height;
  final int capturedAt;
  final bool exists;

  Map<String, Object> toMap() => {
    'id': id,
    'path': path,
    'width': width,
    'height': height,
    'capturedAt': capturedAt,
    'exists': exists,
  };
}

class ScreenshotHistoryStore {
  ScreenshotHistoryStore(this.database, this.directory, {this.onChanged}) {
    database.execute('''
CREATE TABLE IF NOT EXISTS screenshot_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  capture_id TEXT NOT NULL UNIQUE,
  file_name TEXT NOT NULL,
  width INTEGER NOT NULL,
  height INTEGER NOT NULL,
  captured_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS history_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''');
    database.execute('''
INSERT INTO history_meta(key, value) VALUES('screenshotRecording', '0')
ON CONFLICT(key) DO NOTHING
''');
  }

  static const maxEntries = 100;

  static const retention = Duration(days: 30);

  final Database database;
  final Directory directory;

  int _composed = 0;

  final void Function()? onChanged;

  Future<void> _changes = Future<void>.value();

  Future<void> _serial(Future<void> Function() change) {
    final next = _changes.then((_) => change());
    _changes = next.catchError((_) {});
    return next;
  }

  bool get recordingEnabled =>
      database
          .select(
            "SELECT value FROM history_meta WHERE key = 'screenshotRecording'",
          )
          .first['value'] ==
      '1';

  set recordingEnabled(bool value) {
    database.execute(
      "INSERT INTO history_meta(key, value) VALUES('screenshotRecording', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [value ? '1' : '0'],
    );
  }

  Future<void> record({
    required String captureId,
    required Uint8List png,
    required int capturedAt,
    required int now,
  }) => _serial(() async {
    if (!recordingEnabled) return;
    await _write(captureId, png, capturedAt);
    await _prune(now);
    onChanged?.call();
  });

  Future<void> add(List<Uint8List> images, int now) => _serial(() async {
    for (final png in images.reversed) {
      _composed += 1;
      await _write('composed-$now-$_composed', png, now);
    }
    await _prune(now);
    onChanged?.call();
  });

  Future<void> _write(String captureId, Uint8List png, int capturedAt) async {
    final (width, height) = pngSize(png);
    await directory.create(recursive: true);
    final fileName = '$captureId.png';
    final temporary = await File(
      '${directory.path}/.$fileName.tmp',
    ).writeAsBytes(png, flush: true);
    await temporary.rename('${directory.path}/$fileName');
    database.execute(
      '''INSERT INTO screenshot_history(capture_id, file_name, width, height, captured_at) VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(capture_id) DO UPDATE SET width = excluded.width, height = excluded.height''',
      [captureId, fileName, width, height, capturedAt],
    );
  }

  List<ScreenshotRecord> list() => [
    for (final row in database.select(
      'SELECT id, file_name, width, height, captured_at FROM screenshot_history ORDER BY captured_at DESC, id DESC',
    ))
      ScreenshotRecord(
        id: row['id'] as int,
        path: '${directory.path}/${row['file_name']}',
        width: row['width'] as int,
        height: row['height'] as int,
        capturedAt: row['captured_at'] as int,
        exists: File('${directory.path}/${row['file_name']}').existsSync(),
      ),
  ];

  Future<void> delete(int id) => _serial(() async {
    await _remove(
      database.select(
        'SELECT id, file_name FROM screenshot_history WHERE id = ?',
        [id],
      ),
    );
    onChanged?.call();
  });

  Future<void> clear() => _serial(() async {
    await _remove(
      database.select('SELECT id, file_name FROM screenshot_history'),
    );
    onChanged?.call();
  });

  Future<void> _prune(int now) {
    return _remove(
      database.select(
        '''SELECT id, file_name FROM screenshot_history
           WHERE captured_at < ? OR id NOT IN (
             SELECT id FROM screenshot_history ORDER BY captured_at DESC, id DESC LIMIT ?
           )''',
        [now - retention.inMilliseconds, maxEntries],
      ),
    );
  }

  Future<void> _remove(ResultSet rows) async {
    for (final row in rows) {
      final file = File('${directory.path}/${row['file_name']}');
      if (await file.exists()) await file.delete();
      database.execute('DELETE FROM screenshot_history WHERE id = ?', [
        row['id'],
      ]);
    }
  }

  static (int, int) pngSize(Uint8List png) {
    final data = ByteData.sublistView(png);
    return (data.getUint32(16), data.getUint32(20));
  }
}

Future<Object?> handleScreenshotHistoryRequest(
  ScreenshotHistoryStore store,
  MethodCall call,
  int now,
) async {
  final map = Map<Object?, Object?>.from(call.arguments as Map? ?? const {});
  switch (call.method) {
    case MethodNames.recordScreenshotHistory:
      await store.record(
        captureId: map['id'] as String,
        png: map['bytes'] as Uint8List,
        capturedAt: map['capturedAt'] as int,
        now: now,
      );
      return null;
    case MethodNames.screenshotHistoryList:
      return [for (final record in store.list()) record.toMap()];
    case MethodNames.deleteScreenshotHistory:
      await store.delete(map['id'] as int);
      return null;
    case MethodNames.clearScreenshotHistory:
      await store.clear();
      return null;
    case MethodNames.screenshotHistoryRecording:
      return store.recordingEnabled;
    case MethodNames.setScreenshotHistoryRecording:
      store.recordingEnabled = map['enabled'] == true;
      return null;
    case MethodNames.addScreenshotHistory:
      await store.add([
        for (final png in map['images'] as List) png as Uint8List,
      ], now);
      return null;
    default:
      throw MissingPluginException('未知截图历史操作：${call.method}');
  }
}
