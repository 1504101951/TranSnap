import 'package:transnap/src/common/constants/platform_capabilities.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/channel_names.dart';
import 'package:transnap/src/common/constants/glass_metrics.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/preference_keys.dart';
import 'package:transnap/src/common/widgets/app_motion.dart';
import 'package:transnap/src/common/widgets/native_glass.dart';
import 'package:transnap/src/settings/mcp_platforms.dart';
import 'package:transnap/src/settings/mcp_settings_page.dart';
import 'package:transnap/src/settings/settings_app.dart';

import 'support/settings_pages.dart';

class _FakeMcpService extends McpPlatformService {
  _FakeMcpService(String helperPath) : super(helperPath: helperPath, home: '/');

  final states = <String, McpInstallState>{
    'grok': McpInstallState.missing,
    'codex': McpInstallState.pathChanged,
  };

  final failures = <String, String>{};

  final pendingInstalls = <String, Completer<void>>{};

  @override
  Future<McpInstallState> detect(McpPlatform platform) async =>
      states[platform.id] ?? McpInstallState.notInstalled;

  @override
  Future<void> install(McpPlatform platform) async {
    final pending = pendingInstalls[platform.id];
    if (pending != null) await pending.future;
    final failure = failures[platform.id];
    if (failure != null) throw McpPlatformException(failure);
    states[platform.id] = McpInstallState.installed;
  }

  @override
  Future<void> remove(McpPlatform platform) async {
    states[platform.id] = McpInstallState.notInstalled;
  }
}

