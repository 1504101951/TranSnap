import 'package:transnap/src/common/constants/appearance_modes.dart';
import 'package:transnap/src/common/constants/channel_names.dart';
import 'package:transnap/src/common/constants/preference_keys.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// testMain 为 Flutter 测试入口；原生视图在原生测试验证，widget 测试只替代嵌入通道。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    // 只有 testWidgets 已建立绑定时才配置视图通道，纯 Dart HTTP 测试保留真实网络栈。
    if (BindingBase.debugBindingType() == null) return;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(ChannelNames.appearance),
          (_) async => {
            PreferenceKeys.glassAppearance: 'system',
            PreferenceKeys.glassOpacity: 0.8,
            // 原生快照总是携带浅、深外观下的系统强调色；测试用系统蓝。
            AppearanceKeys.accentLight: 0xFF007AFF,
            AppearanceKeys.accentDark: 0xFF0A84FF,
          },
        );
    // headless widget 环境没有 NSView，保留真实前景布局、焦点及业务状态验证。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform_views,
          (_) async => null,
        );
  });
  await testMain();
}
