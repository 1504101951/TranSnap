import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/appearance_modes.dart';
import 'package:transnap/src/common/constants/channel_names.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/text_mode.dart';
import 'package:transnap/src/common/widgets/app_motion.dart';
import 'package:transnap/src/common/widgets/native_glass.dart';
import 'package:transnap/src/settings/glossary_editor.dart';
import 'package:transnap/src/settings/prompt_editor.dart';
import 'package:transnap/src/settings/service_config.dart';
import 'package:transnap/src/settings/service_editor.dart';
import 'package:transnap/src/settings/sticker_upload_dialog.dart';
import 'package:transnap/src/translation/glossary.dart';

/// 无参数；验证设置页各独立弹窗子编辑器的 UI/UX 规范加固项（#144）。
void main() {
  testWidgets('PromptEditor 消除重复标题、报错内联归属，恢复默认需二次确认（#144）', (tester) async {
    // 作用：验证各字段只渲染单份标题，清空后错误落在 NativeGlassField.errorText 内，恢复默认有二次确认防误触。
    // 边界：「润色」修改过时「恢复默认」可点；取消确认保持修改，点击「恢复默认」确认后归位默认。
    await tester.pumpWidget(
      NativeGlassApp(
        home: Scaffold(
          body: PromptEditor(
            prompts: {
              ...defaultPrompts,
              TextMode.polish: '自定义润色提示词',
            },
            thinking: {for (final mode in TextMode.values) mode: false},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('以下提示词所有模型服务共用。'), findsOneWidget);
    expect(find.textContaining('思考只对 DeepSeek'), findsNothing);
    for (final label in ['翻译', '润色', '纠错', '解释']) {
      expect(find.text(label), findsOneWidget);
    }

    await tester.enterText(find.byKey(const ValueKey('提示词-纠错')), '  ');
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is NativeGlassField &&
            widget.semanticLabel == '纠错' &&
            widget.errorText == '提示词不能为空。',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('恢复默认-润色')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('提示词-润色')))
          .controller!
          .text,
      '自定义润色提示词',
    );

    await tester.tap(find.byKey(const ValueKey('恢复默认-润色')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '恢复默认'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('提示词-润色')))
          .controller!
          .text,
      defaultPrompts[TextMode.polish],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('PromptEditor 矮窗可滚动且隐藏滚动条避免遮挡右侧操作按钮（#67）', (tester) async {
    // 作用：验证提示词弹窗隐藏默认桌面滚动条，避免覆盖右侧「恢复默认」按钮，同时在矮窗内保持可滚动访问。
    // 边界：视口高 480pt 时无 Scrollbar/RawScrollbar 实例，向上拖动表单滚动视图后底部「解释」输入框仍可达。
    tester.view.physicalSize = const Size(700, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      NativeGlassApp(
        home: Scaffold(
          body: PromptEditor(
            prompts: defaultPrompts,
            thinking: {for (final mode in TextMode.values) mode: false},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 弹窗外层表单不挂载滚动条（避免遮挡右侧「恢复默认」按钮）；仅多行输入框内部保留 Flutter 自身 EditableText 的 Scrollbar。
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('恢复默认-翻译')),
        matching: find.byType(Scrollbar),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey('恢复默认-翻译')),
        matching: find.byType(RawScrollbar),
      ),
      findsNothing,
    );
    expect(
      tester.widgetList(find.byType(Scrollbar)).length,
      tester
          .widgetList(
            find.descendant(
              of: find.byType(EditableText),
              matching: find.byType(Scrollbar),
            ),
          )
          .length,
    );

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();

    final explainField = find.byKey(const ValueKey('提示词-解释'));
    await tester.ensureVisible(explainField);
    await tester.pumpAndSettle();
    expect(explainField.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('StickerUploadDialog 480pt 矮窗可滚动无溢出、24pt 手柄命中区且支持滑块缩放与深色棋盘格（#144）', (
    tester,
  ) async {
    // 作用：验证设置窗最小高度（480pt）内弹窗滚动不溢出，手柄命中 ≥ 24pt，Slider 支持等比调整且深色不抛异常。
    // 边界：视口高 480pt 时无 RenderFlex overflow；200×100 原图滑块设为 100 时默认大小更新为 100 × 50 pt。
    tester.view.physicalSize = const Size(700, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    GlassAppearance.current.value = const GlassAppearance(
      mode: AppearanceModes.dark,
    );
    addTearDown(() {
      GlassAppearance.current.value = const GlassAppearance();
    });

    final pixel = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
    );
    await tester.pumpWidget(
      NativeGlassApp(
        home: Scaffold(
          body: StickerUploadDialog(
            bytes: Uint8List.fromList(pixel),
            pixelWidth: 200,
            pixelHeight: 100,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final handleSize = tester.getSize(
      find.byKey(const ValueKey('sticker-handle-0')),
    );
    expect(handleSize.width, greaterThanOrEqualTo(24));
    expect(handleSize.height, greaterThanOrEqualTo(24));

    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(100);
    await tester.pumpAndSettle();
    expect(find.text('默认大小 100 × 50 pt'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ServiceEditor 保留自定义名称、支持密钥显隐切换及测试连接忙碌态与横幅展示（#144）', (
    tester,
  ) async {
    // 作用：验证切服务类型不覆盖手填名称、密钥可见性切换及连接测试期间 BusyRing 与横幅反馈。
    // 边界：手填「自建名称」保留，未改动的默认 Base URL 随类型切换；testService 挂起时 BusyRing.active=true。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final pendingTest = Completer<String>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.testService) return pendingTest.future;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const NativeGlassApp(home: Scaffold(body: ServiceEditor())));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const ValueKey('配置名称')), '自建名称');
    await tester.pump();
    await tester.tap(find.text('百度翻译'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OpenAI'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('配置名称'))).controller!.text,
      '自建名称',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('API Base URL')))
          .controller!
          .text,
      ServiceConfig.endpoints['openai'],
    );

    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('API Key'))).obscureText,
      isTrue,
    );
    await tester.tap(find.byTooltip('显示密钥'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byKey(const ValueKey('API Key'))).obscureText,
      isFalse,
    );

    await tester.enterText(find.byKey(const ValueKey('模型名称')), 'gpt-4o-mini');
    await tester.enterText(find.byKey(const ValueKey('API Key')), 'sk-test');
    await tester.tap(find.text('测试连接'));
    await tester.pump();

    final busyRing = tester.widget<BusyRing>(
      find.ancestor(of: find.text('正在测试…'), matching: find.byType(BusyRing)).first,
    );
    expect(busyRing.active, isTrue);

    pendingTest.complete('连接正常');
    await tester.pumpAndSettle();
    expect(find.byType(NativeGlassBanner), findsOneWidget);
    expect(find.text('连接成功：连接正常'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('GlossaryEditor 重复术语内联报错且 GlossaryManager 删除需二次确认（#144）', (
    tester,
  ) async {
    // 作用：验证术语查重结果直接呈现在「原文术语」NativeGlassField 内，管理页删除需弹窗确认。
    // 边界：同语言忽略大小写重复「api」触发内联 errorText；取消删除保留原词，确认后显示「暂无术语」。
    const channel = MethodChannel(ChannelNames.settings);
    await tester.pumpWidget(
      NativeGlassApp(
        home: Scaffold(
          body: GlossaryManager(
            glossary: const [
              GlossaryEntry(
                term: 'API',
                translation: '接口',
                language: 'zh-CN',
              ),
            ],
            defaultLanguage: 'zh-CN',
            channel: channel,
            onChanged: (_) {},
            onImport: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加术语'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('原文术语')), 'api');
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is NativeGlassField &&
            widget.label == '原文术语' &&
            widget.errorText == '该目标语言下已有此术语。',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('删除 API'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('API → 接口'), findsOneWidget);

    await tester.tap(find.byTooltip('删除 API'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.text('暂无术语'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
