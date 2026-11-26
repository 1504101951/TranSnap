import 'dart:io';

import 'package:transnap/src/common/constants/font_sets.dart';

const _dropInstanceNames = '''
import sys
from fontTools.ttLib import TTFont
font = TTFont(sys.argv[1])
if "fvar" in font:
    ids = {i.postscriptNameID for i in font["fvar"].instances}
    for instance in font["fvar"].instances:
        instance.postscriptNameID = 0xFFFF
    font["name"].names = [n for n in font["name"].names if n.nameID not in ids]
font.save(sys.argv[1])
''';

Future<void> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode == 0) return;
  stderr.write(result.stderr);
  exit(result.exitCode);
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      '用法：dart run scripts/generate_font_subsets.dart <字体文件目录> <装有 fonttools 的 python>',
    );
    exit(64);
  }
  final [source, python] = arguments;
  final output = Directory('${FontFile.bundledDirectory}/names')
    ..createSync(recursive: true);
  for (final set in FontSet.values) {
    for (final (file, text, target) in [
      (set.ui.latin, '${set.label}${set.composition}', set.name),
      (set.title.cjk, set.label, '${set.name}-title'),
      (set.ui.cjk, set.composition, '${set.name}-text'),
    ]) {
      final path = '${output.path}/$target.ttf';
      await _run(python, [
        '-I',
        '-m',
        'fontTools.subset',
        '$source/${file.fileName}',
        '--text=$text',
        '--name-IDs=0,13,14',
        '--output-file=$path',
      ]);
      await _run(python, ['-I', '-c', _dropInstanceNames, path]);
    }
  }
  for (final file in FontFile.bundled) {
    File('$source/${file.fileName}')
        .copySync('${FontFile.bundledDirectory}/${file.fileName}');
  }
}
