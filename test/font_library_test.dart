import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/error_codes.dart';
import 'package:transnap/src/common/constants/font_sets.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/fonts/font_library.dart';
import 'package:transnap/src/fonts/font_state.dart';

const _fixture = 'test/support/fonts/AtkinsonHyperlegibleNext.ttf';

class _Harness {
  _Harness(this.directory, Uri base, {this._selected = FontSet.neutral}) {
    library = FontLibrary(
      directory: directory,
      publish: (state) async {
        raw.add(state);
        published.add(FontState.fromMap(state));
      },
      select: (set) async {
        selections.add(set);
        _selected = set;
      },
      selected: () => _selected,
      locate: (file) => base.resolve(file.fileName),
    );
  }

  final Directory directory;
  late final FontLibrary library;
  final published = <FontState>[];
  final raw = <Map<String, Object>>[];
  final selections = <FontSet>[];
  FontSet _selected;

  File file(FontFile font) => File('${directory.path}/${font.fileName}');
}

void main() {
  late Directory directory;
  late HttpServer server;
  late Uri base;
  var corrupt = false;
  Completer<void>? stall;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('font-library-');
    corrupt = false;
    stall = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}/');
    server.listen((request) async {
      final name = request.uri.pathSegments.last;
      if (name != FontFile.atkinsonHyperlegibleNext.fileName) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final bytes = File(_fixture).readAsBytesSync();
      if (corrupt) bytes[bytes.length ~/ 2] ^= 0xFF;
      request.response.contentLength = bytes.length;
      request.response.add(bytes.sublist(0, bytes.length ~/ 2));
      await request.response.flush();
      if (stall != null) await stall!.future;
      request.response.add(bytes.sublist(bytes.length ~/ 2));
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    directory.deleteSync(recursive: true);
  });

  test('下载只取缺失的文件，过程发布百分比，校验通过后原子移入并切换到该组合', () async {
    final harness = _Harness(directory, base);
    await harness.library.start();
    final result = await harness.library.handle(
      const MethodCall(MethodNames.downloadFontSet, 'legible'),
    );
    expect(result, isTrue);
    expect(harness.selections, [FontSet.legible]);
    expect(
      harness.file(FontFile.atkinsonHyperlegibleNext).lengthSync(),
      FontFile.atkinsonHyperlegibleNext.bytes,
    );
    expect(
      directory.listSync().where((e) => e.path.endsWith('.part')),
      isEmpty,
    );
    final progress = [for (final state in harness.published) ?state.download];
    expect(progress.first.received, 0);
    expect(progress.first.total, FontFile.atkinsonHyperlegibleNext.bytes);
    expect(progress.last.received, lessThanOrEqualTo(progress.first.total));
    expect(harness.published.last.download, isNull);
    expect(harness.published.last.downloaded, {
      FontFile.atkinsonHyperlegibleNext,
    });
  });

  test('内容校验不符时删除临时文件、保留当前组合并报校验失败', () async {
    corrupt = true;
    final harness = _Harness(directory, base);
    await harness.library.start();
    await expectLater(
      harness.library.download(FontSet.legible),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          ErrorCodes.fontChecksum,
        ),
      ),
    );
    expect(directory.listSync(), isEmpty);
    expect(harness.selections, isEmpty);
    expect(harness.library.state, const FontState());
  });

  test('文件不存在于下载源时报下载失败，可重试', () async {
    final harness = _Harness(directory, base);
    await harness.library.start();
    await expectLater(
      harness.library.download(FontSet.geometric),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          ErrorCodes.fontDownload,
        ),
      ),
    );
    expect(directory.listSync(), isEmpty);
    expect(harness.library.state.download, isNull);
  });

  test('下载中取消：删除临时文件、不切换组合，同时只允许一个下载', () async {
    stall = Completer<void>();
    final harness = _Harness(directory, base);
    await harness.library.start();
    final pending = harness.library.download(FontSet.legible);
    while (harness.library.state.download?.received == 0 ||
        harness.library.state.download == null) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await expectLater(
      harness.library.download(FontSet.geometric),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          ErrorCodes.fontBusy,
        ),
      ),
    );
    harness.library.cancel();
    expect(await pending, isFalse);
    stall!.complete();
    expect(directory.listSync(), isEmpty);
    expect(harness.selections, isEmpty);
    expect(harness.library.state, const FontState());
  });

  test('卸载正在使用的组合先切回中性，只删除不被其他已下载组合需要的文件', () async {
    File(_fixture).copySync(
      '${directory.path}/${FontFile.atkinsonHyperlegibleNext.fileName}',
    );
    File(_fixture).copySync('${directory.path}/${FontFile.geist.fileName}');
    final harness = _Harness(directory, base, selected: FontSet.legible);
    await harness.library.start();
    expect(harness.library.state.downloaded, {
      FontFile.atkinsonHyperlegibleNext,
      FontFile.geist,
    });
    await harness.library.handle(
      const MethodCall(MethodNames.uninstallFontSet, 'legible'),
    );
    expect(harness.selections, [FontSet.neutral]);
    expect(
      harness.file(FontFile.atkinsonHyperlegibleNext).existsSync(),
      isFalse,
    );
    expect(harness.file(FontFile.geist).existsSync(), isTrue);
    expect(harness.library.state.downloaded, {FontFile.geist});
  });

  test('启动时所选组合的文件校验不符：删除该文件、标为未下载并切回中性；残留临时文件被清理', () async {
    File(_fixture).copySync('${directory.path}/${FontFile.geist.fileName}');
    File('${directory.path}/Geist.ttf.part').writeAsStringSync('partial');
    final harness = _Harness(directory, base, selected: FontSet.geometric);
    await harness.library.start();
    expect(harness.file(FontFile.geist).existsSync(), isFalse);
    expect(directory.listSync(), isEmpty);
    expect(harness.library.state.downloaded, isEmpty);
    expect(harness.selections, [FontSet.neutral]);
  });

  test('启动时所选组合文件完整且校验通过时保持不变', () async {
    File(_fixture).copySync(
      '${directory.path}/${FontFile.atkinsonHyperlegibleNext.fileName}',
    );
    final harness = _Harness(directory, base, selected: FontSet.legible);
    await harness.library.start();
    expect(harness.selections, isEmpty);
    expect(harness.library.state.downloaded, {
      FontFile.atkinsonHyperlegibleNext,
    });
  });

  test('发布的状态附带所选组合三个角色的文件：内置文件给资源键，下载文件给字体目录路径', () async {
    final harness = _Harness(directory, base, selected: FontSet.claude);
    await harness.library.noteSelection(FontSet.character);
    expect(harness.raw.last['roles'], {
      'ui': {
        'latin': '${directory.path}/SpaceGrotesk.ttf',
        'cjk': 'asset:assets/fonts/NotoSansSC.ttf',
      },
      'body': {
        'latin': '${directory.path}/SpaceGrotesk.ttf',
        'cjk': 'asset:assets/fonts/NotoSansSC.ttf',
      },
      'title': {
        'latin': '${directory.path}/SpaceGrotesk.ttf',
        'cjk': '${directory.path}/SmileySans-Oblique.ttf',
      },
    });
  });
}
