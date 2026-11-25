import 'dart:async';

import 'package:transnap/src/common/constants/method_names.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/channel_names.dart';
import 'package:transnap/src/common/widgets/app_motion.dart';
import 'package:transnap/src/common/widgets/native_glass.dart';
import 'package:transnap/src/settings/permission_wizard_app.dart';

void main() {
  testWidgets('同一页两个授权按钮，都成功后进入应用才可点', (tester) async {
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var accessibility = false;
    var screen = false;
    var finished = false;
    var closed = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.permissionWizardStatus:
          return {
            'accessibility': accessibility,
            'screenAccess': screen,
            'finishedOrSkipped': finished,
          };
        case MethodNames.openAccessibility:
          accessibility = true;
          return null;
        case MethodNames.requestScreenAccess:
          screen = true;
          return {'screenAccess': true};
        case MethodNames.finishPermissionWizard:
          finished = true;
          return null;
        case MethodNames.closePermissionWizard:
          closed = true;
          return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const PermissionWizardApp());
    await tester.pump();
    expect(find.text('授权辅助功能'), findsOneWidget);
    expect(find.text('申请录屏权限'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '进入应用'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('授权辅助功能'));
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '进入应用'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('申请录屏权限'));
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '进入应用'))
          .onPressed,
      isNotNull,
    );
    expect(closed, isFalse);

    await tester.tap(find.text('进入应用'));
    await tester.pump();
    expect(finished, isTrue);
    expect(closed, isTrue);
  });

  testWidgets('稍后可结束向导；系统回调授权后进入应用变可点但不自动关窗', (tester) async {
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var accessibility = true;
    var screen = false;
    var finished = false;
    var closed = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.permissionWizardStatus:
          return {
            'accessibility': accessibility,
            'screenAccess': screen,
            'finishedOrSkipped': finished,
          };
        case MethodNames.finishPermissionWizard:
          finished = true;
          return null;
        case MethodNames.closePermissionWizard:
          closed = true;
          return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const PermissionWizardApp());
    await tester.pump();
    expect(find.text('申请录屏权限'), findsOneWidget);

    screen = true;
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall(MethodNames.permissionStatusChanged),
      ),
      (_) {},
    );
    await tester.pump();
    await tester.pump();
    expect(closed, isFalse);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '进入应用'))
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.text('稍后'));
    await tester.pump();
    expect(finished, isTrue);
    expect(closed, isTrue);
  });

  testWidgets('申请权限等待期间仅对应按钮显示进度环，完成后收起（#142）', (tester) async {
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final pending = Completer<void>();
    var screen = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.permissionWizardStatus:
          return {
            'accessibility': false,
            'screenAccess': screen,
            'finishedOrSkipped': false,
          };
        case MethodNames.requestScreenAccess:
          await pending.future;
          screen = true;
          return {'screenAccess': true};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const PermissionWizardApp());
    await tester.pumpAndSettle();
    BusyRing ringFor(String label) => tester.widget<BusyRing>(
      find
          .ancestor(of: find.text(label), matching: find.byType(BusyRing))
          .first,
    );

    await tester.tap(find.text('申请录屏权限'));
    await tester.pump();
    expect(ringFor('申请录屏权限').active, isTrue);
    expect(ringFor('授权辅助功能').active, isFalse);

    pending.complete();
    await tester.pumpAndSettle();
    expect(ringFor('已完成').active, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('小尺寸窗口正文可滚动且无溢出，授权失败报错在重试后清除（#144）', (tester) async {
    tester.view.physicalSize = const Size(480, 260);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var accessibility = false;
    var failOpen = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.permissionWizardStatus:
          return {
            'accessibility': accessibility,
            'screenAccess': false,
            'finishedOrSkipped': false,
          };
        case MethodNames.openAccessibility:
          if (failOpen) {
            throw PlatformException(code: 'perm_err', message: '无法打开辅助功能设置');
          }
          accessibility = true;
          return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const PermissionWizardApp());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('授权辅助功能'));
    await tester.pumpAndSettle();
    expect(find.byType(NativeGlassBanner), findsOneWidget);
    expect(find.text('无法打开辅助功能设置'), findsOneWidget);

    failOpen = false;
    await tester.tap(find.text('授权辅助功能'));
    await tester.pumpAndSettle();
    expect(find.text('无法打开辅助功能设置'), findsNothing);
    expect(find.text('已完成'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
