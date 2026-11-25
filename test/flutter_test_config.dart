import 'package:transnap/src/common/constants/appearance_modes.dart';
import 'package:transnap/src/common/constants/channel_names.dart';
import 'package:transnap/src/common/constants/preference_keys.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    if (BindingBase.debugBindingType() == null) return;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(ChannelNames.appearance),
          (_) async => {
            PreferenceKeys.glassAppearance: 'system',
            PreferenceKeys.glassOpacity: 0.8,
            AppearanceKeys.accentLight: 0xFF007AFF,
            AppearanceKeys.accentDark: 0xFF0A84FF,
          },
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform_views,
          (_) async => null,
        );
  });
  await testMain();
}
