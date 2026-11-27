import 'package:transnap/src/common/constants/platform_capabilities.dart';
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

void main() {
  testWidgets('透明度两端经过表单校验后成功保存并重新加载', (tester) async {
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
    await tester.pumpWidget(
      SettingsApp(capabilities: PlatformCapability.values.toSet()),
    );
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
      expect(find.text('已自动保存'), findsNothing);
      expect(find.text('正在自动保存…'), findsNothing);
      await tester.scrollUntilVisible(
        slider,
        -200,
        scrollable: settingsContentScrollable(),
      );
      await tester.pumpAndSettle();
      expect(find.text('窗口透明度'), findsOneWidget);
      expect(find.text('${(transparency * 100).round()}%'), findsOneWidget);
    }
  });

  testWidgets('保存外观广播更新材料与明暗，不覆盖未保存表单', (tester) async {
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
    await tester.pumpWidget(
      SettingsApp(capabilities: PlatformCapability.values.toSet()),
    );
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
    expect(NativeGlassTheme.accentOf(context), const Color(0xFF953D96));
    expect(
      Theme.of(context).colorScheme.primary,
      Color.lerp(const Color(0xFF953D96), Colors.black, 0.25),
    );
  });

  test('外观快照的玻璃材质缺省为原生，接受亚克力与不透明，未知值报错', () {
    Map<String, Object> snapshot([String? material]) => {
      PreferenceKeys.glassAppearance: AppearanceModes.system,
      PreferenceKeys.glassOpacity: 0.8,
      AppearanceKeys.accentLight: 0xFF007AFF,
      AppearanceKeys.accentDark: 0xFF0A84FF,
      AppearanceKeys.glassMaterial: ?material,
    };
    expect(GlassAppearance.fromMap(snapshot()).material, GlassMaterials.native);
    for (final material in [GlassMaterials.acrylic, GlassMaterials.opaque]) {
      expect(GlassAppearance.fromMap(snapshot(material)).material, material);
    }
    expect(
      () => GlassAppearance.fromMap(snapshot('mica')),
      throwsFormatException,
    );
  });

  testWidgets('非原生材质由 Flutter 绘制底色：亚克力叠加 16% 色调乘以透明度，不透明用阅读底色，均不创建原生玻璃视图', (
    tester,
  ) async {
    addTearDown(() => GlassAppearance.current.value = const GlassAppearance());
    Future<void> pump(String material, Brightness brightness) async {
      GlassAppearance.current.value = GlassAppearance(
        opacity: 0.5,
        material: material,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: NativeGlassTheme.data(brightness),
          home: const Center(
            child: NativeGlassSurface(material: true, child: Text('玻璃')),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Iterable<Color> fills() => tester
        .widgetList<ColoredBox>(
          find.descendant(
            of: find.byType(NativeGlassSurface),
            matching: find.byType(ColoredBox),
          ),
        )
        .map((box) => box.color);

    await pump(GlassMaterials.acrylic, Brightness.light);
    expect(find.byType(AppKitView), findsNothing);
    expect(fills(), contains(Colors.white.withValues(alpha: 0.08)));
    await pump(GlassMaterials.acrylic, Brightness.dark);
    expect(fills(), contains(Colors.black.withValues(alpha: 0.08)));
    await pump(GlassMaterials.opaque, Brightness.dark);
    expect(find.byType(AppKitView), findsNothing);
    expect(fills(), contains(const Color(0xFF171717)));
    await pump(GlassMaterials.native, Brightness.light);
    expect(find.byType(AppKitView), findsOneWidget);
  });

  test('外观快照缺少系统强调色时拒绝，系统蓝时 primary 与原定值一致', () {
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

    await tester.pumpWidget(
      SettingsApp(capabilities: PlatformCapability.values.toSet()),
    );
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

    await tester.pumpWidget(
      SettingsApp(capabilities: PlatformCapability.values.toSet()),
    );
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

    await tester.pumpWidget(
      SettingsApp(capabilities: PlatformCapability.values.toSet()),
    );
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
