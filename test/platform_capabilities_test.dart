import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/channel_names.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/platform_capabilities.dart';
import 'package:transnap/src/settings/app_settings.dart';
import 'package:transnap/src/settings/service_config.dart';
import 'package:transnap/src/settings/settings_app.dart';
import 'package:transnap/src/translation/provider_selection.dart';

import 'support/settings_pages.dart';

const _withoutApple = {
  PlatformCapability.dictionary,
  PlatformCapability.permissions,
  PlatformCapability.screenshot,
  PlatformCapability.recording,
  PlatformCapability.mcp,
};

void main() {
  test('内置服务按能力列出：有 Apple 系统翻译时排在首位作为默认，没有时只剩谷歌翻译', () {
    expect(
      ServiceConfig.builtins(PlatformCapability.values.toSet()).keys,
      [ServiceConfig.systemId, ServiceConfig.builtinId],
    );
    expect(ServiceConfig.builtins(_withoutApple).keys, [
      ServiceConfig.builtinId,
    ]);
    expect(ServiceConfig.builtins(const {}).keys, [ServiceConfig.builtinId]);
  });

  test('卡片服务菜单不列出平台不提供的 Apple 系统翻译', () {
    final settings = AppSettings(
      primaryLanguage: 'zh-CN',
      defaultServiceId: ServiceConfig.builtinId,
    );
    expect(serviceChoices(settings, _withoutApple), [
      (
        id: ServiceConfig.builtinId,
        name: ServiceConfig.builtinName,
        isModel: false,
        isDefault: true,
      ),
    ]);
  });

  testWidgets('能力为空时设置窗口隐藏截图与 MCP 页、权限卡片、语言包行与录制点击特效，默认服务只剩谷歌翻译', (
    tester,
  ) async {
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) return <String, Object>{};
      if (call.method == MethodNames.getSettings) {
        return {
          ...AppSettings(
            primaryLanguage: 'zh-CN',
            defaultServiceId: ServiceConfig.builtinId,
          ).toMap(),
          'revision': 0,
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp(capabilities: {}));
    await tester.pumpAndSettle();

    expect(settingsSidebarRow('截图'), findsNothing);
    expect(settingsSidebarRow('MCP'), findsNothing);
    expect(settingsSidebarRow('翻译'), findsOneWidget);
    expect(find.text('权限'), findsNothing);
    expect(find.byKey(const ValueKey('离线翻译语言')), findsNothing);
    expect(find.text('登录时启动'), findsOneWidget);

    await openSettingsPage(tester, '个性化');
    expect(find.text('录制点击特效'), findsNothing);

    await openSettingsPage(tester, '语言与服务');
    await tester.scrollUntilVisible(
      find.text(ServiceConfig.builtinName),
      300,
      scrollable: settingsContentScrollable(),
    );
    await tester.tap(find.text(ServiceConfig.builtinName));
    await tester.pumpAndSettle();
    expect(find.text(ServiceConfig.builtinName), findsNWidgets(2));
    expect(find.text(ServiceConfig.systemName), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await openSettingsPage(tester, '服务列表');
    expect(find.text('暂无自定义翻译服务；默认使用谷歌翻译。'), findsOneWidget);
  });
}
