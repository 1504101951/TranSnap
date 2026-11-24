import 'dart:async';
import 'dart:ui' as ui;

import 'package:translate_app/src/common/constants/error_codes.dart';
import 'package:translate_app/src/common/constants/glass_metrics.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/channel_names.dart';
import 'package:translate_app/src/common/constants/preference_keys.dart';
import 'package:translate_app/src/common/constants/screenshot_enums.dart';
import 'package:translate_app/src/common/constants/shortcut_keys.dart';
import 'package:translate_app/src/common/constants/text_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/settings/service_config.dart';
import 'package:translate_app/src/settings/settings_app.dart';
import 'package:translate_app/src/settings/sticker_upload_dialog.dart';
import 'package:flutter/gestures.dart';

import 'support/settings_pages.dart';

/// 无参数；验证真实表单在菜单刷新时保留草稿，并阻止过期设置覆盖。
void main() {
  testWidgets('菜单更新不会覆盖未保存编辑，显式重新加载才替换表单', (tester) async {
    const channel = MethodChannel(ChannelNames.settings);
    const codec = StandardMethodCodec();
    var revision = 0;
    final pending = Completer<void>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map);
        await pending.future;
        if (draft['revision'] != revision) {
          throw PlatformException(
            code: ErrorCodes.settingsConflict,
            message: '设置版本冲突',
          );
        }
        return {...draft, 'revision': ++revision};
      }
      if (call.method == MethodNames.getSettings) {
        return {
          PreferenceKeys.primaryLanguage: revision == 0 ? 'zh-CN' : 'ja',
          PreferenceKeys.secondaryLanguage: 'en',
          'revision': revision,
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '快捷键');
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is NativeGlassSwitchTile && w.title == '仅使用快捷键',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();
    revision = 1;
    pending.complete();
    await messenger.handlePlatformMessage(
      ChannelNames.settings,
      codec.encodeMethodCall(const MethodCall(MethodNames.refreshSettings)),
      (_) {},
    );
    await tester.pumpAndSettle();
    // 草稿仍保留中文和开启的仅快捷键开关，不用检查通道调用次数代替用户结果。
    expect(
      tester
          .widget<NativeGlassSwitch>(find.byType(NativeGlassSwitch).first)
          .value,
      isTrue,
    );
    await openSettingsPage(tester, '语言与服务');
    expect(find.text('简体中文'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('重新加载设置'),
      300,
      scrollable: settingsContentScrollable(),
    );
    await tester.pumpAndSettle();
    expect(find.text('保存设置'), findsNothing);
    expect(find.text('重试自动保存'), findsNothing);
    await tester.tap(find.text('重新加载设置'));
    await tester.pumpAndSettle();
    await tester.drag(settingsContentList(), const Offset(0, 1800));
    await tester.pumpAndSettle();
    expect(find.text('日本語'), findsOneWidget);
    await openSettingsPage(tester, '快捷键');
    expect(
      tester
          .widget<NativeGlassSwitch>(find.byType(NativeGlassSwitch).first)
          .value,
      isFalse,
    );
  });

  testWidgets('录制数字组合后显示真实快捷键，取消保留当前组合', (tester) async {
    const channel = MethodChannel(ChannelNames.settings);
    var cancel = false;
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
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map);
        return {...draft, 'revision': (draft['revision'] as int) + 1};
      }
      if (call.method == MethodNames.recordShortcut) {
        return cancel ? null : {'keyCode': 18, 'modifiers': 4352, 'label': '1'};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '快捷键');
    // 先滚入视口再录制，避免点到不可命中区域。
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('全局翻译快捷键')),
      300,
      scrollable: settingsContentScrollable(),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('全局翻译快捷键')));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('⌃ ⌘ 1'), findsOneWidget);
    for (final token in ['⌃', '⌘', '1']) {
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('全局翻译快捷键')),
          matching: find.text(token),
        ),
        findsOneWidget,
      );
    }
    cancel = true;
    await tester.tap(find.byKey(const ValueKey('全局翻译快捷键')));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('⌃ ⌘ 1'), findsOneWidget);
  });
  testWidgets('添加服务、测试草稿、默认切换和删除通过保存形成实际状态', (tester) async {
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var state = <String, Object?>{'revision': 0};
    var credentialIds = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) {
        return {...state, MethodNames.credentialIds: credentialIds};
      }
      if (call.method == MethodNames.testService) {
        // 测试连接不得使主偏好提前包含新服务。
        expect(state[PreferenceKeys.services], isNull);
        return '你好，世界。';
      }
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map);
        final credentials = draft.remove('credentials') as Map;
        final services = draft[PreferenceKeys.services] as List;
        credentialIds = services
            .map((e) => (e as Map)['id'] as String)
            .toList();
        if (credentials.isNotEmpty && services.isNotEmpty) {
          expect(credentials[credentialIds.single], {
            'apiKey': 'test-key',
            'appId': 'test-app',
          });
          expect((services.single as Map).containsKey('apiKey'), false);
        }
        state = {...draft, 'revision': (state['revision'] as int) + 1};
        return {...state, MethodNames.credentialIds: credentialIds};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '服务列表');
    await tester.tap(find.text('添加服务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('请填写 API Key／密钥，百度翻译还需要 App ID。'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('百度 App ID')), 'test-app');
    await tester.enterText(find.byKey(const ValueKey('百度密钥')), 'test-key');
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('连接成功：你好，世界。'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('百度翻译'), findsWidgets);
    await openSettingsPage(tester, '语言与服务');
    final selector = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is NativeGlassDropdown<String> && w.label == '默认翻译服务',
      ),
      matching: find.byType(TextButton),
    );
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '百度翻译'));
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '快捷键');
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is NativeGlassSwitchTile && w.title == '仅使用快捷键',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();
    expect(state[PreferenceKeys.defaultServiceId], credentialIds.single);
    expect(state[PreferenceKeys.automatic], false);
    expect(find.text('已自动保存'), findsNothing);
    await openSettingsPage(tester, '服务列表');
    await tester.ensureVisible(find.byTooltip('删除 百度翻译'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('删除 百度翻译'), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(state[PreferenceKeys.services], hasLength(1));

    await tester.tap(find.byTooltip('删除 百度翻译'), warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(state[PreferenceKeys.services], isEmpty);
    expect(state[PreferenceKeys.defaultServiceId], 'unofficial-google');
  });

  testWidgets('侧边栏：点选二级行切换子页并显示标题，一级标签不切换，切换保留未保存草稿', (tester) async {
    // 边界：「通用」「翻译」「截图」是只作标签的一级行，点击后仍停在当前子页；「MCP」本身是子页，「个性化」在「通用」之下；
    // 标题与侧边栏同名，所以可见文字出现 2 次；快捷键页开启的开关在往返其他子页后仍为开启。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true, 'loginItems': 'enabled'};
      }
      if (call.method == MethodNames.getSettings) {
        return {
          PreferenceKeys.primaryLanguage: 'zh-CN',
          PreferenceKeys.secondaryLanguage: 'en',
          'revision': 0,
          PreferenceKeys.screenshotSaveDirectory: '/tmp/shots',
        };
      }
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map);
        return {...draft, 'revision': (draft['revision'] as int) + 1};
      }
      if (call.method == MethodNames.chooseScreenshotDirectory) {
        return '/tmp/chosen';
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();

    // 默认「权限与启动」子页：侧边栏行与标题各一处；登录与权限可见，其他子页内容不可见。
    expect(find.text('权限与启动'), findsNWidgets(2));
    expect(find.text('通用'), findsOneWidget);
    expect(find.text('登录时启动'), findsOneWidget);
    expect(find.text('屏幕录制'), findsOneWidget);
    expect(find.text('翻译语言'), findsNothing);
    expect(find.text('截图目录'), findsNothing);
    for (final label in [
      '通用',
      '权限与启动',
      '个性化',
      '翻译',
      '语言与服务',
      '服务列表',
      '快捷键',
      '排除应用',
      '截图',
      '保存与导出',
      '录制',
      '操作',
      '贴纸',
      '工具栏',
      'MCP',
    ]) {
      expect(settingsSidebarRow(label), findsOneWidget);
    }

    // 一级标签不可点：停留在「权限与启动」子页。
    await tester.tap(settingsSidebarRow('通用'));
    await tester.pumpAndSettle();
    await tester.tap(settingsSidebarRow('翻译'));
    await tester.pumpAndSettle();
    await tester.tap(settingsSidebarRow('截图'));
    await tester.pumpAndSettle();
    expect(find.text('登录时启动'), findsOneWidget);
    expect(find.text('翻译'), findsOneWidget);
    expect(find.text('截图'), findsOneWidget);

    await openSettingsPage(tester, '快捷键');
    expect(find.text('快捷键'), findsNWidgets(2));
    expect(find.text('登录时启动'), findsNothing);
    expect(find.text('仅使用快捷键'), findsOneWidget);
    expect(find.byKey(const ValueKey('全局翻译快捷键')), findsOneWidget);
    expect(find.text('翻译语言'), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is NativeGlassSwitchTile && w.title == '仅使用快捷键',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();

    // 在翻译一级行上点击仍停留在快捷键子页。
    await tester.tap(settingsSidebarRow('翻译'));
    await tester.pumpAndSettle();
    expect(find.text('仅使用快捷键'), findsOneWidget);

    await openSettingsPage(tester, '保存与导出');
    expect(find.text('保存与导出'), findsNWidgets(2));
    expect(find.text('截图目录'), findsOneWidget);
    expect(find.text('/tmp/shots'), findsOneWidget);
    expect(find.text('仅使用快捷键'), findsNothing);
    await tester.tap(find.text('选择路径'));
    await tester.pumpAndSettle();
    expect(find.text('/tmp/chosen'), findsOneWidget);

    // 录制子页放置三个录制相关开关，不含截图目录。
    await openSettingsPage(tester, '录制');
    expect(find.text('实时翻译时同时录制'), findsOneWidget);
    expect(find.text('截图目录'), findsNothing);

    // 操作子页放置区域截图快捷键。
    await openSettingsPage(tester, '操作');
    expect(find.byKey(const ValueKey('区域截图快捷键')), findsOneWidget);

    // 工具栏子页直接展示网格编辑器，无需展开，也不弹出对话框，且只含可拼接功能（#141）。
    await openSettingsPage(tester, '工具栏');
    expect(find.byType(Dialog), findsNothing);
    expect(
      find.byKey(const ValueKey('toolbar-cell-screenshot-tool-cursor')),
      findsOneWidget,
    );
    expect(find.text('增大字号'), findsNothing);
    expect(find.text('在 Finder 中显示'), findsNothing);

    await openSettingsPage(tester, '快捷键');
    expect(
      tester
          .widget<NativeGlassSwitch>(find.byType(NativeGlassSwitch).first)
          .value,
      isTrue,
    );
    await openSettingsPage(tester, '语言与服务');
    expect(find.text('翻译语言'), findsOneWidget);
    expect(find.text('简体中文'), findsOneWidget);
  });

  testWidgets('截图子页保存GIF帧率与最大宽度，留空恢复原宽且非法值不保存', (tester) async {
    // 600是有效压缩上限；0非法、空值是不限制，保存后的重新加载必须保留用户选择。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var settings = <String, Object?>{'revision': 0};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return settings;
      if (call.method == MethodNames.saveSettings) {
        settings = {
          ...Map<String, Object?>.from(call.arguments as Map),
          'revision': (settings['revision'] as int) + 1,
        };
        return settings;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '保存与导出');
    // 截图目录行以「截图目录」为标题，未设置时说明行显示默认位置。
    expect(find.text('截图目录'), findsOneWidget);
    expect(find.text('系统图片目录/截图'), findsOneWidget);
    expect(find.text('每次询问'), findsNothing);
    expect(find.text('10 fps'), findsOneWidget);
    final width = find.byKey(const Key('gif-maximum-width'));
    await tester.ensureVisible(width);
    await tester.enterText(width, '600');
    await tester.pumpAndSettle();
    expect(settings[PreferenceKeys.gifMaximumWidth], 600);
    // 输入框滚动后帧率下拉可能离开视口，点击前先滚入可见区域。
    await tester.ensureVisible(find.text('10 fps'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10 fps'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('15 fps'));
    await tester.tap(find.text('15 fps'));
    await tester.pumpAndSettle();
    expect(settings[PreferenceKeys.gifFramesPerSecond], 15);
    await tester.enterText(width, '0');
    await tester.pumpAndSettle();
    expect(settings[PreferenceKeys.gifMaximumWidth], 600);
    await tester.scrollUntilVisible(
      find.textContaining('最大宽度须为正整数'),
      150,
      scrollable: settingsContentScrollable(),
    );
    expect(find.textContaining('最大宽度须为正整数'), findsOneWidget);
    // 滚到底部提示后输入框可能已移出按需构建范围，反向滚回。
    await tester.scrollUntilVisible(
      width,
      -150,
      scrollable: settingsContentScrollable(),
    );
    await tester.enterText(width, '');
    await tester.pumpAndSettle();
    expect(settings.containsKey(PreferenceKeys.gifMaximumWidth), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '保存与导出');
    expect(find.text('15 fps'), findsOneWidget);
    expect(tester.widget<TextField>(width).controller!.text, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('贴纸：添加时按原图比例给出默认大小，拖角缩小后保存；删除移除设置与文件（#103）', (tester) async {
    // 边界：1000×500 的图默认 512×256pt；把右下角拖到预览中心右 50pt、下 10pt 处，宽度决定大小，长边变为
    // 100/预览比例 ≈ 173pt（短于 512 但大于 16）；提交的 stickers 宽高与说明一致；删除后列表为空并请求删除文件。
    final png = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xFFFF0000), BlendMode.src);
      final image = await recorder.endRecording().toImage(1000, 500);
      return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
          .asUint8List();
    });
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var settings = <String, Object?>{'revision': 0};
    final saved = <String>[];
    final deleted = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      switch (call.method) {
        case MethodNames.systemStatus:
          return {'accessibility': true};
        case MethodNames.getSettings:
          return settings;
        case MethodNames.importStickerImage:
          return {'bytes': png, 'width': 1000, 'height': 500};
        case MethodNames.saveSticker:
          saved.add((call.arguments as Map)['id'] as String);
          return '/tmp/x.png';
        case MethodNames.deleteSticker:
          deleted.add((call.arguments as Map)['id'] as String);
          return null;
        case MethodNames.saveSettings:
          final draft = Map<String, Object?>.from(call.arguments as Map)
            ..remove('credentials');
          settings = {...draft, 'revision': (settings['revision'] as int) + 1};
          return settings;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '贴纸');
    expect(find.text('还没有贴纸'), findsOneWidget);
    await tester.ensureVisible(find.text('添加图片'));
    await tester.tap(find.text('添加图片'));
    await tester.pumpAndSettle();
    expect(find.text('默认大小 512 × 256 pt'), findsOneWidget);
    final handle = find.byKey(const ValueKey('sticker-handle-3'));
    final preview = find
        .ancestor(of: handle, matching: find.byType(SizedBox))
        .first;
    final center = tester.getCenter(preview);
    // 分步移动越过手势判定距离，最终指针在中心右 50pt、下 10pt：横向决定大小。
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(-30, -30));
    await gesture.moveTo(center + const Offset(50, 10));
    await gesture.up();
    await tester.pumpAndSettle();
    final long = (100 / StickerUploadDialog.previewScale).round();
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();
    final stickers = settings[PreferenceKeys.stickers] as List;
    expect(saved, hasLength(1));
    expect((stickers.single as Map)['id'], saved.single);
    expect(((stickers.single as Map)['width'] as num).round(), long);

    final thumbnail = find.byKey(ValueKey('sticker-${saved.single}'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(thumbnail));
    addTearDown(mouse.removePointer);
    await tester.pump();
    await tester.tap(find.byTooltip('删除贴纸'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(settings[PreferenceKeys.stickers], hasLength(1));

    await tester.tap(find.byTooltip('删除贴纸'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(settings[PreferenceKeys.stickers], isEmpty);
    expect(deleted, saved);
  });

  testWidgets('翻译语言分段：切到输入翻译只修改输入翻译的一组语言，全局不变（#99）', (tester) async {
    // 边界：全局 zh-CN/en，输入翻译未设置时显示复制的 zh-CN/en；切到「输入翻译」把次要语言改为日本語，
    // 提交后输入翻译次要语言为 ja，全局次要语言仍为 en。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var settings = <String, Object?>{
      'revision': 0,
      PreferenceKeys.primaryLanguage: 'zh-CN',
      PreferenceKeys.secondaryLanguage: 'en',
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return settings;
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        settings = {...draft, 'revision': (settings['revision'] as int) + 1};
        return settings;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '语言与服务');
    await tester.tap(find.text('输入翻译').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('日本語').last);
    await tester.pumpAndSettle();
    expect(settings[PreferenceKeys.inputSecondaryLanguage], 'ja');
    expect(settings[PreferenceKeys.secondaryLanguage], 'en');
    expect(settings[PreferenceKeys.inputPrimaryLanguage], 'zh-CN');
    expect(tester.takeException(), isNull);
  });
  testWidgets('提示词：四个字段、恢复默认、空提示词不能保存，保存后自动提交提示词与思考开关', (tester) async {
    // 边界：初始润色为自定义值时「恢复默认」可用，点击后回到默认值且按钮禁用；
    // 纠错清空时显示「提示词不能为空。」且「保存」禁用；填回后保存，提交的偏好含四种提示词；
    // 弹窗恰有翻译、润色、纠错、解释四个字段，只打开润色思考开关时只有 polishThinking 为 true。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var settings = <String, Object?>{
      'revision': 0,
      PreferenceKeys.prompts[TextMode.polish]!: '自定义润色',
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return settings;
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        settings = {...draft, 'revision': (settings['revision'] as int) + 1};
        return settings;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '语言与服务');
    await tester.ensureVisible(find.text('编辑提示词'));
    await tester.tap(find.text('编辑提示词'));
    await tester.pumpAndSettle();

    for (final label in ['翻译', '润色', '纠错', '解释']) {
      expect(find.byKey(ValueKey('提示词-$label')), findsOneWidget);
      expect(find.byKey(ValueKey('思考-$label')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('思考-润色')));
    await tester.pumpAndSettle();

    TextButton restore(String label) =>
        tester.widget<TextButton>(find.byKey(ValueKey('恢复默认-$label')));
    expect(restore('润色').onPressed, isNotNull);
    expect(restore('纠错').onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('恢复默认-润色')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(restore('润色').onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('恢复默认-润色')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '恢复默认'));
    await tester.pumpAndSettle();
    expect(restore('润色').onPressed, isNull);

    await tester.enterText(find.byKey(const ValueKey('提示词-纠错')), '');
    await tester.pumpAndSettle();
    expect(find.text('提示词不能为空。'), findsOneWidget);
    FilledButton save() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '保存'));
    expect(save().onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('提示词-纠错')), '只纠错');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(
      settings[PreferenceKeys.prompts[TextMode.polish]!],
      defaultPrompts[TextMode.polish],
    );
    expect(settings[PreferenceKeys.prompts[TextMode.correct]!], '只纠错');
    expect(settings[PreferenceKeys.thinking[TextMode.polish]!], isTrue);
    for (final mode in [
      TextMode.translate,
      TextMode.correct,
      TextMode.explain,
    ]) {
      expect(settings[PreferenceKeys.thinking[mode]!], isFalse);
    }
    expect(
      settings[PreferenceKeys.prompts[TextMode.explain]!],
      defaultPrompts[TextMode.explain],
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('截图子页确认动作：下拉只提供复制图片与复制并保存，选择后自动保存（#111）', (tester) async {
    // 边界：缺省为复制图片；下拉恰好两项，选「复制并保存」后提交的偏好值为 copyAndSave。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var settings = <String, Object?>{'revision': 0};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return settings;
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        settings = {...draft, 'revision': (settings['revision'] as int) + 1};
        return settings;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '操作');
    final scrollable = settingsContentScrollable();
    await tester.scrollUntilVisible(
      find.text('复制图片'),
      150,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制图片'));
    await tester.pumpAndSettle();
    expect(find.text('复制并保存'), findsWidgets);
    await tester.tap(find.text('复制并保存').last);
    await tester.pumpAndSettle();
    expect(settings[PreferenceKeys.screenshotConfirmAction], 'copyAndSave');
    expect(tester.takeException(), isNull);
  });
  testWidgets('术语表：管理弹窗内添加、编辑与删除即时自动保存，同一目标语言下重复时留在编辑弹窗提示', (tester) async {
    // 边界：新增 api 与已有 API 只差大小写，视为重复；编辑条目本身不算与自己重复；
    // 原文术语为空时「确定」不可用；译法留空显示为保留原文。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var state = <String, Object?>{
      'revision': 0,
      PreferenceKeys.primaryLanguage: 'zh-CN',
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) {
        return {...state, MethodNames.credentialIds: <String>[]};
      }
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        state = {...draft, 'revision': (state['revision'] as int) + 1};
        return {...state, MethodNames.credentialIds: <String>[]};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '语言与服务');
    await tester.tap(find.text('管理术语（0）'));
    await tester.pumpAndSettle();
    expect(find.text('暂无术语'), findsOneWidget);

    /// term/translation 为弹窗输入；打开添加弹窗、填写并点击确定。
    Future<void> add(String term, String translation) async {
      await tester.tap(find.text('添加术语'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byKey(const ValueKey('原文术语')), term);
      await tester.enterText(find.byKey(const ValueKey('译法')), translation);
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
    }

    /// 无参数；返回已保存偏好中的术语表。
    List<Object?> saved() => state[PreferenceKeys.glossary] as List;

    await add('API', '应用接口');
    expect(saved(), [
      {'term': 'API', 'translation': '应用接口', 'language': 'zh-CN'},
    ]);
    expect(find.text('API → 应用接口'), findsOneWidget);

    await add('api', '接口');
    expect(find.text('该目标语言下已有此术语。'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('原文术语')), 'Kubernetes');
    await tester.enterText(find.byKey(const ValueKey('译法')), '');
    await tester.pump();
    expect(find.text('该目标语言下已有此术语。'), findsNothing);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('Kubernetes（保留原文）'), findsOneWidget);
    expect(saved(), hasLength(2));

    await tester.tap(find.byTooltip('编辑 API'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('译法')), '接口');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect((saved().first as Map)['translation'], '接口');

    await tester.tap(find.byTooltip('删除 Kubernetes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(saved(), hasLength(2));

    await tester.tap(find.byTooltip('删除 Kubernetes'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(saved(), [
      {'term': 'API', 'translation': '接口', 'language': 'zh-CN'},
    ]);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('管理术语（1）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('截图子页「长截图 → 滚动方式」默认手动滚动，选自动滚动后自动保存到偏好（#112）', (tester) async {
    // 边界：偏好缺省时显示「手动滚动」；选「自动滚动」后偏好值为 automatic。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var state = <String, Object?>{'revision': 0};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) {
        return {...state, MethodNames.credentialIds: <String>[]};
      }
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        state = {...draft, 'revision': (state['revision'] as int) + 1};
        return {...state, MethodNames.credentialIds: <String>[]};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '操作');
    await tester.scrollUntilVisible(
      find.text('手动滚动'),
      150,
      scrollable: settingsContentScrollable(),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('手动滚动'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动滚动').last);
    await tester.pumpAndSettle();
    expect(state[PreferenceKeys.scrollCaptureMode], 'automatic');
    expect(tester.takeException(), isNull);
  });
  testWidgets('截图录制页：指针开关默认关闭，点击特效下拉7项可选，右键与拖动区分默认开启并可自动保存（#105、#143）', (
    tester,
  ) async {
    // 边界：缺省时截图包含指针为 false、点击特效为 off、区分右键为 true；切换下拉与开关后各自写入规范偏好值。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var state = <String, Object?>{'revision': 0};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) {
        return {...state, MethodNames.credentialIds: <String>[]};
      }
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        state = {...draft, 'revision': (state['revision'] as int) + 1};
        return {...state, MethodNames.credentialIds: <String>[]};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '录制');

    final cursorTile = find.byWidgetPredicate(
      (w) => w is NativeGlassSwitchTile && w.title == '截图包含鼠标指针',
    );
    await tester.scrollUntilVisible(
      cursorTile,
      200,
      scrollable: settingsContentScrollable(),
    );
    expect(tester.widget<NativeGlassSwitchTile>(cursorTile).value, isFalse);
    await tester.tap(
      find.descendant(of: cursorTile, matching: find.byType(NativeGlassSwitch)),
    );
    await tester.pumpAndSettle();
    expect(state[PreferenceKeys.screenshotIncludesCursor], isTrue);

    final effectDropdown = find.byWidgetPredicate(
      (w) => w is NativeGlassDropdown<RecordingClickEffect>,
    );
    await tester.scrollUntilVisible(
      effectDropdown,
      200,
      scrollable: settingsContentScrollable(),
    );
    expect(
      tester
          .widget<NativeGlassDropdown<RecordingClickEffect>>(effectDropdown)
          .value,
      RecordingClickEffect.off,
    );
    await tester.tap(
      find.descendant(of: effectDropdown, matching: find.text('关闭')),
    );
    await tester.pumpAndSettle();
    for (final effect in RecordingClickEffect.values) {
      expect(find.text(effect.label), findsWidgets);
    }
    await tester.tap(find.text('光学涟漪').last);
    await tester.pumpAndSettle();
    expect(state[PreferenceKeys.recordingClickEffect], 'optical');

    final distinctTile = find.byWidgetPredicate(
      (w) => w is NativeGlassSwitchTile && w.title == '区分右键与拖动轨迹',
    );
    await tester.scrollUntilVisible(
      distinctTile,
      200,
      scrollable: settingsContentScrollable(),
    );
    expect(tester.widget<NativeGlassSwitchTile>(distinctTile).value, isTrue);
    await tester.tap(
      find.descendant(
        of: distinctTile,
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();
    expect(state[PreferenceKeys.recordingClickRightDistinct], isFalse);
  });

  testWidgets('默认翻译服务下拉固定先列谷歌翻译与 Apple 系统翻译，选中 Apple 保存内置 ID，服务列表不出现 Apple', (
    tester,
  ) async {
    // 边界：已配置一个 OpenAI 服务；下拉恰为谷歌、Apple、OpenAI 三项且内置项在前；
    // 选 Apple 后偏好为 apple-system；服务列表只含已配置服务，不含 Apple。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var state = <String, Object?>{
      'revision': 0,
      PreferenceKeys.services: [
        const ServiceConfig(
          id: 'saved',
          kind: 'openai',
          name: 'OpenAI',
          baseUrl: 'https://api.openai.com',
          model: 'gpt-test',
        ).toMap(),
      ],
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.checkSystemTranslation:
          return languagePackInstalledStatus;
        case MethodNames.systemStatus:
          return {'accessibility': true};
        case MethodNames.getSettings:
          return {
            ...state,
            MethodNames.credentialIds: <String>['saved'],
          };
        case MethodNames.saveSettings:
          final draft = Map<String, Object?>.from(call.arguments as Map)
            ..remove('credentials');
          state = {...draft, 'revision': (state['revision'] as int) + 1};
          return {
            ...state,
            MethodNames.credentialIds: <String>['saved'],
          };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();

    await openSettingsPage(tester, '语言与服务');
    final selector = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is NativeGlassDropdown<String> && w.label == '默认翻译服务',
      ),
      matching: find.byType(TextButton),
    );
    await tester.tap(selector);
    await tester.pumpAndSettle();
    final items = find.byType(MenuItemButton);
    expect(items, findsNWidgets(3));
    double top(String label) =>
        tester.getTopLeft(find.widgetWithText(MenuItemButton, label)).dy;
    expect(top('谷歌翻译'), lessThan(top('Apple 系统翻译')));
    expect(top('Apple 系统翻译'), lessThan(top('OpenAI')));
    expect(find.widgetWithText(MenuItemButton, '谷歌翻译'), findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, 'Apple 系统翻译'), findsOneWidget);
    expect(find.widgetWithText(MenuItemButton, 'OpenAI'), findsOneWidget);
    await tester.tap(find.widgetWithText(MenuItemButton, 'Apple 系统翻译'));
    await tester.pumpAndSettle();
    expect(state[PreferenceKeys.defaultServiceId], ServiceConfig.systemId);

    await openSettingsPage(tester, '服务列表');
    expect(find.byTooltip('编辑 OpenAI'), findsOneWidget);
    expect(find.textContaining('Apple'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('通用子页显示语言包状态：查询中为检查中，成功显示说明，失败显示异常说明', (tester) async {
    // 边界：通道未返回前显示「正在检查语言包…」；返回字符串时原样显示；
    // 抛 PlatformException 时显示其 message，不显示检查中。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var reply = Completer<String>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.checkSystemTranslation:
          return reply.future;
        case MethodNames.systemStatus:
          return {'accessibility': true};
        case MethodNames.getSettings:
          return {'revision': 0};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pump();
    await tester.pump();
    expect(find.text('正在检查语言包…'), findsOneWidget);
    expect(find.text('Apple 离线翻译语言包'), findsOneWidget);
    expect(find.text('管理'), findsOneWidget);

    reply.complete('语言包已安装：English → 简体中文');
    await tester.pumpAndSettle();
    expect(find.text('语言包已安装：English → 简体中文'), findsOneWidget);
    expect(find.text('正在检查语言包…'), findsNothing);

    // 离开再回到通用子页会重新查询；这次以异常返回。
    reply = Completer<String>();
    await openSettingsPage(tester, '快捷键');
    await openSettingsPage(tester, '权限与启动');
    expect(find.text('正在检查语言包…'), findsOneWidget);
    reply.completeError(
      PlatformException(
        code: ErrorCodes.testFailed,
        message: '日语 → 简体中文 语言包未安装',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('日语 → 简体中文 语言包未安装'), findsOneWidget);
    expect(find.text('正在检查语言包…'), findsNothing);
  });

  testWidgets('全局与输入快捷键录制状态隔离，切页取消录制且不阻塞非快捷键按钮（#144）', (tester) async {
    // 作用：验证双快捷键各自独立展示等待提示、切页自动中止录制且丢弃迟到热键结果。
    // 边界：点击「全局翻译快捷键」仅该钮变为等待态，离开到「通用」仍可申请权限，迟到回包不触发保存。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final pendingShortcut = Completer<Map<String, Object>?>();
    var saved = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.checkSystemTranslation:
          return languagePackInstalledStatus;
        case MethodNames.systemStatus:
          return {'accessibility': true, 'screenAccess': false};
        case MethodNames.getSettings:
          return {'revision': 0};
        case MethodNames.recordShortcut:
          return pendingShortcut.future;
        case MethodNames.saveSettings:
          saved = true;
          return {'revision': 1};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '快捷键');

    await tester.tap(find.byKey(const ValueKey('全局翻译快捷键')));
    await tester.pump();
    expect(find.text('请按下组合键，Esc 取消…'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('输入翻译快捷键')))
          .onPressed,
      isNull,
    );

    await openSettingsPage(tester, '权限与启动');
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '授权…'))
          .onPressed,
      isNotNull,
    );

    pendingShortcut.complete({'keyCode': 1, 'modifiers': 256, 'label': '⌘ S'});
    await tester.pumpAndSettle();
    expect(saved, isFalse);

    await openSettingsPage(tester, '快捷键');
    expect(find.text('请按下组合键，Esc 取消…'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('服务与排除应用空态提示、录屏特效联动禁用及 GIF 最大宽度就地校验（#144）', (tester) async {
    // 作用：验证列表空态引导文案、关闭录屏点击特效时随动禁用衍生开关，以及 GIF 宽度就地内联报错。
    // 边界：services 与 excludedApps 为空展示引导；off 态禁用「区分右键与拖动轨迹」；输入 0 展示内联 errorText。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var state = <String, Object?>{'revision': 0};
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.checkSystemTranslation:
          return languagePackInstalledStatus;
        case MethodNames.systemStatus:
          return {'accessibility': true, 'screenAccess': true};
        case MethodNames.getSettings:
          return state;
        case MethodNames.saveSettings:
          final draft = Map<String, Object?>.from(call.arguments as Map)
            ..remove('credentials');
          state = {...draft, 'revision': (state['revision'] as int) + 1};
          return state;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();

    await openSettingsPage(tester, '服务列表');
    expect(find.text('暂无自定义翻译服务；默认使用谷歌翻译或 Apple 系统翻译。'), findsOneWidget);

    await openSettingsPage(tester, '排除应用');
    expect(find.text('暂无排除应用；添加后在这些应用中不会自动触发选区翻译。'), findsOneWidget);

    await openSettingsPage(tester, '录制');
    NativeGlassSwitch distinctSwitch() => tester.widget<NativeGlassSwitch>(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is NativeGlassSwitchTile && w.title == '区分右键与拖动轨迹',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    expect(distinctSwitch().onChanged, isNull);

    await tester.tap(find.text(RecordingClickEffect.off.label));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(MenuItemButton, RecordingClickEffect.optical.label),
    );
    await tester.pumpAndSettle();
    expect(distinctSwitch().onChanged, isNotNull);

    await openSettingsPage(tester, '保存与导出');
    final width = find.byKey(const Key('gif-maximum-width'));
    await tester.ensureVisible(width);
    await tester.enterText(width, '0');
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is NativeGlassField &&
            w.label == '最大宽度（像素）' &&
            w.errorText == '请输入大于 0 的整数像素宽度，留空表示不限制。',
      ),
      findsOneWidget,
    );
  });

  testWidgets('快捷键按钮在字符宽度不同时保持统一最小宽度与左右对齐（#67）', (tester) async {
    // 作用：验证全局翻译快捷键与输入翻译快捷键按钮在使用窄/宽不同字符标签时保持统一宽度与左右边界对齐。
    // 边界：@ 与 ! 的字符宽度不同，按钮宽度均应 >= GlassMetrics.shortcutButtonMinWidth（128pt）且左右边缘差 <= 0.01pt。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.checkSystemTranslation:
          return languagePackInstalledStatus;
        case MethodNames.systemStatus:
          return {'accessibility': true, 'screenAccess': true};
        case MethodNames.getSettings:
          return {
            'revision': 0,
            PreferenceKeys.shortcutKeyCode: 19,
            PreferenceKeys.shortcutModifiers:
                ShortcutKeys.shift | ShortcutKeys.command,
            PreferenceKeys.shortcutLabel: '@',
            PreferenceKeys.inputShortcutKeyCode: 18,
            PreferenceKeys.inputShortcutModifiers:
                ShortcutKeys.shift | ShortcutKeys.command,
            PreferenceKeys.inputShortcutLabel: '!',
          };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '快捷键');

    final globalRect = tester.getRect(find.byKey(const ValueKey('全局翻译快捷键')));
    final inputRect = tester.getRect(find.byKey(const ValueKey('输入翻译快捷键')));
    expect(
      globalRect.width,
      greaterThanOrEqualTo(GlassMetrics.shortcutButtonMinWidth),
    );
    expect(
      inputRect.width,
      greaterThanOrEqualTo(GlassMetrics.shortcutButtonMinWidth),
    );
    expect((globalRect.width - inputRect.width).abs(), lessThanOrEqualTo(0.01));
    expect((globalRect.left - inputRect.left).abs(), lessThanOrEqualTo(0.01));
    expect((globalRect.right - inputRect.right).abs(), lessThanOrEqualTo(0.01));
  });
}
