import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/channel_names.dart';
import 'package:transnap/src/common/constants/error_codes.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/preference_keys.dart';
import 'package:transnap/src/common/constants/screenshot_enums.dart';
import 'package:transnap/src/platform/settings_platform.dart';
import 'package:transnap/src/settings/app_settings.dart';
import 'package:transnap/src/settings/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File saved;
  late SettingsController controller;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('settings-controller-');
    saved = File('${directory.path}/preferences/settings.json');
    saved.parent.createSync();
    controller = SettingsController(
      initial: AppSettings(primaryLanguage: 'zh-CN'),
      platform: _FileSettingsPlatform(saved),
      onSaved: (_) {},
    );
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('外部草稿、协议快照和通知接收方不能绕过提交修改有效配置', () async {
    final initial = AppSettings(
      primaryLanguage: 'zh-CN',
      excludedApps: {'com.example.editor': '编辑器'},
    );
    controller = SettingsController(
      initial: initial,
      platform: _FileSettingsPlatform(saved),
      onSaved: (published) {
        published.primaryLanguage = 'ja';
        published.excludedApps.clear();
      },
    );
    initial.primaryLanguage = 'en';
    initial.excludedApps.clear();
    final draft = controller.current;
    draft.automatic = false;
    draft.excludedApps.clear();
    final snapshot = await controller.handle(
      const MethodCall(MethodNames.getSettings),
    ) as Map;
    (snapshot[PreferenceKeys.excludedApps] as Map).clear();

    expect(controller.current.primaryLanguage, 'zh-CN');
    expect(controller.current.automatic, isTrue);
    expect(controller.current.excludedApps, {'com.example.editor': '编辑器'});
    expect(snapshot['revision'], 0);
    expect(saved.existsSync(), isFalse);

    final committed = await controller.handle(
      const MethodCall(MethodNames.toggleAutomatic),
    ) as Map;
    expect(committed['revision'], 1);
    expect(controller.current.automatic, isFalse);
    expect(controller.current.primaryLanguage, 'zh-CN');
    expect(controller.current.excludedApps, {'com.example.editor': '编辑器'});
    final persisted = jsonDecode(saved.readAsStringSync()) as Map;
    expect(persisted[PreferenceKeys.primaryLanguage], 'zh-CN');
    expect(persisted[PreferenceKeys.excludedApps], {
      'com.example.editor': '编辑器',
    });
  });

  test('录制选项：截图工具栏保存延时与点击特效，其他设置保持不变，非法延时或特效不提交（#129、#143）', () async {
    final committed = await controller.handle(
      MethodCall(MethodNames.saveRecordingOptions, {
        PreferenceKeys.recordingDelay: 5,
        PreferenceKeys.recordingClickEffect: RecordingClickEffect.optical.name,
      }),
    ) as Map;
    expect(committed['revision'], 1);
    expect(controller.current.recordingDelay, 5);
    expect(controller.current.recordingClickEffect, RecordingClickEffect.optical);
    expect(controller.current.recordingClickRightDistinct, isTrue);
    expect(controller.current.primaryLanguage, 'zh-CN');
    await expectLater(
      controller.handle(
        MethodCall(MethodNames.saveRecordingOptions, {
          PreferenceKeys.recordingDelay: 4,
          PreferenceKeys.recordingClickEffect: RecordingClickEffect.off.name,
        }),
      ),
      throwsFormatException,
    );
    await expectLater(
      controller.handle(
        MethodCall(MethodNames.saveRecordingOptions, {
          PreferenceKeys.recordingDelay: 5,
          PreferenceKeys.recordingClickEffect: 'invalidEffect',
        }),
      ),
      throwsFormatException,
    );
    expect(controller.current.recordingDelay, 5);
    expect(controller.current.recordingClickEffect, RecordingClickEffect.optical);
  });

  test('存储目录不可用时不发布配置，修复目录后下一次提交成功', () async {
    saved.parent.deleteSync();
    final obstruction = File(saved.parent.path)..writeAsStringSync('occupied');
    await expectLater(
      controller.handle(const MethodCall(MethodNames.toggleAutomatic)),
      throwsA(isA<FileSystemException>()),
    );
    expect(controller.current.automatic, isTrue);
    final failed = await controller.handle(
      const MethodCall(MethodNames.getSettings),
    ) as Map;
    expect(failed['revision'], 0);
    expect(saved.existsSync(), isFalse);

    obstruction.deleteSync();
    saved.parent.createSync();
    final recovered = await controller.handle(
      const MethodCall(MethodNames.toggleAutomatic),
    ) as Map;
    expect(recovered['revision'], 1);
    expect(controller.current.automatic, isFalse);
    expect(
      jsonDecode(saved.readAsStringSync())[PreferenceKeys.automatic],
      isFalse,
    );
  });

  test('同一修订的并发草稿只接受首个提交，过期草稿不覆盖系统文件', () async {
    final first = controller.handle(
      MethodCall(MethodNames.saveSettings, {
        ...controller.current.toMap(),
        'revision': 0,
        PreferenceKeys.gifFramesPerSecond: 24,
      }),
    );
    final conflict = expectLater(
      controller.handle(
        MethodCall(MethodNames.saveSettings, {
          ...controller.current.toMap(),
          'revision': 0,
          PreferenceKeys.gifFramesPerSecond: 20,
        }),
      ),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          ErrorCodes.settingsConflict,
        ),
      ),
    );
    expect((await first as Map)['revision'], 1);
    await conflict;
    expect(controller.current.gifFramesPerSecond, 24);
    expect(
      jsonDecode(saved.readAsStringSync())[PreferenceKeys.gifFramesPerSecond],
      24,
    );
  });

  test('连续菜单切换按提交顺序读取最新状态，失败校验不占用修订', () async {
    final changes = await Future.wait([
      controller.handle(const MethodCall(MethodNames.toggleAutomatic)),
      controller.handle(const MethodCall(MethodNames.toggleAutomatic)),
    ]);
    expect((changes[0] as Map)[PreferenceKeys.automatic], isFalse);
    expect((changes[1] as Map)[PreferenceKeys.automatic], isTrue);
    expect((changes[1] as Map)['revision'], 2);

    await expectLater(
      controller.handle(
        MethodCall(MethodNames.saveSettings, {
          ...controller.current.toMap(),
          'revision': 2,
          PreferenceKeys.gifFramesPerSecond: 31,
        }),
      ),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          ErrorCodes.invalidSettings,
        ),
      ),
    );
    final next = await controller.handle(
      MethodCall(MethodNames.saveSettings, {
        ...controller.current.toMap(),
        'revision': 2,
        PreferenceKeys.gifFramesPerSecond: 30,
      }),
    ) as Map;
    expect(next['revision'], 3);
    expect(controller.current.gifFramesPerSecond, 30);
  });

  group('Apple 系统翻译语言包检查', () {
    const methods = MethodChannel(ChannelNames.platform);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    void nativeStatuses(Map<String, String> statuses) {
      messenger.setMockMethodCallHandler(methods, (call) async {
        final pairs = (call.arguments as Map)['pairs'] as List;
        return [
          for (final pair in pairs)
            statuses['${pair[0]}>${pair[1]}'] ?? 'installed',
        ];
      });
    }

    Future<Object?> testApple(String primary, [String? secondary]) =>
        SettingsController(
          initial: AppSettings(
            primaryLanguage: primary,
            secondaryLanguage: secondary,
          ),
          platform: _FileSettingsPlatform(saved),
          onSaved: (_) {},
        ).handle(const MethodCall(MethodNames.checkSystemTranslation));

    tearDown(() => messenger.setMockMethodCallHandler(methods, null));

    test('设置次要语言时检查双向，只列出未安装的语言对并给出下载位置', () async {
      nativeStatuses({'en>zh-CN': 'supported'});
      await expectLater(
        testApple('zh-CN', 'en'),
        throwsA(
          isA<PlatformException>()
              .having((error) => error.code, 'code', ErrorCodes.testFailed)
              .having(
                (error) => error.message,
                'message',
                '缺少语言包：English → 简体中文。请到「系统设置 → 通用 → 语言与地区 → 翻译语言」下载。',
              ),
        ),
      );
    });

    test('不支持的语言对优先于未安装提示', () async {
      nativeStatuses({
        'zh-CN>zh-TW': 'unsupported',
        'zh-TW>zh-CN': 'unsupported',
      });
      await expectLater(
        testApple('zh-CN', 'zh-TW'),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.message,
            'message',
            'Apple 系统翻译不支持：简体中文 → 繁體中文、繁體中文 → 简体中文。',
          ),
        ),
      );
    });

    test('未设置次要语言时检查英文译为主要语言，全部安装时返回已安装说明', () async {
      nativeStatuses({});
      expect(await testApple('ja'), '语言包已安装：English → 日本語');
    });

    test('主要语言为英文且未设置次要语言时没有可检查的语言对', () async {
      nativeStatuses({'en>en': 'unsupported'});
      expect(await testApple('en'), '主要语言为英文且未设置次要语言，翻译时按原文语言检查语言包。');
    });
  });
}

class _FileSettingsPlatform implements SettingsPlatform {
  _FileSettingsPlatform(this.destination);

  final File destination;
  final Map<String, Map<String, String>> _credentials = {};

  @override
  Future<void> applySettings(
    Map<String, Object> settings, {
    Map<String, Map<String, String>?> credentials = const {},
  }) async {
    await destination.writeAsString(jsonEncode(settings));
    for (final entry in credentials.entries) {
      final value = entry.value;
      if (value == null) {
        _credentials.remove(entry.key);
      } else {
        _credentials[entry.key] = Map.of(value);
      }
    }
  }

  @override
  Future<Map<String, String>> readCredentials(String id) async =>
      Map.of(_credentials[id] ?? {});

  @override
  Future<List<String>> credentialIds(List<String> ids) async =>
      ids.where(_credentials.containsKey).toList();
}