void main() {
  const helperPath =
      '/Applications/TranSnap.app/Contents/MacOS/transnap-mcp';
  const channel = MethodChannel(ChannelNames.settings);

  Future<void> open(
    WidgetTester tester, {
    String section = 'MCP',
    List<Map<String, Object?>>? saved,
    List<String>? clipboard,
    _FakeMcpService? service,
    Size windowSize = const Size(800, 2400),
  }) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var revision = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      switch (call.method) {
        case MethodNames.systemStatus:
          return {'accessibility': true};
        case MethodNames.getSettings:
          return {'revision': revision};
        case MethodNames.mcpHelperPath:
          return helperPath;
        case MethodNames.saveSettings:
          final draft = Map<String, Object?>.from(call.arguments as Map);
          saved?.add(draft);
          return {...draft, 'revision': ++revision};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard?.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    tester.view.physicalSize = windowSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      SettingsApp(capabilities: PlatformCapability.values.toSet(), createMcpService: (path) => service ?? _FakeMcpService(path)),
    );
    await tester.pumpAndSettle();
    await openSettingsPage(tester, section);
  }

  Finder mcpSwitch() => find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is NativeGlassSwitchTile && w.title == '允许 agent 截图',
    ),
    matching: find.byType(NativeGlassSwitch),
  );

  bool enabled(WidgetTester tester, String key) =>
      tester.widget<TextButton>(find.byKey(ValueKey(key))).onPressed != null;

  Finder rowText(String id, String text) => find.descendant(
    of: find.byKey(ValueKey('mcp-platform-$id')),
    matching: find.text(text),
  );

  testWidgets('MCP 是侧边栏的一级子页，保存与导出子页不包含 MCP 内容', (tester) async {
    await open(tester, section: '保存与导出');
    expect(find.text('MCP 接口'), findsNothing);
    expect(find.text('允许 agent 截图'), findsNothing);

    await openSettingsPage(tester, 'MCP');
    expect(find.text('MCP 接口'), findsOneWidget);
    expect(find.text('接入平台'), findsOneWidget);
    expect(find.text('截图目录'), findsNothing);
  });

  testWidgets('「允许操控电脑」默认关闭，「允许 agent 截图」关闭时不可切换，开启后经自动保存提交（#140）', (
    tester,
  ) async {
    final saved = <Map<String, Object?>>[];
    await open(tester, saved: saved);
    final control = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is NativeGlassSwitchTile && w.title == '允许操控电脑',
      ),
      matching: find.byType(NativeGlassSwitch),
    );
    expect(tester.widget<NativeGlassSwitch>(control).value, isFalse);
    expect(tester.widget<NativeGlassSwitch>(control).onChanged, isNull);

    await tester.tap(mcpSwitch());
    await tester.pumpAndSettle();
    await tester.tap(control);
    await tester.pumpAndSettle();
    expect(saved.last[PreferenceKeys.mcpControlEnabled], isTrue);
    expect(saved.last[PreferenceKeys.mcpEnabled], isTrue);
  });

  testWidgets('开关默认关闭并经自动保存提交', (tester) async {
    final saved = <Map<String, Object?>>[];
    await open(tester, saved: saved);
    expect(tester.widget<NativeGlassSwitch>(mcpSwitch()).value, isFalse);

    await tester.tap(mcpSwitch());
    await tester.pumpAndSettle();
    expect(saved.last[PreferenceKeys.mcpEnabled], isTrue);
    expect(tester.widget<NativeGlassSwitch>(mcpSwitch()).value, isTrue);
  });

  testWidgets('开关关闭时显示完整路径并可复制客户端配置，「已复制」保持 1000ms', (tester) async {
    final clipboard = <String>[];
    await open(tester, clipboard: clipboard);

    final path = find.byKey(const ValueKey('mcp-helper-path'));
    expect(tester.widget<SelectableText>(path).data, helperPath);
    final copy = find.byKey(const ValueKey('mcp-copy-config'));
    final width = tester.getSize(copy).width;
    await tester.tap(copy);
    await tester.pump();

    final config = jsonDecode(clipboard.single) as Map<String, Object?>;
    expect(config, {
      'mcpServers': {
        'transnap': {'command': helperPath, 'args': <Object?>[]},
      },
    });
    expect(find.text('已复制'), findsOneWidget);
    expect(tester.getSize(copy).width, width);

    await tester.pump(const Duration(milliseconds: 999));
    expect(find.text('已复制'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('已复制'), findsNothing);
  });

  testWidgets('平台列表按注册表渲染，状态决定按钮文字与可用性，行最小高 60', (tester) async {
    await open(tester);

    for (final platform in mcpPlatforms) {
      expect(
        find.byKey(ValueKey('mcp-platform-${platform.id}')),
        findsOneWidget,
      );
    }
    expect(
      tester
          .getSize(find.byKey(const ValueKey('mcp-platform-claude-code')))
          .height,
      greaterThanOrEqualTo(60),
    );
    expect(rowText('grok', '未检测到 grok CLI'), findsOneWidget);
    expect(enabled(tester, 'mcp-install-grok'), isFalse);
    expect(enabled(tester, 'mcp-remove-grok'), isFalse);
    expect(rowText('claude-code', '未安装'), findsOneWidget);
    expect(enabled(tester, 'mcp-install-claude-code'), isTrue);
    expect(enabled(tester, 'mcp-remove-claude-code'), isFalse);
    expect(rowText('codex', '路径已变化'), findsOneWidget);
    expect(rowText('codex', '重新安装'), findsOneWidget);
    expect(enabled(tester, 'mcp-remove-codex'), isTrue);
  });

  testWidgets('安装后重新检测；配置文件式平台提示重启；失败原文显示在行下方', (tester) async {
    late _FakeMcpService service;
    await open(
      tester,
      service: service = _FakeMcpService(helperPath)
        ..failures['claude-code'] = 'claude: permission denied',
    );

    await tester.tap(find.byKey(const ValueKey('mcp-install-claude-desktop')));
    await tester.pumpAndSettle();
    expect(rowText('claude-desktop', '已安装'), findsOneWidget);
    expect(rowText('claude-desktop', '重启 Claude 后生效'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mcp-install-claude-code')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('mcp-error-claude-code')))
          .data,
      'claude: permission denied',
    );
    expect(rowText('claude-code', '未安装'), findsOneWidget);

    service.failures.clear();
    await tester.tap(find.byKey(const ValueKey('mcp-install-claude-code')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mcp-error-claude-code')), findsNothing);
    expect(rowText('claude-code', '已安装'), findsOneWidget);
  });

  testWidgets('删除前二次确认：取消不删除，确认后删除并重新检测', (tester) async {
    await open(tester);

    await tester.tap(find.byKey(const ValueKey('mcp-remove-codex')));
    await tester.pumpAndSettle();
    expect(
      find.text('从 Codex（CLI 与桌面 App 共用） 删除 TranSnap？'),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(rowText('codex', '路径已变化'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mcp-remove-codex')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(rowText('codex', '未安装'), findsOneWidget);
    expect(enabled(tester, 'mcp-remove-codex'), isFalse);
  });

  testWidgets('MCP 安装进行中仅激活对应平台按钮的进度环并锁定重复操作（#144）', (tester) async {
    final pendingInstall = Completer<void>();
    final service = _FakeMcpService(helperPath)
      ..pendingInstalls['codex'] = pendingInstall;
    await open(tester, service: service);

    BusyRing ringFor(String key) => tester.widget<BusyRing>(
      find
          .ancestor(of: find.byKey(ValueKey(key)), matching: find.byType(BusyRing))
          .first,
    );

    await tester.tap(find.byKey(const ValueKey('mcp-install-codex')));
    await tester.pump();
    expect(ringFor('mcp-install-codex').active, isTrue);
    expect(ringFor('mcp-remove-codex').active, isFalse);
    expect(ringFor('mcp-install-claude-code').active, isFalse);
    expect(enabled(tester, 'mcp-install-codex'), isFalse);
    expect(enabled(tester, 'mcp-remove-codex'), isFalse);

    pendingInstall.complete();
    await tester.pumpAndSettle();
    expect(ringFor('mcp-install-codex').active, isFalse);
    expect(rowText('codex', '已安装'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('helper 路径读取失败时显示错误横幅并支持重试恢复（#144）', (tester) async {
    const pageChannel = MethodChannel('test/mcp-helper-retry');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var failHelper = true;
    messenger.setMockMethodCallHandler(pageChannel, (call) async {
      if (call.method == MethodNames.mcpHelperPath) {
        if (failHelper) {
          throw PlatformException(code: 'helper_missing', message: '未找到 MCP 组件');
        }
        return helperPath;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(pageChannel, null));

    await tester.pumpWidget(
      NativeGlassApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: McpSettingsPage(
              enabled: false,
              onChanged: (_) {},
              controlEnabled: false,
              onControlChanged: (_) {},
              channel: pageChannel,
              createService: (path) => _FakeMcpService(path),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NativeGlassBanner), findsOneWidget);
    expect(find.text('未找到 MCP 组件'), findsOneWidget);

    failHelper = false;
    await tester.tap(find.text('重试加载'));
    await tester.pumpAndSettle();
    expect(find.text('未找到 MCP 组件'), findsNothing);
    expect(find.byKey(const ValueKey('mcp-platform-codex')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('默认 760×640 窗口下 MCP 子页一屏完整展示、无滚动条，侧边栏避让顶部安全区（#67）', (
    tester,
  ) async {
    await open(tester, windowSize: const Size(760, 640));
    final sidebar = tester.widget<NativeGlassSidebar<SettingsPage>>(
      find.byKey(const ValueKey('settings-sidebar')),
    );
    expect(sidebar.topPadding, 38);

    final contentList = find.descendant(
      of: find.byType(SettingsApp),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is ListView &&
            widget.padding ==
                const EdgeInsets.fromLTRB(
                  GlassMetrics.pagePadding,
                  0,
                  GlassMetrics.pagePadding,
                  GlassMetrics.pagePadding,
                ),
      ),
    );
    final scrollable = tester.state<ScrollableState>(
      find.descendant(of: contentList, matching: find.byType(Scrollable)).first,
    );
    expect(scrollable.position.maxScrollExtent, 0);
    expect(tester.takeException(), isNull);
  });
}
