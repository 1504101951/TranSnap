import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../common/constants/error_codes.dart';
import '../common/constants/font_sets.dart';
import '../common/constants/method_names.dart';
import 'font_state.dart';

class FontLibrary {
  FontLibrary({
    required this.directory,
    required this.publish,
    required this.select,
    required this.selected,
    Uri Function(FontFile file)? locate,
  }) : locate = locate ?? ((file) => Uri.parse(file.url));

  final Directory directory;
  final Future<void> Function(Map<String, Object> state) publish;
  final Future<void> Function(FontSet set) select;
  final FontSet Function() selected;
  final Uri Function(FontFile file) locate;

  FontState _state = const FontState();
  HttpClient? _client;
  bool _cancelled = false;

  FontState get state => _state;

  String _path(FontFile file) => '${directory.path}/${file.fileName}';

  Future<void> _set(FontState state) async {
    _state = state;
    await publish(state.toMap());
  }

  Future<void> start() async {
    directory.createSync(recursive: true);
    final known = {
      for (final file in FontFile.values)
        if (!file.isBundled) file.fileName: file,
    };
    final downloaded = <FontFile>{};
    for (final entity in directory.listSync()) {
      final name = entity.uri.pathSegments.last;
      final file = known[name];
      if (file != null) {
        downloaded.add(file);
      } else if (name.endsWith('.part')) {
        entity.deleteSync();
      }
    }
    final current = selected();
    for (final file in current.files.intersection(downloaded)) {
      if (await _verify(file)) continue;
      File(_path(file)).deleteSync();
      downloaded.remove(file);
    }
    await _set(FontState(downloaded: downloaded));
    if (!_state.isAvailable(current)) await select(FontSet.fallback);
  }

  Future<bool> _verify(FontFile file) {
    final path = _path(file);
    return Isolate.run(() async {
      final source = File(path);
      if (source.lengthSync() != file.bytes) return false;
      return (await sha256.bind(source.openRead()).first).toString() ==
          file.sha256;
    });
  }

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case MethodNames.downloadFontSet:
        return download(FontSet.values.byName(call.arguments as String));
      case MethodNames.cancelFontDownload:
        cancel();
        return null;
      case MethodNames.uninstallFontSet:
        await uninstall(FontSet.values.byName(call.arguments as String));
        return null;
    }
    throw MissingPluginException('未知字体操作：${call.method}');
  }

  Future<bool> download(FontSet set) async {
    if (_state.download != null) {
      throw PlatformException(
        code: ErrorCodes.fontBusy,
        message: '已有字体正在下载，请等它完成或取消后再试。',
      );
    }
    final missing = [
      for (final file in set.files)
        if (!_state.has(file)) file,
    ];
    final total = missing.fold(0, (sum, file) => sum + file.bytes);
    var received = 0;
    var percent = 0;
    _cancelled = false;
    await _set(
      FontState(
        downloaded: _state.downloaded,
        download: (set: set, received: 0, total: total),
      ),
    );
    try {
      for (final file in missing) {
        final fetched = await _fetch(file, (count) {
          received += count;
          final next = received * 100 ~/ total;
          if (next == percent) return;
          percent = next;
          _state = FontState(
            downloaded: _state.downloaded,
            download: (set: set, received: received, total: total),
          );
          publish(_state.toMap());
        });
        if (!fetched) return false;
        _state = FontState(
          downloaded: {..._state.downloaded, file},
          download: _state.download,
        );
      }
    } finally {
      await _set(FontState(downloaded: _state.downloaded));
    }
    await select(set);
    return true;
  }

  Future<bool> _fetch(FontFile file, void Function(int count) onChunk) async {
    final part = File('${_path(file)}.part');
    final client = _client = HttpClient();
    final digests = <Digest>[];
    final hasher = sha256.startChunkedConversion(
      ChunkedConversionSink.withCallback(digests.addAll),
    );
    var count = 0;
    try {
      final response = await (await client.getUrl(locate(file))).close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final sink = part.openWrite();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          hasher.add(chunk);
          count += chunk.length;
          onChunk(chunk.length);
        }
      } finally {
        await sink.close();
      }
    } on IOException catch (error) {
      if (part.existsSync()) part.deleteSync();
      if (_cancelled) return false;
      throw PlatformException(
        code: ErrorCodes.fontDownload,
        message: '「${file.fileName}」下载失败（$error），可重试。',
      );
    } finally {
      client.close(force: true);
      _client = null;
    }
    if (_cancelled) {
      part.deleteSync();
      return false;
    }
    hasher.close();
    if (count != file.bytes || digests.single.toString() != file.sha256) {
      part.deleteSync();
      throw PlatformException(
        code: ErrorCodes.fontChecksum,
        message: '「${file.fileName}」校验失败，已删除下载内容，可重试。',
      );
    }
    part.renameSync(_path(file));
    return true;
  }

  void cancel() {
    _cancelled = true;
    _client?.close(force: true);
  }

  Future<void> uninstall(FontSet set) async {
    if (selected() == set) await select(FontSet.fallback);
    final kept = {
      for (final other in FontSet.values)
        if (other != set && _state.isAvailable(other)) ...other.files,
    };
    final removed = set.files
        .difference(kept)
        .where((file) => !file.isBundled)
        .toSet();
    for (final file in removed) {
      final target = File(_path(file));
      if (target.existsSync()) target.deleteSync();
    }
    await _set(FontState(downloaded: _state.downloaded.difference(removed)));
  }
}
