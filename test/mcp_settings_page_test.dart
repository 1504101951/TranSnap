import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/channel_names.dart';
import 'package:translate_app/src/common/constants/glass_metrics.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/preference_keys.dart';
import 'package:translate_app/src/common/widgets/app_motion.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/settings/mcp_platforms.dart';
import 'package:translate_app/src/settings/mcp_settings_page.dart';
import 'package:translate_app/src/settings/settings_app.dart';

import 'support/settings_pages.dart';

/// 内存中的平台服务：替代真实 CLI 与配置文件，只用于驱动界面状态；
/// 平台服务自身的命令与文件行为由 mcp_platforms_test.dart 用真实进程验证。
class _FakeMcpService extends McpPlatformService {
  _FakeMcpService(String helperPath) : super(helperPath: helperPath, home: '/');

  /// 各平台当前状态；缺省为未安装。
  final states = <String, McpInstallState>{
    'grok': McpInstallState.missing,
    'codex': McpInstallState.pathChanged,
  };

  /// 安装时抛出的错误原文，按平台设置。
  final failures = <String, String>{};

  /// 等待挂起的安装事务，按平台 id 控制异步完成时机。
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

/// 验证设置窗口的 MCP 页（#96「设置」、#67「设置 MCP 页（#96）」）：MCP 侧边栏行、开关自动保存、
/// helper 路径与配置复制、按注册表渲染的平台状态与按钮可用性、安装失败原文、删除二次确认。
void main() {
  const helperPath =
      '/Applications/TranslateApp.app/Contents/MacOS/translateapp-mcp';
  const channel = MethodChannel(ChannelNames.settings);

  /// 作用：挂载设置窗口并切到侧边栏指定子页。
  /// 参数 tester：测试驱动；section：侧边栏行文字；saved：收集 saveSettings 草稿；clipboard：收集剪贴板文本；
  /// service：平台服务。
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
    // 默认测试视图高度可传入覆盖；常规用例展开全部内容便于直接点击。
    tester.view.physicalSize = windowSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      SettingsApp(createMcpService: (path) => service ?? _FakeMcpService(path)),
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

  /// 作用：返回平台行内按钮的可用状态。参数 tester：测试驱动；key：按钮键。返回：是否可点击。
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
    // 作用：操控开关依赖 MCP 接口开关，且与它分开持久化。
    // 边界：MCP 关闭时操控开关禁用；打开 MCP 后才能打开操控，保存值为 true。
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
        'translateapp': {'command': helperPath, 'args': <Object?>[]},
      },
    });
    expect(find.text('已复制'), findsOneWidget);
    // 反馈文字切换不改变按钮宽度。
    expect(tester.getSize(copy).width, width);

    // 边界依据：#96 待确认值 1000ms；999ms 仍显示，1000ms 恢复。
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
    // 边界依据：#67 平台行最小高 60。
    expect(
      tester
          .getSize(find.byKey(const ValueKey('mcp-platform-claude-code')))
          .height,
      greaterThanOrEqualTo(60),
    );
    // 未检测到 CLI：两个按钮都不可用。
    expect(rowText('grok', '未检测到 grok CLI'), findsOneWidget);
    expect(enabled(tester, 'mcp-install-grok'), isFalse);
    expect(enabled(tester, 'mcp-remove-grok'), isFalse);
    // 未安装：只可安装。
    expect(rowText('claude-code', '未安装'), findsOneWidget);
    expect(enabled(tester, 'mcp-install-claude-code'), isTrue);
    expect(enabled(tester, 'mcp-remove-claude-code'), isFalse);
    // 路径已变化：可重新安装或删除。
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

    // 下次操作开始时清除上次失败原文。
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
      find.text('从 Codex（CLI 与桌面 App 共用） 删除 TranslateApp？'),
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
    // 作用：验证平台安装挂起时当前安装按钮激活 BusyRing，同时锁定同平台动作而不干扰其他平台。
    // 边界：codex 挂起期间仅 mcp-install-codex 的 BusyRing active=true，mcp-remove-codex 禁用且非忙碌。
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
    // 作用：验证 mcpHelperPath 抛 PlatformException 时呈现错误横幅和「重试加载」，恢复后加载平台列表。
    // 边界：首次调用抛错展示 NativeGlassBanner；恢复路径并点击重试后平台项正常渲染。
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
    // 作用：验证外置眉标、同行 helper 路径与复制按钮及全高侧边栏避让顶部后，MCP 页在默认窗口不产生滚动。
    // 边界：760×640 视口下正文主列表 maxScrollExtent == 0，侧边栏 topPadding == 38。
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
