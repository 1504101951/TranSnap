import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/channel_names.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/preference_keys.dart';
import 'package:transnap/src/common/widgets/app_motion.dart';
import 'package:transnap/src/common/widgets/native_glass.dart';
import 'package:transnap/src/settings/app_settings.dart';
import 'package:transnap/src/settings/glossary_editor.dart';
import 'package:transnap/src/settings/settings_app.dart';

import 'support/settings_pages.dart';

import 'package:transnap/src/translation/glossary.dart';
import 'package:transnap/src/translation/glossary_file.dart';

Future<void> openPreview(
  WidgetTester tester, {
  required String source,
  required List<GlossaryEntry> existing,
  required Future<void> Function(List<GlossaryEntry>) submit,
}) async {
  await tester.pumpWidget(
    NativeGlassApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              barrierDismissible: false,
              builder: (_) => GlossaryImportPreview(
                name: '术语.json',
                draft: parseGlossaryFile(source, format: 'json'),
                existing: existing,
                onSubmit: submit,
              ),
            ),
            child: const Text('打开预览'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开预览'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('无效行禁用整批导入，取消保留已提交术语', (tester) async {
    final settings = AppSettings(
      primaryLanguage: 'zh-CN',
      glossary: [
        const GlossaryEntry(term: '已有', translation: '', language: 'en'),
      ],
    );
    await openPreview(
      tester,
      source:
          '[{"term":"API","translation":"接口","language":"zh-CN"},'
          '{"term":" ","translation":"","language":"en"}]',
      existing: settings.glossary,
      submit: (entries) async {
        settings.glossary
          ..clear()
          ..addAll(entries);
      },
    );
    expect(find.text('新增 1 · 重复 0 · 错误 1'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认导入'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(settings.glossary.single.term, '已有');
    expect(find.byType(GlossaryImportPreview), findsNothing);
  });

  testWidgets('预览保存真实校验失败保留草稿，修正配置后可重试成功', (tester) async {
    var settings = AppSettings(primaryLanguage: 'en', secondaryLanguage: 'en');
    await openPreview(
      tester,
      source: '[{"term":"API","translation":"接口","language":"zh-CN"}]',
      existing: settings.glossary,
      submit: (entries) async {
        final candidate = AppSettings.fromMap(settings.toMap());
        candidate.glossary.addAll(entries);
        candidate.validate();
        settings = candidate;
      },
    );
    await tester.tap(find.text('确认导入'));
    await tester.pumpAndSettle();
    expect(find.text('主要语言和次要语言必须不同。'), findsOneWidget);
    expect(find.text('API → 接口'), findsOneWidget);
    expect(settings.glossary, isEmpty);
    settings.primaryLanguage = 'zh-CN';
    settings.inputSecondaryLanguage = null;
    await tester.tap(find.text('确认导入'));
    await tester.pumpAndSettle();
    expect(settings.glossary.single.translation, '接口');
    expect(find.byType(GlossaryImportPreview), findsNothing);
  });

  testWidgets('默认保留已有值，选择覆盖后整批保存并等待实际完成', (tester) async {
    var saved = [
      const GlossaryEntry(term: 'API', translation: '现有', language: 'en'),
    ];
    final gate = Completer<void>();
    await openPreview(
      tester,
      source: '[{"term":"api","translation":"覆盖值","language":"en"}]',
      existing: saved,
      submit: (entries) async {
        await gate.future;
        saved = entries;
      },
    );
    expect(find.text('保留已有值'), findsOneWidget);
    await tester.tap(find.text('保留已有值'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '覆盖已有值'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认导入'));
    await tester.pump();
    expect(saved.single.translation, '现有');
    expect(find.text('保存中…'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
          .onPressed,
      isNull,
    );
    gate.complete();
    await tester.pumpAndSettle();
    expect(saved.single.translation, '覆盖值');
    expect(find.byType(GlossaryImportPreview), findsNothing);
  });

  testWidgets('先前自动保存未结束时导入等待后续完整事务，两个改动均持久化', (tester) async {
    final gate = Completer<void>();
    var saved = <String, Object?>{
      ...AppSettings(primaryLanguage: 'zh-CN').toMap(),
      'revision': 0,
    };
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return saved;
      if (call.method == MethodNames.openGlossaryFile) {
        return {
          'name': '术语.csv',
          'format': 'csv',
          'text': 'term,translation,language\nAPI,接口,zh-CN',
        };
      }
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        if (saved['revision'] == 0) await gate.future;
        final candidate = AppSettings.fromMap(draft);
        candidate.validate();
        saved = {
          ...candidate.toMap(),
          'revision': (saved['revision'] as int) + 1,
        };
        return saved;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (widget) =>
              widget is NativeGlassSwitchTile && widget.title == '登录时启动',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '语言与服务');
    await tester.ensureVisible(find.text('管理术语（0）'));
    await tester.tap(find.text('管理术语（0）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认导入'));
    await tester.pump();
    expect(find.text('保存中…'), findsOneWidget);
    expect(saved[PreferenceKeys.glossary], isEmpty);
    gate.complete();
    await tester.pumpAndSettle();
    expect(saved[PreferenceKeys.launchAtLogin], true);
    expect(AppSettings.fromMap(saved).glossary.single.translation, '接口');
    expect(find.byType(GlossaryImportPreview), findsNothing);
    expect(find.text('API → 接口'), findsOneWidget);
  });

  testWidgets('失败导入取消后不夹带术语，已有未保存设置仍可修正并提交', (tester) async {
    var saved = <String, Object?>{
      ...AppSettings(
        primaryLanguage: 'en',
        secondaryLanguage: 'en',
        inputPrimaryLanguage: 'zh-CN',
        inputSecondaryLanguage: 'en',
      ).toMap(),
      'revision': 0,
    };
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return saved;
      if (call.method == MethodNames.openGlossaryFile) {
        return {
          'name': '术语.csv',
          'format': 'csv',
          'text': 'term,translation,language\nAPI,接口,zh-CN',
        };
      }
      if (call.method == MethodNames.saveSettings) {
        final candidate = AppSettings.fromMap(
          Map<Object?, Object?>.from(call.arguments as Map),
        );
        candidate.validate();
        saved = {
          ...candidate.toMap(),
          'revision': (saved['revision'] as int) + 1,
        };
        return saved;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (widget) =>
              widget is NativeGlassSwitchTile && widget.title == '登录时启动',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();
    await openSettingsPage(tester, '语言与服务');
    await tester.ensureVisible(find.text('管理术语（0）'));
    await tester.tap(find.text('管理术语（0）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认导入'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(GlossaryImportPreview),
        matching: find.text('主要语言和次要语言必须不同。'),
      ),
      findsOneWidget,
    );
    expect(saved[PreferenceKeys.glossary], isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('暂无术语'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.drag(settingsContentList(), const Offset(0, 1200));
    await tester.pumpAndSettle();
    final primary = find.descendant(
      of: find.byWidgetPredicate(
        (widget) =>
            widget is NativeGlassDropdown<String> && widget.label == '主要语言',
      ),
      matching: find.byType(TextButton),
    );
    await tester.ensureVisible(primary);
    await tester.tap(primary);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '简体中文'));
    await tester.pumpAndSettle();
    expect(saved[PreferenceKeys.launchAtLogin], true);
    expect(saved[PreferenceKeys.primaryLanguage], 'zh-CN');
    expect(saved[PreferenceKeys.glossary], isEmpty);
  });

  testWidgets('导出操作保存可重新导入的 UTF-8 CSV 与 JSON 术语文件', (tester) async {
    final directory = Directory.systemTemp.createTempSync(
      'transnap-glossary.01a19b92-2e95-7c50-ba89-aed2fc78fad9.',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    const channel = MethodChannel(ChannelNames.settings);
    final entries = [
      const GlossaryEntry(
        term: 'API, "client"',
        translation: '接口\n客户端',
        language: 'zh-CN',
      ),
      const GlossaryEntry(term: 'Swift', translation: '', language: 'sv'),
    ];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.checkSystemTranslation) {
        return languagePackInstalledStatus;
      }
      if (call.method != MethodNames.saveTextFile) return null;
      final arguments = Map<String, String>.from(call.arguments as Map);
      final file = File('${directory.path}/${arguments['suggestedName']}');
      file.writeAsStringSync(arguments['text']!, encoding: utf8);
      return file.path;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      NativeGlassApp(
        home: GlossaryManager(
          glossary: entries,
          defaultLanguage: 'zh-CN',
          channel: channel,
          onChanged: (_) {},
          onImport: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final format in ['CSV', 'JSON']) {
      await tester.tap(find.text('导出…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(format));
      await tester.pumpAndSettle();
      final file = File(
        '${directory.path}/TranSnap 术语表.${format.toLowerCase()}',
      );
      final text = file.readAsStringSync(encoding: utf8);
      final draft = parseGlossaryFile(text, format: format.toLowerCase());
      expect(draft.errorCount, 0);
      expect(
        draft.rows.map((row) => row.entry!.toMap()),
        entries.map((entry) => entry.toMap()),
      );
      if (format == 'JSON') {
        expect(
          jsonDecode(text),
          entries.map((entry) => entry.toMap()).toList(),
        );
      }
    }
  });

  testWidgets('术语表导入与确认保存等待期间仅对应按钮显示进度环，完成后关闭（#142）', (tester) async {
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final picking = Completer<Map<String, String>?>();
    final saving = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.openGlossaryFile) return picking.future;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(
      NativeGlassApp(
        home: GlossaryManager(
          glossary: const [],
          defaultLanguage: 'zh-CN',
          channel: channel,
          onChanged: (_) {},
          onImport: (_) => saving.future,
        ),
      ),
    );
    await tester.pumpAndSettle();
    BusyRing ringFor(String text) => tester.widget<BusyRing>(
      find.ancestor(of: find.text(text), matching: find.byType(BusyRing)).first,
    );

    await tester.tap(find.text('导入…'));
    await tester.pump();
    expect(ringFor('导入…').active, isTrue);
    expect(ringFor('导出…').active, isFalse);

    picking.complete({
      'name': 't.json',
      'format': 'json',
      'text': '[{"term":"API","translation":"接口","language":"zh-CN"}]',
    });
    await tester.pumpAndSettle();
    expect(ringFor('确认导入').active, isFalse);

    await tester.tap(find.text('确认导入'));
    await tester.pump();
    expect(ringFor('保存中…').active, isTrue);
    expect(ringFor('取消').active, isFalse);

    saving.complete();
    await tester.pumpAndSettle();
    expect(ringFor('导入…').active, isFalse);
    expect(tester.takeException(), isNull);
  });
}
