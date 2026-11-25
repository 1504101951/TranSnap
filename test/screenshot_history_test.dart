import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:transnap/src/history/screenshot_history.dart';

Uint8List fakePng(int width, int height) {
  final data = ByteData(33);
  for (final (index, byte) in [137, 80, 78, 71, 13, 10, 26, 10].indexed) {
    data.setUint8(index, byte);
  }
  data.setUint32(8, 13);
  data.setUint32(16, width);
  data.setUint32(20, height);
  return data.buffer.asUint8List();
}

void main() {
  late Directory directory;
  late ScreenshotHistoryStore store;
  const day = 24 * 60 * 60 * 1000;
  const now = 100 * day;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('screenshot-history-');
    store = ScreenshotHistoryStore(
      sqlite3.openInMemory(),
      Directory('${directory.path}/ScreenshotHistory'),
    );
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('默认不记录；开启后写入图片与尺寸，同一截图再次导出只保留最后一次', () async {
    await store.record(
      captureId: 'a',
      png: fakePng(10, 20),
      capturedAt: now,
      now: now,
    );
    expect(store.list(), isEmpty);
    store.recordingEnabled = true;
    await store.record(
      captureId: 'a',
      png: fakePng(10, 20),
      capturedAt: now,
      now: now,
    );
    await store.record(
      captureId: 'a',
      png: fakePng(30, 40),
      capturedAt: now,
      now: now,
    );
    final records = store.list();
    expect(records, hasLength(1));
    expect((records.single.width, records.single.height), (30, 40));
    expect(records.single.exists, isTrue);
    expect(File(records.single.path).readAsBytesSync(), fakePng(30, 40));
  });

  test('同一截图连续导出不等待前一次写完时，按到达顺序串行，保留最后一次', () async {
    store.recordingEnabled = true;
    final first = store.record(
      captureId: 'a',
      png: fakePng(10, 20),
      capturedAt: now,
      now: now,
    );
    final second = store.record(
      captureId: 'a',
      png: fakePng(30, 40),
      capturedAt: now,
      now: now,
    );
    await Future.wait([first, second]);
    final records = store.list();
    expect(records, hasLength(1));
    expect((records.single.width, records.single.height), (30, 40));
    expect(File(records.single.path).readAsBytesSync(), fakePng(30, 40));
  });

  test('超过 100 条删除最早的记录及图片，超过 30 天的记录在下次写入时删除', () async {
    store.recordingEnabled = true;
    await store.record(
      captureId: 'old',
      png: fakePng(1, 1),
      capturedAt: now - 30 * day - 1,
      now: now - 30 * day,
    );
    await store.record(
      captureId: 'edge',
      png: fakePng(1, 1),
      capturedAt: now - 30 * day,
      now: now - 30 * day,
    );
    await store.record(
      captureId: 'fresh',
      png: fakePng(1, 1),
      capturedAt: now,
      now: now,
    );
    final paths = store.list().map((r) => r.path).toList();
    expect(paths.map((p) => p.split('/').last), ['fresh.png', 'edge.png']);
    expect(File('${store.directory.path}/old.png').existsSync(), isFalse);
    for (var i = 0; i < 100; i++) {
      await store.record(
        captureId: 'n$i',
        png: fakePng(1, 1),
        capturedAt: now + i + 1,
        now: now + i + 1,
      );
    }
    final kept = store.list();
    expect(kept, hasLength(100));
    expect(kept.last.path.split('/').last, 'n0.png');
    expect(File('${store.directory.path}/edge.png').existsSync(), isFalse);
    expect(File('${store.directory.path}/fresh.png').existsSync(), isFalse);
  });

  test('图片被移走时标记缺失仍可删除；清空删除全部历史图片', () async {
    store.recordingEnabled = true;
    await store.record(captureId: 'a', png: fakePng(1, 1), capturedAt: now, now: now);
    await store.record(
      captureId: 'b',
      png: fakePng(1, 1),
      capturedAt: now + 1,
      now: now + 1,
    );
    final missing = store.list().last;
    File(missing.path).deleteSync();
    expect(store.list().last.exists, isFalse);
    await store.delete(missing.id);
    expect(store.list().map((r) => r.path.split('/').last), ['b.png']);
    await store.clear();
    expect(store.list(), isEmpty);
    expect(store.directory.listSync().whereType<File>(), isEmpty);
  });

  test('拼接与拆分结果不受记录开关限制，按给定顺序从上到下排列且身份不重复', () async {
    await store.add([fakePng(1, 10), fakePng(2, 10), fakePng(3, 10)], now);
    expect([for (final record in store.list()) record.width], [1, 2, 3]);
    await store.add([fakePng(4, 10)], now);
    expect(store.list(), hasLength(4));
    expect(store.list().first.width, 4);
    expect(store.list().every((record) => record.exists), isTrue);

    await store.clear();
    store.recordingEnabled = true;
    for (var i = 0; i < 99; i++) {
      await store.record(
        captureId: 'old-$i',
        png: fakePng(100 + i, 1),
        capturedAt: now - 1000 + i,
        now: now,
      );
    }
    await store.add([fakePng(1, 1), fakePng(2, 1), fakePng(3, 1)], now);
    final widths = [for (final record in store.list()) record.width];
    expect(widths, hasLength(100));
    expect(widths.take(3), [1, 2, 3]);
    expect(widths, isNot(contains(100)));
    expect(widths, isNot(contains(101)));
    expect(widths.last, 102);
  });
}
