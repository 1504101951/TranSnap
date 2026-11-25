import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/widgets/line_icon.dart';

/// 按常规字重图标查找 LineIcon；icon 为代码里写的 LucideIcons 常量。
/// LineIcon 按尺寸换用其他字重渲染，find.byIcon 看到的是换后的图标，所以按 LineIcon 自身的 icon 比较。
Finder findLineIcon(IconData icon) => find.byWidgetPredicate(
  (widget) => widget is LineIcon && widget.icon == icon,
  description: 'LineIcon $icon',
);
