import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/appearance_modes.dart';
import 'package:transnap/src/common/constants/channel_names.dart';
import 'package:transnap/src/common/constants/font_sets.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/preference_keys.dart';
import 'package:transnap/src/common/widgets/native_glass.dart';
import 'package:transnap/src/fonts/font_state.dart';
import 'package:transnap/src/settings/app_settings.dart';

void main() {
  test('主题按角色使用所选组合：界面与标题分开，正文由扩展提供', () {
    final character = NativeGlassTheme.data(
      Brightness.light,
      const GlassAppearance(fontSet: FontSet.character),
    );
    expect(character.textTheme.bodyMedium!.fontFamily, 'TranSnap SpaceGrotesk');
    expect(character.textTheme.bodyMedium!.fontFamilyFallback, [
      'TranSnap NotoSansSC',
    ]);
    expect(
      character.textTheme.displayLarge!.fontFamily,
      'TranSnap SpaceGrotesk',
    );
    expect(character.textTheme.titleMedium!.fontFamilyFallback, [
      'TranSnap SmileySans-Oblique',
    ]);
    expect(character.textTheme.headlineSmall!.fontFamilyFallback, [
      'TranSnap SmileySans-Oblique',
    ]);
    final claude = NativeGlassTheme.data(
      Brightness.dark,
      const GlassAppearance(fontSet: FontSet.claude),
    ).extension<GlassFonts>()!;
    expect(claude.ui.fontFamily, 'TranSnap InstrumentSans');
    expect(claude.body.fontFamily, 'TranSnap SourceSerif4');
    expect(claude.body.fontFamilyFallback, ['TranSnap NotoSerifSC']);
  });

  test('日文、韩文与繁体中文正文只保留西文字体，汉字回退系统字体；简体与其他语言保留中文字体', () {
    final fonts = GlassFonts.of(FontSet.neutral);
    for (final (language, script) in [
      ('ja', null),
      ('ko', null),
      ('zh-TW', 'Hant'),
      ('zh-Hant', 'Hant'),
    ]) {
      final style = fonts.bodyFor(language);
      expect(style.fontFamily, 'TranSnap Inter');
      expect(style.fontFamilyFallback, isNull);
      expect(style.locale!.languageCode, language.split('-').first);
      expect(style.locale!.scriptCode, script);
    }
    for (final language in [null, 'zh-CN', 'en', 'fr']) {
      expect(fonts.bodyFor(language), fonts.body);
    }
  });

  testWidgets('显式文字样式只写字号时继承主题字体', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(
          Brightness.light,
          const GlassAppearance(fontSet: FontSet.rounded),
        ),
        home: const Material(
          child: Text('翻译完成', style: TextStyle(fontSize: 11)),
        ),
      ),
    );
    final paragraph = tester.renderObject<RenderParagraph>(find.text('翻译完成'));
    expect(paragraph.text.style!.fontFamily, 'TranSnap Nunito');
    expect(paragraph.text.style!.fontFamilyFallback, ['TranSnap NotoSansSC']);
    expect(paragraph.text.style!.fontSize, 11);
  });

  test('组合所需文件按角色去重，内置判断与缺失体积按已下载文件计算', () {
    expect(FontSet.neutral.isBundled, isTrue);
    expect(FontSet.claude.files, {
      FontFile.instrumentSans,
      FontFile.notoSansSC,
      FontFile.sourceSerif4,
      FontFile.notoSerifSC,
    });
    final state = FontState(downloaded: {FontFile.sourceSerif4});
    expect(state.isAvailable(FontSet.neutral), isTrue);
    expect(state.isAvailable(FontSet.claude), isFalse);
    expect(
      state.missingBytes(FontSet.claude),
      FontFile.instrumentSans.bytes + FontFile.notoSerifSC.bytes,
    );
    expect(FontState.fromMap(state.toMap()), state);
    final downloading = FontState(
      download: (set: FontSet.bookish, received: 10, total: 20),
    );
    expect(FontState.fromMap(downloading.toMap()), downloading);
  });

  test('字体组合偏好缺省为中性，可往返，未知名称报错', () {
    final settings = AppSettings(primaryLanguage: 'zh-CN');
    expect(settings.fontSet, FontSet.neutral);
    settings.fontSet = FontSet.legible;
    expect(AppSettings.fromMap(settings.toMap()).fontSet, FontSet.legible);
    expect(
      () => AppSettings.fromMap({
        PreferenceKeys.primaryLanguage: 'zh-CN',
        PreferenceKeys.fontSet: 'serif',
      }),
      throwsArgumentError,
    );
  });

  testWidgets('外观快照所选组合的文件可读时注册并应用，文件缺失时退回中性', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const codec = StandardMethodCodec();
    final directory = Directory.systemTemp.createTempSync('fonts-');
    addTearDown(() => directory.deleteSync(recursive: true));
    File('assets/fonts/Inter.ttf')
        .copySync('${directory.path}/${FontFile.geist.fileName}');
    Map<String, Object> snapshot(FontSet set, String fonts) => {
      PreferenceKeys.glassAppearance: AppearanceModes.light,
      PreferenceKeys.glassOpacity: 0.8,
      AppearanceKeys.accentLight: 0xFF007AFF,
      AppearanceKeys.accentDark: 0xFF0A84FF,
      PreferenceKeys.fontSet: set.name,
      AppearanceKeys.fontsDirectory: fonts,
      AppearanceKeys.fontState: {
        'downloaded': [FontFile.geist.name],
      },
    };
    messenger.setMockMethodCallHandler(
      const MethodChannel(ChannelNames.appearance),
      (_) async => snapshot(FontSet.neutral, directory.path),
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel(ChannelNames.appearance),
        null,
      ),
    );
    await tester.pumpWidget(const NativeGlassApp(home: Text('字体')));
    await tester.pumpAndSettle();
    Future<void> push(FontSet set, String fonts) => tester.runAsync(
      () => messenger.handlePlatformMessage(
        ChannelNames.appearance,
        codec.encodeMethodCall(
          MethodCall(MethodNames.appearanceChanged, snapshot(set, fonts)),
        ),
        (_) {},
      ),
    );
    await push(FontSet.geometric, directory.path);
    await tester.pumpAndSettle();
    expect(GlassAppearance.current.value.fontSet, FontSet.geometric);
    expect(FontState.current.value.downloaded, {FontFile.geist});
    expect(
      Theme.of(tester.element(find.text('字体')))
          .textTheme
          .bodyMedium!
          .fontFamily,
      'TranSnap Geist',
    );
    await push(FontSet.humanist, '${directory.path}/missing');
    await tester.pumpAndSettle();
    expect(GlassAppearance.current.value.fontSet, FontSet.neutral);
  });
}
