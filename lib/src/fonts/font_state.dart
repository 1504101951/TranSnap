import 'package:flutter/foundation.dart';

import '../common/constants/font_sets.dart';

typedef FontDownload = ({FontSet set, int received, int total});

@immutable
class FontState {
  const FontState({this.downloaded = const {}, this.download});

  final Set<FontFile> downloaded;
  final FontDownload? download;

  static final current = ValueNotifier(const FontState());

  bool has(FontFile file) => file.isBundled || downloaded.contains(file);

  bool isAvailable(FontSet set) => set.files.every(has);

  int missingBytes(FontSet set) => set.files
      .where((file) => !has(file))
      .fold(0, (sum, file) => sum + file.bytes);

  factory FontState.fromMap(Map<Object?, Object?> map) {
    final download = map['download'] as Map?;
    return FontState(
      downloaded: {
        for (final name in (map['downloaded'] as List? ?? const []))
          FontFile.values.byName(name as String),
      },
      download: download == null
          ? null
          : (
              set: FontSet.values.byName(download['set']! as String),
              received: download['received']! as int,
              total: download['total']! as int,
            ),
    );
  }

  Map<String, Object> toMap() => {
    'downloaded': [for (final file in downloaded) file.name],
    if (download case final download?)
      'download': {
        'set': download.set.name,
        'received': download.received,
        'total': download.total,
      },
  };

  @override
  bool operator ==(Object other) =>
      other is FontState &&
      setEquals(other.downloaded, downloaded) &&
      other.download == download;

  @override
  int get hashCode =>
      Object.hash(Object.hashAllUnordered(downloaded), download);
}
