import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 设置侧边栏中指定名称的行；label 为行文字。侧边栏之外的子页标题同名，所以限定在侧边栏内查找。
Finder settingsSidebarRow(String label) => find.descendant(
  of: find.byKey(const ValueKey('settings-sidebar')),
  matching: find.text(label),
);

/// 设置右侧子页内容的滚动列表；侧边栏的列表先于它构建，所以取最后一个。
Finder settingsContentList() => find.byType(ListView).last;

/// 设置右侧子页内容的滚动视口，供 scrollUntilVisible 使用。
Finder settingsContentScrollable() => find
    .descendant(of: settingsContentList(), matching: find.byType(Scrollable))
    .first;

/// 点选侧边栏的指定行并等待切换完成；tester 为测试驱动，label 为侧边栏行文字，无返回值。
Future<void> openSettingsPage(WidgetTester tester, String label) async {
  await tester.tap(settingsSidebarRow(label));
  await tester.pumpAndSettle();
}

/// 设置页通用子页的语言包状态查询（MethodNames.checkSystemTranslation）在测试通道中的默认返回值。
const languagePackInstalledStatus = '语言包已安装：English → 简体中文';
