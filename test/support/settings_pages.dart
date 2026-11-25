import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Finder settingsSidebarRow(String label) => find.descendant(
  of: find.byKey(const ValueKey('settings-sidebar')),
  matching: find.text(label),
);

Finder settingsContentList() => find.byType(ListView).last;

Finder settingsContentScrollable() => find
    .descendant(of: settingsContentList(), matching: find.byType(Scrollable))
    .first;

Future<void> openSettingsPage(WidgetTester tester, String label) async {
  if (label == '个性化') {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }
  await tester.tap(settingsSidebarRow(label));
  await tester.pumpAndSettle();
}

const languagePackInstalledStatus = '语言包已安装：English → 简体中文';
