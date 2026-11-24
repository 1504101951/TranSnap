import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Color;

import 'package:transnap/src/common/constants/appearance_modes.dart';
import 'package:transnap/src/settings/service_config.dart';
import 'package:transnap/src/common/constants/preference_keys.dart';
import 'package:transnap/src/common/constants/screenshot_enums.dart';
import 'package:transnap/src/common/constants/text_mode.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/settings/app_settings.dart';
import 'package:transnap/src/selection/selection_session.dart';
import 'package:transnap/src/translation/language_direction.dart';

import 'selection_session_test.dart' show RecordingProvider;

/// 无参数；验证设置约束和异步语言识别跨越会话边界时的业务输出。
void main() {
  test('普通设置不读取密钥，凭据修改只合并对应服务，删除保留删除标记', () async {
    // 已有服务仅修改普通偏好时 reader 不可访问；只有用户提交密钥才触及钥匙串。
    const saved = ServiceConfig(
      id: 'saved',
      kind: 'baidu',
      name: '百度',
      baseUrl: 'https://fanyi-api.baidu.com',
    );
    final untouched = await prepareCredentialChanges(
      previous: [saved],
      current: [saved],
      drafts: {'saved': {}},
      readCredentials: (_) async => throw StateError('普通设置不应读取密钥'),
    );
    expect(untouched, isEmpty);
    // 同一 ID 不可更换协议并沿用旧密钥，拒绝前也不应触发钥匙串读取。
    await expectLater(
      prepareCredentialChanges(
        previous: [saved],
        current: [
          const ServiceConfig(
            id: 'saved',
            kind: 'deepseek',
            name: 'DeepSeek',
            baseUrl: 'https://api.deepseek.com',
            model: 'test',
          ),
        ],
        drafts: {},
        readCredentials: (_) async => throw StateError('跨协议不应读取旧密钥'),
      ),
      throwsFormatException,
    );
    final changed = await prepareCredentialChanges(
      previous: [saved],
      current: [saved],
      drafts: {
        'saved': {'apiKey': 'new'},
      },
      readCredentials: (_) async => {'appId': 'app', 'apiKey': 'old'},
    );
    expect(changed, {
      'saved': {'appId': 'app', 'apiKey': 'new'},
    });
    final removed = await prepareCredentialChanges(
      previous: [saved],
      current: [],
      drafts: {},
      readCredentials: (_) async => throw StateError('删除不应在 Dart 读取密钥'),
    );
    expect(removed, {'saved': null});
    // 新服务无任何密钥必须失败，不能绕过协议必填项检查。
    await expectLater(
      prepareCredentialChanges(
        previous: [],
        current: [saved],
        drafts: {},
        readCredentials: (_) async => throw StateError('新服务没有旧密钥'),
      ),
      throwsFormatException,
    );
  });

  test('secondary language can be cleared and remains absent after saving', () {
    // 用户已有次要语言，再主动清空；完整偏好往返后不能悄悄恢复默认值。
    final settings = AppSettings(
      primaryLanguage: 'zh-CN',
      secondaryLanguage: 'en',
    );
    settings.secondaryLanguage = null;
    settings.validate();
    final restored = AppSettings.fromMap(settings.toMap());
    expect(restored.secondaryLanguage, isNull);
    expect(restored.direction.resolve('zh-CN').targetLanguage, 'zh-CN');
  });
  test('服务配置只持久化非敏感字段，默认项必须存在，地址拒绝凭据与远程 HTTP', () {
    const service = ServiceConfig(
      id: 'baidu-personal',
      kind: 'baidu',
      name: '我的百度',
      baseUrl: 'https://fanyi-api.baidu.com',
    );
    final settings = AppSettings(
      primaryLanguage: 'zh-CN',
      secondaryLanguage: 'en',
      services: [service],
      defaultServiceId: service.id,
    );
    final restored = AppSettings.fromMap(settings.toMap());
    expect(restored.defaultServiceId, service.id);
    expect(restored.services.single.name, '我的百度');
    final serialized = jsonEncode(settings.toMap());
    expect(serialized, isNot(contains('apiKey')));
    expect(serialized, isNot(contains('appId')));
    expect(settings.validate, returnsNormally);
    settings.services.clear();
    expect(settings.validate, throwsFormatException);
    for (final address in [
      'http://example.com',
      'https://user:secret@example.com',
      'https://example.com?key=secret',
      'https://example.com#secret',
    ]) {
      expect(
        () => ServiceConfig(
          id: 'invalid',
          kind: 'google',
          name: 'Google',
          baseUrl: address,
        ).validate(),
        throwsFormatException,
      );
    }
    expect(
      () => service.validateCredentials({'apiKey': 'dummy'}),
      throwsFormatException,
    );
    expect(
      () => service.validateCredentials({'apiKey': 'dummy', 'appId': 'app'}),
      returnsNormally,
    );
  });

  test('输入翻译语言：未设置时复制全局两项，设置后与全局隔离，次要语言「不设置」可往返（#99）', () {
    // 边界：旧偏好没有输入翻译键时取全局 zh-CN/en；保存后改全局次要语言不影响输入翻译；
    // 输入翻译次要语言设为 null 往返后仍为 null，不回落到全局；输入翻译两项相同时校验失败。
    final legacy = AppSettings.fromMap({
      'primaryLanguage': 'zh-CN',
      'secondaryLanguage': 'en',
    });
    expect(legacy.inputPrimaryLanguage, 'zh-CN');
    expect(legacy.inputSecondaryLanguage, 'en');
    legacy
      ..inputSecondaryLanguage = null
      ..secondaryLanguage = 'ja';
    final restored = AppSettings.fromMap(legacy.toMap());
    expect(restored.secondaryLanguage, 'ja');
    expect(restored.inputSecondaryLanguage, isNull);
    expect(restored.inputDirection.secondaryCode, isNull);
    expect(restored.validate, returnsNormally);
    restored.inputSecondaryLanguage = 'zh-CN';
    expect(restored.validate, throwsFormatException);
  });

  test('提示词缺省为默认值、思考缺省全部关闭，修改后可往返保存，空提示词被拒绝', () {
    // 边界：未保存过时四种模式提示词都等于默认值、思考全为 false；只改翻译提示词与润色思考后往返仍保持，
    // 其余模式不变；润色提示词改为空白时校验失败。
    final settings = AppSettings(primaryLanguage: 'zh-CN');
    expect(settings.prompts, defaultPrompts);
    expect(settings.prompts.keys, containsAll(TextMode.values));
    expect(settings.thinking, {
      for (final mode in TextMode.values) mode: false,
    });
    settings.prompts[TextMode.translate] = '只改翻译';
    settings.prompts[TextMode.polish] = '只改润色';
    settings.thinking[TextMode.polish] = true;
    final restored = AppSettings.fromMap(settings.toMap());
    expect(restored.prompts[TextMode.translate], '只改翻译');
    expect(restored.prompts[TextMode.polish], '只改润色');
    expect(
      restored.prompts[TextMode.explain],
      defaultPrompts[TextMode.explain],
    );
    expect(restored.thinking, {
      TextMode.translate: false,
      TextMode.polish: true,
      TextMode.correct: false,
      TextMode.explain: false,
    });
    expect(restored.validate, returnsNormally);
    restored.prompts[TextMode.polish] = '  ';
    expect(restored.validate, throwsFormatException);
  });

  test('输入翻译快捷键默认 ⌃⌥R 可往返保存，三个全局快捷键任意两个相同都被拒绝', () {
    // 边界：默认组合与另外两个默认值都不同；把输入翻译分别改成与翻译、截图相同，各自必须失败。
    final settings = AppSettings(primaryLanguage: 'zh-CN');
    expect(settings.validate, returnsNormally);
    final restored = AppSettings.fromMap(settings.toMap());
    expect(
      (
        restored.inputShortcutKeyCode,
        restored.inputShortcutModifiers,
        restored.inputShortcutLabel,
      ),
      (15, 6144, 'R'),
    );
    for (final (code, modifiers) in [
      (settings.shortcutKeyCode, settings.shortcutModifiers),
      (
        settings.screenshotShortcutKeyCode,
        settings.screenshotShortcutModifiers,
      ),
    ]) {
      final duplicate = AppSettings.fromMap(settings.toMap())
        ..inputShortcutKeyCode = code
        ..inputShortcutModifiers = modifiers;
      expect(duplicate.validate, throwsFormatException);
    }
  });

  test('Apple 系统翻译是内置默认服务：可作默认并往返，未知 ID 与 apple 类型的配置服务被拒绝', () {
    // 边界：systemId 无需出现在 services 中即为合法默认服务；不在内置与已配置之列的 ID 被拒绝；
    // 'apple' 不再是可配置的服务类型，即使地址与名称合法也被拒绝；空地址的远程服务仍被拒绝。
    final settings = AppSettings(
      primaryLanguage: 'zh-CN',
      defaultServiceId: ServiceConfig.systemId,
    );
    expect(settings.validate, returnsNormally);
    final restored = AppSettings.fromMap(settings.toMap());
    expect(restored.defaultServiceId, ServiceConfig.systemId);
    expect(restored.services, isEmpty);
    expect(
      AppSettings(
        primaryLanguage: 'zh-CN',
        defaultServiceId: 'apple-missing',
      ).validate,
      throwsFormatException,
    );
    const apple = ServiceConfig(
      id: 'apple-local',
      kind: 'apple',
      name: 'Apple 系统翻译',
      baseUrl: 'https://example.com',
    );
    expect(apple.validate, throwsFormatException);
    const remote = ServiceConfig(
      id: 'remote',
      kind: 'openai',
      name: 'OpenAI',
      baseUrl: '',
      model: 'gpt-test',
    );
    expect(remote.validate, throwsFormatException);
  });

  test('模型服务允许 API Key 留空，Google 与百度仍须填写（#123）', () {
    // 边界：三种模型协议的空凭据都通过；Google 空凭据、百度缺 App ID 仍被拒绝。
    for (final kind in ['openai', 'deepseek', 'anthropic']) {
      final model = ServiceConfig(
        id: kind,
        kind: kind,
        name: kind,
        baseUrl: 'http://localhost:11434/v1',
        model: 'local-model',
      );
      expect(() => model.validateCredentials(const {}), returnsNormally);
    }
    for (final (kind, credentials) in [
      ('google', const <String, String>{}),
      ('baidu', const {'apiKey': 'k'}),
    ]) {
      final service = ServiceConfig(
        id: kind,
        kind: kind,
        name: kind,
        baseUrl: 'https://example.com',
      );
      expect(
        () => service.validateCredentials(credentials),
        throwsFormatException,
      );
    }
  });

  test('主次语言方向支持多语言、繁体中文以及无法识别的文本', () {
    // nil 必须译向主要语言；BCP-47 同语言不同地区不能误切方向。
    const direction = LanguageDirection(primaryCode: 'fr', secondaryCode: 'en');
    expect(direction.resolve('fr-CA').targetLanguage, 'en');
    expect(direction.resolve('ja').targetLanguage, 'fr');
    expect(direction.resolve(null).targetLanguage, 'fr');
    expect(
      LanguageDirection.systemDefault(languageCode: 'zh-Hant-HK').primaryCode,
      'zh-TW',
    );
  });

  test('相同语言与无系统修饰键的快捷键不能保存', () {
    // en 与 en-US 等价；Shift+A 是普通输入，不允许注册为全局翻译热键。
    // 输入翻译语言在构造时复制全局两项，与全局隔离，因此两组都要改为有效语言（#99）。
    final settings = AppSettings(
      primaryLanguage: 'en',
      secondaryLanguage: 'en-US',
    );
    expect(settings.validate, throwsFormatException);
    settings
      ..secondaryLanguage = 'zh-CN'
      ..inputSecondaryLanguage = 'zh-CN';
    settings.shortcutModifiers = 512;
    expect(settings.validate, throwsFormatException);
    settings.shortcutModifiers = 6144;
    expect(settings.validate, returnsNormally);
  });

  test('语言识别期间关闭选区不会发送请求，下一选区使用已保存方向', () async {
    final detection = Completer<String?>();
    final provider = RecordingProvider();
    final session = SelectionSession(
      provider: provider,
      detectLanguage: (_) => detection.future,
      language: const LanguageDirection(primaryCode: 'fr', secondaryCode: 'en'),
    );
    session.begin(sessionId: 'old', text: 'Bonjour à tous.');
    final pending = session.activate();
    session.dismiss();
    detection.complete('fr');
    await pending;
    expect(provider.requests, isEmpty);
    session.begin(sessionId: 'new', text: 'Bonjour à tous.');
    await session.activate();
    expect(provider.requests.single.targetLanguage, 'en');
    session.dispose();
  });

  test('关闭自动按钮及排除应用可以随同快捷键一起保存和恢复', () {
    // 使用一次完整序列化往返，覆盖实际传输的嵌套排除项与自定义组合。
    final settings = AppSettings(
      primaryLanguage: 'ja',
      secondaryLanguage: 'en',
      automatic: false,
      shortcutKeyCode: 15,
      shortcutLabel: 'R',
      shortcutModifiers: 6400,
      excludedApps: {'com.apple.TextEdit': '文本编辑'},
    );
    final restored = AppSettings.fromMap(settings.toMap());
    expect(restored.automatic, isFalse);
    expect(restored.excludedApps, {'com.apple.TextEdit': '文本编辑'});
    expect(restored.shortcutKeyCode, 15);
    expect(restored.shortcutLabel, 'R');
    expect(restored.direction.resolve('ja').targetLanguage, 'en');
  });

  test('录屏点击特效默认关闭且区分右键默认开启，7种枚举可往返保存，未知样式拒绝（#143）', () {
    // 边界：缺省配置下特效为 off、右键区分为 true；所有枚举往返一致，非法协议值抛出 FormatException。
    final defaults = AppSettings.fromMap({'primaryLanguage': 'zh-CN'});
    expect(defaults.recordingClickEffect, RecordingClickEffect.off);
    expect(defaults.recordingClickRightDistinct, isTrue);

    for (final effect in RecordingClickEffect.values) {
      final settings = AppSettings(
        primaryLanguage: 'zh-CN',
        recordingClickEffect: effect,
        recordingClickRightDistinct: false,
      );
      final restored = AppSettings.fromMap(settings.toMap());
      expect(restored.recordingClickEffect, effect);
      expect(restored.recordingClickRightDistinct, isFalse);
    }

    expect(
      () => AppSettings.fromMap({
        'primaryLanguage': 'zh-CN',
        PreferenceKeys.recordingClickEffect: 'rainbowNeon',
      }),
      throwsFormatException,
    );
  });

  test('强调色偏好默认跟随系统，支持全部 6 种经典色往返保存，未知值拒绝（#144）', () {
    // 作用：验证 AppSettings.accentColor 协议枚举往返序列化与边界校验。
    // 边界：缺失字段默认 AccentColors.system；全部 AccentColors.values 通过校验；非法值抛 FormatException。
    final defaults = AppSettings.fromMap({'primaryLanguage': 'zh-CN'});
    expect(defaults.accentColor, AccentColors.system);

    for (final color in AccentColors.values) {
      final settings = AppSettings(
        primaryLanguage: 'zh-CN',
        accentColor: color,
      );
      expect(settings.validate, returnsNormally);
      final restored = AppSettings.fromMap(settings.toMap());
      expect(restored.accentColor, color);
    }

    final invalid = AppSettings(
      primaryLanguage: 'zh-CN',
      accentColor: 'neonPink',
    );
    expect(invalid.validate, throwsFormatException);
  });

  test('前景色偏好默认自动，接受自动、白色、黑色与大写 #RRGGBB，其余拒绝（#144）', () {
    // 作用：验证 AppSettings.accentForeground 往返序列化与校验。
    // 边界：缺失字段为 auto；auto/white/black/#00FF00 通过；小写 HEX 与 'gray' 拒绝。
    expect(
      AppSettings.fromMap({'primaryLanguage': 'zh-CN'}).accentForeground,
      AccentForegrounds.auto,
    );
    for (final value in ['auto', 'white', 'black', '#00FF00']) {
      final settings = AppSettings(
        primaryLanguage: 'zh-CN',
        accentForeground: value,
      );
      expect(settings.validate, returnsNormally, reason: value);
      expect(AppSettings.fromMap(settings.toMap()).accentForeground, value);
    }
    for (final value in ['#00ff00', 'gray']) {
      final settings = AppSettings(
        primaryLanguage: 'zh-CN',
        accentForeground: value,
      );
      expect(settings.validate, throwsFormatException, reason: value);
    }
  });

  test('自定义强调色只接受大写 #RRGGBB，并推导浅、深两套颜色（#144）', () {
    // 作用：验证自定义强调色的偏好校验与浅/深色推导（深色由浅色向白混合 35%）。
    // 边界：#2EA3D6 合法；小写、5 位、缺 # 均拒绝；#000000 深色为 89/255 灰，#FFFFFF 深色仍为白；预设名返回预设色，system 返回 null。
    for (final value in ['#2EA3D6', '#000000', '#FFFFFF']) {
      final settings = AppSettings(
        primaryLanguage: 'zh-CN',
        accentColor: value,
      );
      expect(settings.validate, returnsNormally, reason: value);
    }
    for (final value in ['#2ea3d6', '#2EA3D', '2EA3D6']) {
      final settings = AppSettings(
        primaryLanguage: 'zh-CN',
        accentColor: value,
      );
      expect(settings.validate, throwsFormatException, reason: value);
    }
    final custom = AccentColors.pairOf('#2EA3D6')!;
    expect(custom.light, const Color(0xFF2EA3D6));
    expect(
      AccentColors.pairOf('#000000')!.dark.toARGB32(),
      const Color(0xFF595959).toARGB32(),
    );
    expect(AccentColors.pairOf('#FFFFFF')!.dark.toARGB32(), 0xFFFFFFFF);
    expect(
      AccentColors.pairOf(AccentColors.blue),
      AccentColors.swatches[AccentColors.blue],
    );
    expect(AccentColors.pairOf(AccentColors.system), isNull);
    expect(AccentColors.customValue(const Color(0xFF2EA3D6)), '#2EA3D6');
  });
}
