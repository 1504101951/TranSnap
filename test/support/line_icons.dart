import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/widgets/line_icon.dart';

Finder findLineIcon(IconData icon) => find.byWidgetPredicate(
  (widget) => widget is LineIcon && widget.icon == icon,
  description: 'LineIcon $icon',
);
