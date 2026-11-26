import 'package:transnap/src/common/constants/platform_capabilities.dart';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:transnap/src/common/constants/channel_names.dart';
import 'package:transnap/src/common/constants/glass_metrics.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/widgets/native_glass.dart';
import 'package:transnap/src/settings/settings_app.dart';
import 'package:transnap/src/settings/service_config.dart';

import 'support/settings_pages.dart';
import 'support/line_icons.dart';

void main() {
  testWidgets('侧边栏滚动后仍固定，权限仅在通用，新建服务为四类且不含 Apple', (tester) async {
    tester.view.physicalSize = const Size(760, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getSettings) return {'revision': 0};
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true, 'screenAccess': true};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(SettingsApp(capabilities: PlatformCapability.values.toSet()));
    await tester.pumpAndSettle();
    final sidebar = find.byKey(const ValueKey('settings-sidebar'));
    final before = tester.getRect(sidebar);
    expect(before.width, 200);
    await tester.drag(settingsContentList(), const Offset(0, -800));
    await tester.pumpAndSettle();
    expect(tester.getRect(sidebar), before);
    expect(find.text('辅助功能'), findsOneWidget);
    expect(find.text('所有支持读取选区的应用均可翻译。'), findsNothing);
    expect(find.text('已授权，可截取屏幕'), findsNothing);
    expect(find.text('屏幕录制'), findsOneWidget);
    final accessibilityGroup = find.ancestor(
      of: find.text('辅助功能'),
      matching: find.byType(NativeGlassGroup),
    );
    final screenGroup = find.ancestor(
      of: find.text('屏幕录制'),
      matching: find.byType(NativeGlassGroup),
    );
    expect(tester.element(accessibilityGroup), tester.element(screenGroup));
    expect(
      find.descendant(of: accessibilityGroup, matching: find.text('登录时启动')),
      findsNothing,
    );
    final languagesRow = find.byKey(const ValueKey('离线翻译语言'));
    expect(tester.getSize(languagesRow).height, greaterThanOrEqualTo(60));
    expect(
      find.descendant(of: accessibilityGroup, matching: find.text('管理')),
      findsOneWidget,
    );
    expect(
      tester.getRect(languagesRow).top,
      greaterThanOrEqualTo(tester.getRect(find.text('屏幕录制')).bottom),
    );
    expect(
      tester.getRect(find.text('登录时启动').first).top,
      greaterThan(tester.getRect(languagesRow).bottom),
    );

    await openSettingsPage(tester, '操作');
    expect(find.text('屏幕录制'), findsNothing);
    final shortcutLabel = find.text('区域截图快捷键');
    final shortcutButton = find.byKey(const ValueKey('区域截图快捷键'));
    expect(
      (tester.getCenter(shortcutLabel).dy - tester.getCenter(shortcutButton).dy)
          .abs(),
      lessThanOrEqualTo(1),
    );
    expect(find.textContaining('点击录制；录制完成'), findsNothing);
    await openSettingsPage(tester, '服务列表');
    await tester.tap(find.text('添加服务'));
    await tester.pumpAndSettle();
    final selector = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is NativeGlassDropdown<String> && w.label == '服务类型',
      ),
      matching: find.byType(TextButton),
    );
    await tester.tap(selector);
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNWidgets(4));
    for (final label in ['谷歌翻译', '百度翻译', 'OpenAI', 'Anthropic']) {
      expect(find.widgetWithText(MenuItemButton, label), findsOneWidget);
    }
    expect(find.widgetWithText(MenuItemButton, 'Apple 系统翻译'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('深色分段选中仍为白字，背景覆盖76×28', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.dark),
        home: Scaffold(
          body: NativeGlassSegments<String>(
            value: 'dark',
            options: const {'system': '跟随系统', 'light': '浅色', 'dark': '深色'},
            onChanged: (_) {},
          ),
        ),
      ),
    );
    final selected = find.widgetWithText(TextButton, '深色');
    expect(tester.getSize(selected), const Size(76, 28));
    final paragraph = tester.widget<RichText>(
      find.descendant(of: selected, matching: find.byType(RichText)),
    );
    expect(paragraph.text.style!.color, Colors.white);
  });

  testWidgets('开关标题区域悬停不绘制整行背景', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.dark),
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: NativeGlassSwitchTile(
              title: '登录时启动',
              value: true,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final beforePixels = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return pixels;
    });
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 500));
    await mouse.moveTo(tester.getCenter(find.text('登录时启动').first));
    await tester.pumpAndSettle();
    final afterPixels = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final pixels = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return pixels;
    });
    expect(
      afterPixels!.buffer.asUint8List(),
      orderedEquals(beforePixels!.buffer.asUint8List()),
    );
    await mouse.removePointer();
  });

  testWidgets('开关只有按钮响应，标题和空白不改变状态', (tester) async {
    var enabled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => NativeGlassSwitchTile(
              title: '仅使用快捷键',
              subtitle: '说明文字',
              value: enabled,
              onChanged: (value) => update(() => enabled = value),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('仅使用快捷键').first);
    await tester.pumpAndSettle();
    expect(enabled, isFalse);
    await tester.tapAt(const Offset(400, 30));
    await tester.pumpAndSettle();
    expect(enabled, isFalse);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(10, 200));
    await mouse.moveTo(tester.getCenter(find.byType(NativeGlassSwitch)));
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
    );
    await mouse.moveTo(tester.getCenter(find.text('仅使用快捷键').first));
    await tester.pumpAndSettle();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.basic,
    );
    await mouse.removePointer();
    await tester.tap(find.byType(NativeGlassSwitch));
    await tester.pumpAndSettle();
    expect(enabled, isTrue);
  });

  testWidgets('默认窗口单服务时除列表子页外的子页无需滚动，服务操作之间保留8pt空白', (tester) async {
    tester.view.physicalSize = const Size(760, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) return <String, Object?>{};
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.getSettings) {
        return {
          'revision': 0,
          'services': [
            const ServiceConfig(
              id: 'saved',
              kind: 'openai',
              name: 'OpenAI',
              baseUrl: 'https://api.openai.com',
              model: 'gpt-test',
            ).toMap(),
          ],
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(SettingsApp(capabilities: PlatformCapability.values.toSet()));
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '服务列表');
    final edit = tester.getRect(
      find.ancestor(of: findLineIcon(LucideIcons.pencil), matching: find.byType(IconButton)),
    );
    final delete = tester.getRect(
      find.ancestor(of: findLineIcon(LucideIcons.trash2), matching: find.byType(IconButton)),
    );
    expect(edit.size, const Size(32, 32));
    expect(delete.left - edit.right, 8);
    double maxScroll() => tester
        .state<ScrollableState>(settingsContentScrollable())
        .position
        .maxScrollExtent;
    expect(maxScroll(), 0);
    await openSettingsPage(tester, '语言与服务');
    expect(find.text('当翻译文本识别为主要语言时，会自动翻译成次要语言'), findsOneWidget);
    expect(maxScroll(), 0);
    await openSettingsPage(tester, '快捷键');
    expect(find.text('点击录制；录制完成后自动保存；检查系统保留组合和可识别的全局占用。'), findsNothing);
    expect(find.byKey(const ValueKey('全局翻译快捷键')).hitTestable(), findsOneWidget);
    expect(maxScroll(), 0);
    await openSettingsPage(tester, '权限与启动');
    expect(find.text('外观'), findsNothing);
    expect(find.text('强调色'), findsNothing);
    expect(maxScroll(), 0, reason: '通用');
    await openSettingsPage(tester, '个性化');
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('强调色'), findsOneWidget);
    expect(find.text('窗口透明度'), findsOneWidget);
    expect(find.byKey(const Key('click-effect-stage')), findsOneWidget);
    expect(maxScroll(), 0, reason: '个性化');
    for (final page in ['保存与导出', '录制', '操作', '工具栏']) {
      await openSettingsPage(tester, page);
      expect(maxScroll(), 0, reason: page);
    }
  });

  test('展示名称调整不改写持久化配置或自定义名称', () {
    const service = ServiceConfig(
      id: 'saved',
      kind: 'openai',
      name: 'OpenAI-compatible',
      baseUrl: 'https://api.deepseek.com',
      model: 'deepseek-v4-flash',
    );
    expect(service.displayName, 'OpenAI');
    expect(service.toMap()['name'], 'OpenAI-compatible');
    final custom = ServiceConfig.fromMap({...service.toMap(), 'name': '工作翻译'});
    expect(custom.displayName, '工作翻译');
    final existing = ServiceConfig.fromMap({
      ...service.toMap(),
      'kind': 'deepseek',
    });
    expect(existing.validate, returnsNormally);
    expect(existing.toMap()['id'], 'saved');
  });

  testWidgets('NativeGlassSwitch 按下态横向果冻拉伸至 21pt，松手回位且减动效跳过拉伸（#67、#144）', (
    tester,
  ) async {
    var value = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => MediaQuery(
              data: const MediaQueryData(disableAnimations: false),
              child: Center(
                child: NativeGlassSwitch(
                  value: value,
                  label: '果冻开关',
                  onChanged: (next) => update(() => value = next),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final thumbFinder = find.byKey(const ValueKey('native-glass-switch-thumb'));
    expect(tester.getSize(thumbFinder).width, GlassMetrics.switchThumb);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(NativeGlassSwitch)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(thumbFinder).width,
      closeTo(GlassMetrics.switchThumbPressedWidth, 0.05),
    );

    await gesture.up();
    await tester.pumpAndSettle();
    expect(value, isTrue);
    expect(tester.getSize(thumbFinder).width, GlassMetrics.switchThumb);

    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Center(
              child: NativeGlassSwitch(
                value: false,
                label: '减动效开关',
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final reducedGesture = await tester.startGesture(
      tester.getCenter(find.byType(NativeGlassSwitch)),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(thumbFinder).width, GlassMetrics.switchThumb);
    await reducedGesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('NativeGlassGroup 外置眉标与 NativeGlassKeycaps 独立键帽及合并语义（#67）', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: NativeGlassGroup(
            title: '外观与材质',
            children: const [
              NativeGlassSettingRow(
                title: '快捷键示例',
                leading: NativeGlassRowIcon(icon: LucideIcons.keyboard),
                child: NativeGlassKeycaps(tokens: ['⇧', '⌘', '@']),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.text('外观与材质')).bottom,
      lessThanOrEqualTo(tester.getRect(find.text('快捷键示例')).top),
    );
    expect(find.bySemanticsLabel('⇧ ⌘ @'), findsOneWidget);
    for (final token in ['⇧', '⌘', '@']) {
      expect(find.text(token), findsOneWidget);
    }
  });
}
