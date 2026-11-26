import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/appearance_modes.dart';
import 'package:transnap/src/common/constants/channel_names.dart';
import 'package:transnap/src/common/constants/error_codes.dart';
import 'package:transnap/src/common/constants/font_sets.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/platform_capabilities.dart';
import 'package:transnap/src/common/constants/preference_keys.dart';
import 'package:transnap/src/fonts/font_state.dart';
import 'package:transnap/src/settings/settings_app.dart';

import 'support/settings_pages.dart';

void main() {
  late List<MethodCall> calls;
  late Map<String, Object?> saved;
  late FontState fonts;
  PlatformException? failure;

  Future<void> pumpPersonalization(WidgetTester tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel(ChannelNames.appearance),
      (_) async => {
        PreferenceKeys.glassAppearance: AppearanceModes.light,
        PreferenceKeys.glassOpacity: 0.8,
        AppearanceKeys.accentLight: 0xFF007AFF,
        AppearanceKeys.accentDark: 0xFF0A84FF,
        AppearanceKeys.fontState: fonts.toMap(),
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel(ChannelNames.settings),
      (call) async {
        calls.add(call);
        switch (call.method) {
          case MethodNames.checkSystemTranslation:
            return languagePackInstalledStatus;
          case MethodNames.systemStatus:
            return {'accessibility': true, 'screenAccess': true};
          case MethodNames.getSettings:
            return saved;
          case MethodNames.saveSettings:
            saved = Map<String, Object?>.from(call.arguments as Map)
              ..remove('credentials')
              ..['revision'] = (saved['revision'] as int) + 1;
            return saved;
          case MethodNames.downloadFontSet:
          case MethodNames.uninstallFontSet:
            if (failure case final error?) throw error;
            return true;
        }
        return null;
      },
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel(ChannelNames.settings),
        null,
      ),
    );
    await tester.pumpWidget(
      SettingsApp(capabilities: PlatformCapability.values.toSet()),
    );
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '个性化');
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('font-set-trigger')));
    await tester.tap(find.byKey(const ValueKey('font-set-trigger')));
    await tester.pumpAndSettle();
  }

  setUp(() {
    calls = [];
    saved = {'revision': 0};
    fonts = const FontState(downloaded: {FontFile.geist});
    failure = null;
  });

  testWidgets('菜单列出 8 套组合的名称与组成，按下载状态显示内置、已下载或缺失体积，只有已下载的非内置组合可卸载', (
    tester,
  ) async {
    await pumpPersonalization(tester);
    expect(find.text('字体'), findsOneWidget);
    await openMenu(tester);
    for (final set in FontSet.values) {
      expect(find.byKey(ValueKey('font-set-${set.name}')), findsOneWidget);
      final name = tester.widget<Text>(
        find.descendant(
          of: find.byKey(ValueKey('font-set-${set.name}')),
          matching: find.text(set.label),
        ),
      );
      expect(name.style!.fontFamily, set.nameFamily);
      expect(name.style!.fontFamilyFallback, [set.nameTitleFamily]);
      expect(find.text(set.composition), findsOneWidget);
    }
    expect(find.text('内置'), findsOneWidget);
    expect(find.text('已下载'), findsOneWidget);
    expect(find.text('未下载 · 0.1 MB'), findsOneWidget);
    expect(find.text('未下载 · 26.9 MB'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('font-set-uninstall-geometric')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('font-set-uninstall-neutral')),
      findsNothing,
    );
  });

  testWidgets('选择已下载的组合直接保存，选择未下载的组合发起下载，卸载交给主引擎', (tester) async {
    await pumpPersonalization(tester);
    await openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('font-set-geometric')));
    await tester.pumpAndSettle();
    expect(saved[PreferenceKeys.fontSet], FontSet.geometric.name);

    await openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('font-set-legible')));
    await tester.pumpAndSettle();
    expect(
      calls.where((call) => call.method == MethodNames.downloadFontSet).single,
      isMethodCall(MethodNames.downloadFontSet, arguments: 'legible'),
    );

    await openMenu(tester);
    await tester.tap(
      find.byKey(const ValueKey('font-set-uninstall-geometric')),
    );
    await tester.pumpAndSettle();
    expect(
      calls.where((call) => call.method == MethodNames.uninstallFontSet).single,
      isMethodCall(MethodNames.uninstallFontSet, arguments: 'geometric'),
    );
  });

  testWidgets('下载中在字体行下方显示名称、百分比与已下载体积，取消发给主引擎', (tester) async {
    fonts = const FontState(
      download: (set: FontSet.bookish, received: 13464470, total: 26928940),
    );
    await pumpPersonalization(tester);
    expect(find.text('正在下载 书卷 · 50%（13.5 MB / 26.9 MB）'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('font-download-progress')),
          )
          .value,
      0.5,
    );
    await tester.tap(find.byKey(const ValueKey('font-download-cancel')));
    await tester.pumpAndSettle();
    expect(
      calls.map((call) => call.method),
      contains(MethodNames.cancelFontDownload),
    );
  });

  testWidgets('下载失败时显示主引擎返回的原因，当前组合不变', (tester) async {
    failure = PlatformException(
      code: ErrorCodes.fontChecksum,
      message: '「Geist.ttf」校验失败，已删除下载内容，可重试。',
    );
    fonts = const FontState();
    await pumpPersonalization(tester);
    await openMenu(tester);
    await tester.tap(find.byKey(const ValueKey('font-set-geometric')));
    await tester.pumpAndSettle();
    expect(find.text('「Geist.ttf」校验失败，已删除下载内容，可重试。'), findsOneWidget);
    expect(saved[PreferenceKeys.fontSet], isNull);
  });
}
