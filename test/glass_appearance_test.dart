import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/appearance_modes.dart';
import 'package:transnap/src/common/constants/channel_names.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/preference_keys.dart';
import 'package:transnap/src/common/widgets/native_glass.dart';
import 'package:transnap/src/settings/settings_app.dart';

import 'support/settings_pages.dart';

/// 核验广播到真实设置页面的主题/材料更新与草稿保留，不测方法被调用次数。
void main() {
  testWidgets('透明度两端经过表单校验后成功保存并重新加载', (tester) async {
    // 0% 与 80% 是用户可选边界；验证实际滑块到持久化状态，覆盖浮点换算误差。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var saved = <String, Object?>{'revision': 0};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return saved;
      if (call.method == MethodNames.saveSettings) {
        saved = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials')
          ..['revision'] = (saved['revision'] as int) + 1;
        return saved;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '个性化');
    expect(find.text('保存设置'), findsNothing);
    final slider = find.byType(Slider);
    for (final transparency in [0.8, 0.0]) {
      final bounds = tester.getRect(slider);
      await tester.tapAt(
        Offset(
          transparency == 0.8 ? bounds.right - 1 : bounds.left + 1,
          bounds.center.dy,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        saved[PreferenceKeys.glassOpacity],
        transparency == 0.8 ? 0.2 : 1.0,
      );
      // 成功仅体现为持久化结果，不显示成功/进行中反馈或改变布局。
      expect(find.text('已自动保存'), findsNothing);
      expect(find.text('正在自动保存…'), findsNothing);
      await tester.scrollUntilVisible(
        slider,
        -200,
        scrollable: settingsContentScrollable(),
      );
      await tester.pumpAndSettle();
      // 标题固定为「窗口透明度」，数值以等宽数字显示在滑块右侧。
      expect(find.text('窗口透明度'), findsOneWidget);
      expect(find.text('${(transparency * 100).round()}%'), findsOneWidget);
    }
  });

  testWidgets('保存外观广播更新材料与明暗，不覆盖未保存表单', (tester) async {
    // 用户正在录入草稿时，另一个引擎发布视觉更新；文字和材料必须同步且草稿不丢。
    const channel = MethodChannel(ChannelNames.settings);
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return {'revision': 0};
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '个性化');
    final slider = find.byType(Slider);
    tester.widget<Slider>(slider).onChanged!(0.6);
    await tester.pump();
    expect(find.text('60%'), findsOneWidget);
    await messenger.handlePlatformMessage(
      ChannelNames.appearance,
      codec.encodeMethodCall(
        const MethodCall(MethodNames.appearanceChanged, {
          PreferenceKeys.glassAppearance: 'dark',
          PreferenceKeys.glassOpacity: 0.2,
          AppearanceKeys.accentLight: 0xFF007AFF,
          AppearanceKeys.accentDark: 0xFF0A84FF,
        }),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Slider));
    expect(Theme.of(context).brightness, Brightness.dark);
    expect(Theme.of(context).colorScheme.onSurface, Colors.white);
    expect(find.text('60%'), findsOneWidget);
    final materials = tester.widgetList<AppKitView>(find.byType(AppKitView));
    expect(materials, isNotEmpty);
    expect(
      materials.every((view) => (view.creationParams as Map)['opacity'] == 0.2),
      isTrue,
    );
    await messenger.handlePlatformMessage(
      ChannelNames.appearance,
      codec.encodeMethodCall(
        const MethodCall(MethodNames.appearanceChanged, {
          PreferenceKeys.glassAppearance: 'light',
          PreferenceKeys.glassOpacity: 1.0,
          AppearanceKeys.accentLight: 0xFF953D96,
          AppearanceKeys.accentDark: 0xFFA550A7,
        }),
      ),
      (_) {},
    );
    await tester.pumpAndSettle();
    expect(Theme.of(context).brightness, Brightness.light);
    expect(Theme.of(context).colorScheme.onSurface, Colors.black);
    expect(find.text('60%'), findsOneWidget);
    // 系统强调色改为紫色后，选中实底取浅色外观解析值，primary 为它与黑 75:25 混合（#142）。
    expect(NativeGlassTheme.accentOf(context), const Color(0xFF953D96));
    expect(
      Theme.of(context).colorScheme.primary,
      Color.lerp(const Color(0xFF953D96), Colors.black, 0.25),
    );
  });

  test('外观快照缺少系统强调色时拒绝，系统蓝时 primary 与原定值一致', () {
    // 作用：强调色是原生快照的必备字段，缺失说明两端契约不一致，应直接报错而不是悄悄用默认值。
    // 边界：只缺深色值也拒绝；系统蓝浅色 #007AFF 与黑 75:25 混合约为 #005BC5，深色 #0A84FF 与白 65:35 混合约为 #64ACFF。
    expect(
      () => GlassAppearance.fromMap({
        PreferenceKeys.glassAppearance: 'system',
        PreferenceKeys.glassOpacity: 0.8,
        AppearanceKeys.accentLight: 0xFF007AFF,
      }),
      throwsFormatException,
    );
    final light = NativeGlassTheme.data(Brightness.light).colorScheme.primary;
    final dark = NativeGlassTheme.data(Brightness.dark).colorScheme.primary;
    expect((light.r * 255).round(), 0);
    expect((light.b * 255).round(), closeTo(0xBF, 2));
    expect((dark.r * 255).round(), closeTo(0x5F, 2));
    expect((dark.b * 255).round(), 0xFF);
  });

  testWidgets('个性化页切换强调色后立即持久化，支持 6 种经典色与跟随系统（#144）', (tester) async {
    // 作用：验证「个性化 → 强调色」点击预设色点立即自动保存 PreferenceKeys.accentColor。
    // 边界：初始缺省为 system，点选 accent-color-purple 后保存值为 purple，切回 system 后恢复 system。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var saved = <String, Object?>{'revision': 0};
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.checkSystemTranslation:
          return languagePackInstalledStatus;
        case MethodNames.systemStatus:
          return {'accessibility': true};
        case MethodNames.getSettings:
          return saved;
        case MethodNames.saveSettings:
          saved = Map<String, Object?>.from(call.arguments as Map)
            ..remove('credentials')
            ..['revision'] = (saved['revision'] as int) + 1;
          return saved;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '个性化');

    expect(find.text('强调色'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('accent-color-purple')));
    await tester.pumpAndSettle();
    expect(saved[PreferenceKeys.accentColor], AccentColors.purple);

    await tester.tap(find.byKey(const ValueKey('accent-color-system')));
    await tester.pumpAndSettle();
    expect(saved[PreferenceKeys.accentColor], AccentColors.system);
  });

  testWidgets('前景色：选「白色」保存 white 并改变强调色实底前景；对比不足时说明行提示（#144）', (tester) async {
    // 作用：验证「前景色」选择持久化为 accentForeground，并在非自动且对比度 < 4.5:1 时显示提示，选回「自动」后提示消失。
    // 边界：默认强调色为浅色系统蓝 #007AFF，白字对比约 4.0:1 < 4.5，选「白色」出现提示；「自动」不提示。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var saved = <String, Object?>{'revision': 0};
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.checkSystemTranslation:
          return languagePackInstalledStatus;
        case MethodNames.systemStatus:
          return {'accessibility': true};
        case MethodNames.getSettings:
          return saved;
        case MethodNames.saveSettings:
          saved = Map<String, Object?>.from(call.arguments as Map)
            ..remove('credentials')
            ..['revision'] = (saved['revision'] as int) + 1;
          return saved;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '个性化');
    expect(saved[PreferenceKeys.accentForeground], isNull);
    expect(find.text('强调色实底上的图标线条与文字'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('accent-foreground-white')));
    await tester.pumpAndSettle();
    expect(saved[PreferenceKeys.accentForeground], AccentForegrounds.white);
    expect(find.textContaining('低于 4.5:1，可能看不清'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('accent-foreground-auto')));
    await tester.pumpAndSettle();
    expect(saved[PreferenceKeys.accentForeground], AccentForegrounds.auto);
    expect(find.textContaining('低于 4.5:1'), findsNothing);
  });

  testWidgets('自定义强调色：调色盘「应用」保存大写 HEX，「取消」不改变已保存值（#144）', (tester) async {
    // 作用：验证末位「自定义」色点展开调色盘，确认后把颜色以 #RRGGBB 保存，取消保留原值。
    // 边界：HEX 输入小写 2ea3d6 也按大写 #2EA3D6 保存；第二次输入 112233 后取消，保存值仍为 #2EA3D6。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var saved = <String, Object?>{'revision': 0};
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.checkSystemTranslation:
          return languagePackInstalledStatus;
        case MethodNames.systemStatus:
          return {'accessibility': true};
        case MethodNames.getSettings:
          return saved;
        case MethodNames.saveSettings:
          saved = Map<String, Object?>.from(call.arguments as Map)
            ..remove('credentials')
            ..['revision'] = (saved['revision'] as int) + 1;
          return saved;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '个性化');

    await tester.tap(find.byKey(const ValueKey('accent-color-custom')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('color-hex')), '2ea3d6');
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(saved[PreferenceKeys.accentColor], '#2EA3D6');
    expect(find.byKey(const Key('color-hex')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('accent-color-custom')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('color-hex')), '112233');
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(saved[PreferenceKeys.accentColor], '#2EA3D6');
  });
}
