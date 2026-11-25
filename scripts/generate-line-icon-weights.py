#!/usr/bin/env python3
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / 'lib/src/common/constants/line_icon_weights.dart'
WEIGHTS = (200, 300, 500, 600)


def package_dir() -> pathlib.Path:
    lock = (ROOT / 'pubspec.lock').read_text(encoding='utf-8')
    version = re.search(r'lucide_icons_flutter:.*?version: "([^"]+)"', lock, re.S).group(1)
    return pathlib.Path.home() / f'.pub-cache/hosted/pub.dev/lucide_icons_flutter-{version}'


def main() -> None:
    names = sorted({
        name
        for path in (ROOT / 'lib').rglob('*.dart')
        if path != OUT
        for name in re.findall(r'LucideIcons\.([A-Za-z0-9_]+)', path.read_text(encoding='utf-8'))
    })
    source = (package_dir() / 'lib/lucide_icons.dart').read_text(encoding='utf-8')
    codepoints = dict(re.findall(r'static const IconData (\w+) = const IconData\((\d+),', source))
    lines = [
        "import 'package:flutter/widgets.dart';",
        "import 'package:lucide_icons_flutter/lucide_icons_weights.dart';",
        '',
        'abstract final class LineIconWeights {',
        '  static const byWeight = <int, Map<int, IconData>>{',
    ]
    for weight in WEIGHTS:
        lines.append(f'    {weight}: {{')
        for name in names:
            if name in codepoints:
                lines.append(f'      {codepoints[name]}: LucideIcons{weight}.{name},')
        lines.append('    },')
    lines += ['  };', '}', '']
    OUT.write_text('\n'.join(lines), encoding='utf-8')


main()
