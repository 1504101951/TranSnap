import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/channel_names.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/preference_keys.dart';
import 'package:transnap/src/common/widgets/native_glass.dart';
import 'package:transnap/src/settings/app_settings.dart';
import 'package:transnap/src/settings/settings_app.dart';

import 'support/settings_pages.dart';

void main() {
  testWidgets('保存期间继续修改时，旧回包不覆盖新选择', (tester) async {
    final gate = Completer<void>();
    var first = true;
    var saved = <String, Object?>{'revision': 0};
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return saved;
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        if (first) {
          first = false;
          await gate.future;
        }
        saved = {...draft, 'revision': (saved['revision'] as int) + 1};
        return saved;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is NativeGlassSwitchTile && w.title == '登录时启动',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '个性化');
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(find.text('正在自动保存…'), findsNothing);
    expect(find.text('已自动保存'), findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(saved[PreferenceKeys.launchAtLogin], true);
    expect(saved[PreferenceKeys.glassAppearance], 'dark');
    expect(find.text('深色'), findsOneWidget);
    expect(find.text('保存设置'), findsNothing);
    await openSettingsPage(tester, '权限与启动');
    expect(
      tester.widget<NativeGlassSwitch>(find.byType(NativeGlassSwitch)).value,
      true,
    );
  });

  testWidgets('无效语言组合保留草稿，修正后自动保存', (tester) async {
    var saved = <String, Object?>{
      ...AppSettings(primaryLanguage: 'zh-CN', secondaryLanguage: 'en').toMap(),
      'revision': 0,
    };
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return saved;
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        saved = {...draft, 'revision': (saved['revision'] as int) + 1};
        return saved;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '语言与服务');
    final primary = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is NativeGlassDropdown<String> && w.label == '主要语言',
      ),
      matching: find.byType(TextButton),
    );
    await tester.tap(primary);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'English'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('重试自动保存'),
      200,
      scrollable: settingsContentScrollable(),
    );
    await tester.tap(find.text('重试自动保存'));
    await tester.pumpAndSettle();
    expect(find.text('主要语言和次要语言必须不同。'), findsOneWidget);
    expect(saved[PreferenceKeys.primaryLanguage], 'zh-CN');
    final secondary = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is NativeGlassDropdown<String> && w.label == '次要语言（可选）',
      ),
      matching: find.byType(TextButton),
    );
    await tester.drag(settingsContentList(), const Offset(0, 1200));
    await tester.pumpAndSettle();
    await tester.ensureVisible(secondary);
    await tester.pumpAndSettle();
    await tester.tap(secondary);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '日本語'));
    await tester.pumpAndSettle();
    expect(saved[PreferenceKeys.primaryLanguage], 'en');
    expect(saved[PreferenceKeys.secondaryLanguage], 'ja');
    expect(find.text('主要语言和次要语言必须不同。'), findsNothing);
  });
  testWidgets('延迟返回的加载快照不回退已自动保存的设置版本', (tester) async {
    final statusGate = Completer<void>();
    var delayStatus = false;
    var saved = <String, Object?>{'revision': 0};
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        if (delayStatus) {
          delayStatus = false;
          await statusGate.future;
        }
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return {...saved};
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        expect(draft['revision'], saved['revision']);
        saved = {...draft, 'revision': (saved['revision'] as int) + 1};
        return saved;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    delayStatus = true;
    final loading = messenger.handlePlatformMessage(
      ChannelNames.settings,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall(MethodNames.refreshSettings),
      ),
      (_) {},
    );
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is NativeGlassSwitchTile && w.title == '登录时启动',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();
    expect(saved[PreferenceKeys.launchAtLogin], true);
    statusGate.complete();
    await loading;
    await tester.pumpAndSettle();
    expect(
      tester.widget<NativeGlassSwitch>(find.byType(NativeGlassSwitch)).value,
      true,
    );
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is NativeGlassSwitchTile && w.title == '登录时启动',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();
    expect(saved[PreferenceKeys.launchAtLogin], false);
    expect(find.text('重新加载设置'), findsNothing);
  });
}
