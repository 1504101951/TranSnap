#!/usr/bin/env python3
"""无参数；扫描 lib 中用到的 LucideIcons 图标，生成 lib/src/common/constants/line_icon_weights.dart。

该文件为每个用到的图标列出 200/300/500/600 字重的常量 IconData，供 LineIcon 按显示尺寸选字重，
使屏幕线宽接近 1.6pt（#67）。必须用常量引用：Release 构建的图标裁剪只保留常量 IconData 用到的字形。
新增或改用图标后重新运行本脚本；未收录的图标由 LineIcon 回退为常规字重（线宽 2/24）。
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / 'lib/src/common/constants/line_icon_weights.dart'
WEIGHTS = (200, 300, 500, 600)


def package_dir() -> pathlib.Path:
    """无参数；返回 pubspec.lock 锁定版本的 lucide_icons_flutter 包目录。"""
    lock = (ROOT / 'pubspec.lock').read_text(encoding='utf-8')
    version = re.search(r'lucide_icons_flutter:.*?version: "([^"]+)"', lock, re.S).group(1)
    return pathlib.Path.home() / f'.pub-cache/hosted/pub.dev/lucide_icons_flutter-{version}'


def main() -> None:
    """无参数；读取用到的图标名与码位，写出 Dart 常量表。"""
    names = sorted({
        name
        for path in (ROOT / 'lib').rglob('*.dart')
        if path != OUT
        for name in re.findall(r'LucideIcons\.([A-Za-z0-9_]+)', path.read_text(encoding='utf-8'))
    })
    source = (package_dir() / 'lib/lucide_icons.dart').read_text(encoding='utf-8')
    codepoints = dict(re.findall(r'static const IconData (\w+) = const IconData\((\d+),', source))
    lines = [
        '// 由 scripts/generate-line-icon-weights.py 生成，请勿手改；新增或改用图标后重新运行该脚本。',
        "import 'package:flutter/widgets.dart';",
        "import 'package:lucide_icons_flutter/lucide_icons_weights.dart';",
        '',
        '/// 用到的 Lucide 图标在 200/300/500/600 字重下的常量（键为常规字重码位，#67）；',
        '/// 字重对应 24 单位线宽 1/1.55/2.5/3，由 LineIcon 按显示尺寸选用。',
        'abstract final class LineIconWeights {',
        '  /// 字重到「码位 → 该字重图标」的表。',
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
