import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/preference_keys.dart';
import 'package:transnap/src/common/constants/screenshot_actions.dart';
import 'package:transnap/src/common/constants/toolbar_grid.dart';
import 'package:transnap/src/settings/app_settings.dart';
import 'package:transnap/src/common/constants/shortcut_keys.dart';
import 'package:transnap/src/common/widgets/native_glass.dart';
import 'package:transnap/src/settings/screenshot_toolbar_editor.dart';
import 'package:transnap/src/settings/screenshot_toolbar_preferences.dart';

void main() {
  const cmd = ShortcutModifiers.meta;
  const opt = ShortcutModifiers.alt;
  const ctrl = ShortcutModifiers.control;

  test('默认常用 6 个占无修饰 1–6，其余 9 个一级工具分为 ⌘、⌥ 两组，不含光标，每个工具只有一个键位', () {
    final value = ScreenshotToolbarPreferences();
    expect(value.favorites, [
      ScreenshotActions.crop,
      ScreenshotActions.rect,
      ScreenshotActions.record,
      ScreenshotActions.ocrCopy,
      ScreenshotActions.ocrTranslate,
      ScreenshotActions.pin,
    ]);
    expect(value.columns.map((c) => c.modifiers), [cmd, opt]);
    expect(value.columns[0].slots, [
      ScreenshotActions.arrow,
      ScreenshotActions.step,
      ScreenshotActions.text,
      ScreenshotActions.brush,
      null,
      null,
    ]);
    expect(value.columns[1].slots, [
      ScreenshotActions.beautify,
      ScreenshotActions.ratio,
      ScreenshotActions.save,
      ScreenshotActions.copy,
      ScreenshotActions.close,
      null,
    ]);
    expect(
      ScreenshotActions.composable.containsKey(ScreenshotActions.cursor),
      isFalse,
    );
    final grid = [for (final c in value.columns) ...c.slots.nonNulls];
    expect(grid.toSet().intersection(value.favorites.toSet()), isEmpty);
    expect(value.shortcutLabel(ScreenshotActions.crop), '1');
    expect(value.shortcutLabel(ScreenshotActions.pin), '6');
    expect(value.shortcutLabel(ScreenshotActions.arrow), '⌘1');
    expect(value.shortcutLabel(ScreenshotActions.beautify), '⌥1');
    expect(value.shortcutLabel(ScreenshotActions.close), '⌥5');
    expect(value.shortcutLabel(ScreenshotActions.scrolling), isNull);
    expect(value.actionAt(0, 2), ScreenshotActions.rect);
    expect(value.actionAt(0, 6), ScreenshotActions.pin);
    expect(value.actionAt(opt, 1), ScreenshotActions.beautify);
    expect(value.actionAt(opt, 6), isNull);
    expect(value.actionAt(ctrl, 1), isNull);
  });

  test('网格、子级、隐藏与常用往返保存；空格存为空字符串', () {
    final base = ScreenshotToolbarPreferences();
    final value = base.copyWith(
      hidden: {ScreenshotActions.save},
      favorites: [ScreenshotActions.text, ScreenshotActions.crop],
      columns: [
        ToolbarColumn(cmd, [
          ScreenshotActions.rect,
          ScreenshotActions.arrow,
          ScreenshotActions.step,
          ScreenshotActions.brush,
          ScreenshotActions.record,
          null,
        ]),
        ToolbarColumn(opt, [
          ScreenshotActions.beautify,
          ScreenshotActions.ratio,
          ScreenshotActions.save,
          ScreenshotActions.copy,
          ScreenshotActions.close,
          ScreenshotActions.pin,
        ]),
        ToolbarColumn(ctrl, [
          ScreenshotActions.ocrCopy,
          ScreenshotActions.ocrTranslate,
          null,
          null,
          null,
          null,
        ]),
      ],
    );
    expect(value.validate, returnsNormally);
    final map = value.toMap();
    expect(
      (map[PreferenceKeys.screenshotToolbarColumns] as List).last,
      allOf(
        containsPair('slots', contains('')),
        containsPair('modifiers', ['control']),
      ),
    );
    expect(
      ToolbarColumn(cmd | opt | ctrl, const []).toMap()['modifiers'],
      ['control', 'alt', 'meta'],
    );
    final restored = ScreenshotToolbarPreferences.fromMap(map);
    expect(
      restored.columns.map((c) => c.slots),
      value.columns.map((c) => c.slots),
    );
    expect(restored.columns.map((c) => c.modifiers), [cmd, opt, ctrl]);
    expect(restored.children, value.children);
    expect(restored.hidden, {ScreenshotActions.save});
    expect(restored.favorites, [ScreenshotActions.text, ScreenshotActions.crop]);
  });

  test('没有网格的旧结构整体重置为默认网格，不迁移旧顺序与快捷键', () {
    final restored = ScreenshotToolbarPreferences.fromMap({
      'screenshotToolbarOrder': [ScreenshotActions.close],
      'screenshotToolbarShortcuts': {
        ScreenshotActions.close: {'keyId': 0x31, 'modifiers': 0},
      },
      'screenshotToolbarHidden': [ScreenshotActions.copy],
      'screenshotToolbarColumns': [
        ToolbarColumn(0, [ScreenshotActions.close]).toMap(),
      ],
      'screenshotToolbarGroups': [
        ToolbarColumn(cmd, [ScreenshotActions.crop]).toMap(),
      ],
      'screenshotToolbarFavorites': [ScreenshotActions.crop],
      'screenshotToolbarChildren': {
        ScreenshotActions.crop: [ScreenshotActions.record],
      },
    });
    final defaults = ScreenshotToolbarPreferences();
    expect(
      restored.columns.map((c) => c.slots),
      defaults.columns.map((c) => c.slots),
    );
    expect(restored.children, defaults.children);
    expect(restored.hidden, isEmpty);
    expect(restored.favorites, defaults.favorites);
  });

  test('已保存网格缺少的功能：默认父级是一级时挂回，否则放进第一个空格，满了新增一列', () {
    final full = ScreenshotToolbarPreferences();
    final topLevel = full.topLevel;
    final withoutClose = [
      for (final column in full.columns)
        ToolbarColumn(column.modifiers, [
          for (final slot in column.slots)
            slot == ScreenshotActions.close ? null : slot,
        ]).toMap(),
    ];
    final restored = ScreenshotToolbarPreferences.fromMap({
      PreferenceKeys.screenshotToolbarColumns: withoutClose,
      PreferenceKeys.screenshotToolbarFavorites: full.favorites,
      PreferenceKeys.screenshotToolbarChildren: {
        ScreenshotActions.crop: [
          ScreenshotActions.eyedropper,
          ScreenshotActions.ruler,
        ],
        ScreenshotActions.beautify: [ScreenshotActions.sticker],
      },
    });
    expect(
      restored.children[ScreenshotActions.crop],
      contains(ScreenshotActions.scrolling),
    );
    expect(restored.shortcutLabel(ScreenshotActions.close), '⌘5');

    final twelve = topLevel.take(12).toList();
    final packed = ScreenshotToolbarPreferences.fromMap({
      PreferenceKeys.screenshotToolbarColumns: [
        ToolbarColumn(cmd, twelve.sublist(0, 6)).toMap(),
        ToolbarColumn(opt, twelve.sublist(6, 12)).toMap(),
      ],
      PreferenceKeys.screenshotToolbarFavorites: const <String>[],
      PreferenceKeys.screenshotToolbarChildren:
          ScreenshotActions.defaultChildren,
    });
    expect(packed.favorites, isEmpty);
    expect(packed.columns.map((c) => c.modifiers), [cmd, opt, ctrl]);
    expect(packed.columns[2].slots.whereType<String>(), topLevel.skip(12));
  });

  test('校验：组合只能是 ⌘⌥⌃ 的组合、不能无修饰、不含 ⇧、各列不重复，每列 6 格，最多 8 列；常用最多 5 个一级工具', () {
    final base = ScreenshotToolbarPreferences();
    ScreenshotToolbarPreferences withModifiers(List<int> modifiers) =>
        base.copyWith(
          columns: [
            for (final (index, column) in base.columns.indexed)
              ToolbarColumn(modifiers[index], column.slots),
          ],
        );
    for (final invalid in [
      [0, opt, cmd | opt],
      [ShortcutModifiers.shift, opt, cmd | opt],
      [cmd | ShortcutModifiers.shift, opt, cmd | opt],
      [cmd, cmd, opt],
    ]) {
      expect(
        () => withModifiers(invalid).validate(),
        throwsFormatException,
        reason: '$invalid',
      );
    }
    expect(
      () => withModifiers([ctrl, cmd | opt | ctrl, opt | ctrl]).validate(),
      returnsNormally,
    );
    expect(
      () => base
          .copyWith(
            columns: [
              ToolbarColumn(cmd, base.columns[0].slots.take(5).toList()),
              ...base.columns.skip(1),
            ],
          )
          .validate(),
      throwsFormatException,
    );
    final nine = [
      ...base.columns,
      for (final modifiers in ToolbarModifiers.allowed)
        if (!base.columns.any((column) => column.modifiers == modifiers))
          ToolbarColumn(modifiers, List.filled(ToolbarGrid.slots, null)),
      ToolbarColumn(cmd | opt, List.filled(ToolbarGrid.slots, null)),
      ToolbarColumn(cmd, List.filled(ToolbarGrid.slots, null)),
    ];
    expect(nine.length, 9);
    expect(
      () => base.copyWith(columns: nine).validate(),
      throwsFormatException,
    );
    for (final favorites in [
      [...base.favorites, ScreenshotActions.arrow],
      [ScreenshotActions.crop, ScreenshotActions.crop],
      [ScreenshotActions.scrolling],
    ]) {
      expect(
        () => base.copyWith(favorites: favorites).validate(),
        throwsFormatException,
        reason: '$favorites',
      );
    }
  });

  test('校验：每个功能在格位与子级中恰好一次，只有一级的工具可以带子级', () {
    final base = ScreenshotToolbarPreferences();
    final duplicate = base.copyWith(
      columns: [
        base.columns[0],
        base.columns[1].withSlot(5, ScreenshotActions.arrow),
      ],
    );
    expect(duplicate.validate, throwsFormatException);
    final favoriteTwice = base.copyWith(
      columns: [
        base.columns[0],
        base.columns[1].withSlot(5, ScreenshotActions.crop),
      ],
    );
    expect(favoriteTwice.validate, throwsFormatException);
    expect(
      () => base
          .copyWith(
            children: {
              ...base.children,
              ScreenshotActions.save: [ScreenshotActions.sticker],
            }..remove(ScreenshotActions.beautify),
          )
          .validate(),
      throwsFormatException,
    );
  });

  test('全局快捷键与系统快捷键按数字行键名换算为格位，带 ⇧ 或 1–6 以外的键不落在网格', () {
    expect(ToolbarGrid.slotOf('Digit1', cmd), (modifiers: cmd, digit: 1));
    expect(ToolbarGrid.slotOf('Digit6', ctrl | opt), (
      modifiers: ctrl | opt,
      digit: 6,
    ));
    expect(ToolbarGrid.slotOf('Digit7', cmd), isNull);
    expect(ToolbarGrid.slotOf('KeyA', cmd), isNull);
    expect(ToolbarGrid.slotOf('Digit1', cmd | ShortcutModifiers.shift), isNull);
  });

  test('全局快捷键落在有工具的格位时拒绝保存，落在空格或网格外时允许', () {
    AppSettings withTranslate(String key, int modifiers) => AppSettings(
      primaryLanguage: 'zh-CN',
      shortcut: (key: key, modifiers: modifiers, label: 'x'),
    );
    expect(
      () => withTranslate('Digit1', cmd).validate(),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('箭头'),
        ),
      ),
    );
    expect(() => withTranslate('Digit5', cmd | opt).validate(), returnsNormally);
    expect(() => withTranslate('Digit7', cmd).validate(), returnsNormally);
    expect(withTranslate('Digit5', cmd | opt).globalShortcutSlots, {
      (modifiers: cmd | opt, digit: 5): '全局翻译',
    });
  });

  group('网格编辑器', () {
    Future<ScreenshotToolbarPreferences Function()> pumpEditor(
      WidgetTester tester,
      ScreenshotToolbarPreferences value, {
      Map<({int modifiers, int digit}), String> reserved = const {},
      Set<({int modifiers, int digit})> systemSlots = const {},
    }) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var saved = value;
      await tester.pumpWidget(
        MaterialApp(
          theme: NativeGlassTheme.data(Brightness.dark),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ScreenshotToolbarEditor(
                value: value,
                onChanged: (next) => saved = next,
                reserved: reserved,
                systemSlots: systemSlots,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return () => saved;
    }

    Future<void> drag(WidgetTester tester, String id, Finder target) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(ValueKey('drag-$id'))),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await gesture.moveTo(tester.getCenter(target));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('全局快捷键占用的空格不可放入并说明用途；与系统快捷键相同的格子标红说明系统优先', (tester) async {
      final saved = await pumpEditor(
        tester,
        ScreenshotToolbarPreferences(),
        reserved: {(modifiers: opt, digit: 6): '全局翻译'},
        systemSlots: {(modifiers: cmd, digit: 1)},
      );
      expect(find.text('已用于全局翻译'), findsOneWidget);
      await drag(
        tester,
        ScreenshotActions.close,
        find.byKey(const ValueKey('toolbar-slot-1-5')),
      );
      expect(saved().shortcutLabel(ScreenshotActions.close), '⌥5');
      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey('toolbar-conflict-${ScreenshotActions.arrow}'),
              ),
            )
            .data,
        '系统优先',
      );
      expect(
        find.byKey(
          const ValueKey('toolbar-conflict-${ScreenshotActions.text}'),
        ),
        findsNothing,
      );
    });

    testWidgets('拖动组头手柄调整组顺序，组合与格位随组移动、快捷键不变；方向键上下移动组', (tester) async {
      final saved = await pumpEditor(tester, ScreenshotToolbarPreferences());
      await drag(
        tester,
        'column-1',
        find.byKey(const ValueKey('toolbar-column-0')),
      );
      expect(saved().columns.map((c) => c.modifiers), [opt, cmd]);
      expect(saved().shortcutLabel(ScreenshotActions.beautify), '⌥1');
      expect(saved().shortcutLabel(ScreenshotActions.arrow), '⌘1');

      await tester.tap(find.byKey(const ValueKey('drag-column-0')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(saved().columns.map((c) => c.modifiers), [opt, cmd]);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(saved().columns.map((c) => c.modifiers), [cmd, opt]);
      expect(saved().shortcutLabel(ScreenshotActions.beautify), '⌥1');
    });

    testWidgets('表头标出 1–6；拖到有工具的格子交换，拖到空格留下原位空格', (tester) async {
      final saved = await pumpEditor(tester, ScreenshotToolbarPreferences());
      final digits = find.descendant(
        of: find.byKey(const ValueKey('toolbar-digits')),
        matching: find.byType(Text),
      );
      expect(
        [for (final text in tester.widgetList<Text>(digits)) text.data],
        ['1', '2', '3', '4', '5', '6'],
      );
      expect(
        tester.getCenter(digits.first).dx,
        tester.getCenter(find.byKey(const ValueKey('toolbar-slot-0-0'))).dx,
      );
      await drag(
        tester,
        ScreenshotActions.arrow,
        find.byKey(const ValueKey('toolbar-slot-1-0')),
      );
      expect(saved().shortcutLabel(ScreenshotActions.arrow), '⌥1');
      expect(saved().shortcutLabel(ScreenshotActions.beautify), '⌘1');

      await drag(
        tester,
        ScreenshotActions.close,
        find.byKey(const ValueKey('toolbar-slot-1-5')),
      );
      expect(saved().shortcutLabel(ScreenshotActions.close), '⌥6');
      expect(saved().columns[1].slots[4], isNull);
    });

    testWidgets('添加组用第一个未使用的组合，只有空组可删除，组合下拉不含其他组已用的组合', (tester) async {
      final saved = await pumpEditor(tester, ScreenshotToolbarPreferences());
      expect(
        find.byKey(const ValueKey('toolbar-remove-column-0')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('toolbar-add-column')));
      await tester.pumpAndSettle();
      expect(saved().columns.last.modifiers, ctrl);
      final menu = tester.widget<NativeGlassMenuButton<int>>(
        find.byKey(const ValueKey('toolbar-modifiers-2')),
      );
      expect(menu.items.keys, isNot(contains(cmd)));
      expect(menu.items.keys, contains(ctrl));
      await tester.tap(find.byKey(const ValueKey('toolbar-remove-column-2')));
      await tester.pumpAndSettle();
      expect(saved().columns.length, 2);
    });

    testWidgets('点按可承载子级的工具显示子级列表；格位工具拖入成为子级，子级拖出到格位成为一级', (tester) async {
      final saved = await pumpEditor(tester, ScreenshotToolbarPreferences());
      await tester.tap(
        find.byKey(
          const ValueKey('toolbar-favorite-cell-${ScreenshotActions.crop}'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('截图的子级'), findsOneWidget);
      final end = find.byKey(
        const ValueKey('toolbar-children-end-${ScreenshotActions.crop}'),
      );
      await tester.ensureVisible(end);
      await drag(tester, 'favorite-${ScreenshotActions.pin}', end);
      expect(
        saved().children[ScreenshotActions.crop]!.last,
        ScreenshotActions.pin,
      );
      expect(saved().shortcutLabel(ScreenshotActions.pin), isNull);
      expect(saved().favorites, isNot(contains(ScreenshotActions.pin)));

      await drag(tester, ScreenshotActions.beautify, end);
      expect(
        saved().children[ScreenshotActions.crop]!.contains(
          ScreenshotActions.beautify,
        ),
        isFalse,
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('drag-${ScreenshotActions.scrolling}')),
      );
      await drag(
        tester,
        ScreenshotActions.scrolling,
        find.byKey(const ValueKey('toolbar-slot-1-5')),
      );
      expect(saved().shortcutLabel(ScreenshotActions.scrolling), '⌥6');
      expect(
        saved().children[ScreenshotActions.crop],
        isNot(contains(ScreenshotActions.scrolling)),
      );
    });

    testWidgets('隐藏保留格位与键位；方向键与相邻格交换', (tester) async {
      final saved = await pumpEditor(tester, ScreenshotToolbarPreferences());
      await tester.tap(
        find.byKey(const ValueKey('visibility-${ScreenshotActions.arrow}')),
      );
      await tester.pumpAndSettle();
      expect(saved().hidden, {ScreenshotActions.arrow});
      expect(saved().shortcutLabel(ScreenshotActions.arrow), '⌘1');

      await tester.tap(
        find.byKey(const ValueKey('drag-${ScreenshotActions.arrow}')),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(saved().shortcutLabel(ScreenshotActions.arrow), '⌘2');
      expect(saved().shortcutLabel(ScreenshotActions.step), '⌘1');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(saved().shortcutLabel(ScreenshotActions.arrow), '⌥2');
    });

    testWidgets('组头眼睛一次隐藏整组，全部隐藏时一次全部显示；格子按内容宽等分不横向滚动', (tester) async {
      final saved = await pumpEditor(tester, ScreenshotToolbarPreferences());
      final column = ScreenshotToolbarPreferences().columns[1];
      final ids = column.slots.nonNulls.toSet();
      final first = ids.first;
      final label = ScreenshotToolbarPreferences().shortcutLabel(first);
      if (!saved().hidden.contains(first)) {
        await tester.tap(find.byKey(ValueKey('visibility-$first')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('toolbar-hide-column-1')));
      await tester.pumpAndSettle();
      expect(saved().hidden.containsAll(ids), isTrue);
      expect(saved().shortcutLabel(first), label);
      await tester.tap(find.byKey(const ValueKey('toolbar-hide-column-1')));
      await tester.pumpAndSettle();
      expect(saved().hidden.intersection(ids), isEmpty);

      final grid = find.byKey(const ValueKey('toolbar-grid'));
      expect(
        tester.getSize(find.byKey(const ValueKey('toolbar-slot-0-0'))).width,
        ScreenshotToolbarEditor.cellWidth,
      );
      tester.view.physicalSize = const Size(400, 1200);
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('toolbar-slot-0-0'))).width,
        50,
      );
      expect(
        find.descendant(of: grid, matching: find.byType(Scrollable)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('方向键移动与修改组组合在冲突全局快捷键时拒绝保存并展示横幅（#144）', (tester) async {
      final base = ScreenshotToolbarPreferences();
      final customColumns = [
        ToolbarColumn(cmd, [
          ScreenshotActions.arrow,
          null,
          ...base.columns[0].slots.skip(2),
        ]),
        base.columns[1].withSlot(5, ScreenshotActions.step),
      ];
      final custom = base.copyWith(columns: customColumns);
      final saved = await pumpEditor(
        tester,
        custom,
        reserved: {
          (modifiers: cmd, digit: 2): '全局截图',
          (modifiers: ctrl, digit: 1): '全局翻译',
        },
      );

      await tester.tap(
        find.byKey(const ValueKey('drag-${ScreenshotActions.arrow}')),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(find.byType(NativeGlassBanner), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(NativeGlassBanner),
          matching: find.textContaining('全局截图'),
        ),
        findsOneWidget,
      );
      expect(saved().shortcutLabel(ScreenshotActions.arrow), '⌘1');

      await tester.tap(find.byKey(const ValueKey('toolbar-modifiers-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, '⌃').last);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(NativeGlassBanner),
          matching: find.textContaining('全局翻译'),
        ),
        findsOneWidget,
      );
      expect(saved().columns.first.modifiers, cmd);
    });

    testWidgets('Enter/Space 展开子级面板、键盘按钮移出与移入子级工作正常（#144）', (tester) async {
      final saved = await pumpEditor(tester, ScreenshotToolbarPreferences());

      Focus.of(
        tester.element(
          find.byKey(
            const ValueKey('toolbar-favorite-cell-${ScreenshotActions.crop}'),
          ),
        ),
      ).requestFocus();
      await tester.pump();
      expect(find.text('截图的子级'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('截图的子级'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.text('截图的子级'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.text('截图的子级'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(
          const ValueKey('promote-child-${ScreenshotActions.scrolling}'),
        ),
      );
      await tester.tap(
        find.byKey(
          const ValueKey('promote-child-${ScreenshotActions.scrolling}'),
        ),
      );
      await tester.pumpAndSettle();
      expect(saved().shortcutLabel(ScreenshotActions.scrolling), '⌘5');
      expect(
        saved().children[ScreenshotActions.crop],
        isNot(contains(ScreenshotActions.scrolling)),
      );

      await tester.ensureVisible(
        find.byKey(
          const ValueKey('toolbar-add-child-${ScreenshotActions.crop}'),
        ),
      );
      await tester.tap(
        find.byKey(
          const ValueKey('toolbar-add-child-${ScreenshotActions.crop}'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('贴图').last);
      await tester.pumpAndSettle();
      expect(
        saved().children[ScreenshotActions.crop],
        contains(ScreenshotActions.pin),
      );
      expect(saved().shortcutLabel(ScreenshotActions.pin), isNull);
      expect(saved().favorites, isNot(contains(ScreenshotActions.pin)));
    });

    testWidgets('恢复默认空闲时禁用，编辑后需确认且恢复出厂排布（#144）', (tester) async {
      final saved = await pumpEditor(tester, ScreenshotToolbarPreferences());
      TextButton resetButton() => tester.widget<TextButton>(
        find.byKey(const ValueKey('toolbar-reset-default')),
      );
      expect(resetButton().onPressed, isNull);

      await tester.tap(
        find.byKey(const ValueKey('visibility-${ScreenshotActions.arrow}')),
      );
      await tester.pumpAndSettle();
      expect(resetButton().onPressed, isNotNull);

      await tester.tap(find.byKey(const ValueKey('toolbar-reset-default')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(saved().hidden, {ScreenshotActions.arrow});

      await tester.tap(find.byKey(const ValueKey('toolbar-reset-default')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '恢复默认'));
      await tester.pumpAndSettle();
      expect(saved().hidden, isEmpty);
      expect(resetButton().onPressed, isNull);
    });

    testWidgets('眼睛按钮命中区至少 24pt 且系统冲突文本使用高对比配色（#144）', (tester) async {
      await pumpEditor(
        tester,
        ScreenshotToolbarPreferences(),
        systemSlots: {(modifiers: cmd, digit: 1)},
      );
      final eyeSize = tester.getSize(
        find.byKey(const ValueKey('visibility-${ScreenshotActions.arrow}')),
      );
      expect(eyeSize.width, greaterThanOrEqualTo(24));
      expect(eyeSize.height, greaterThanOrEqualTo(24));

      final conflictText = find.byKey(
        const ValueKey('toolbar-conflict-${ScreenshotActions.arrow}'),
      );
      final element = tester.element(conflictText);
      expect(
        tester.widget<Text>(conflictText).style!.color,
        ScreenshotToolbarEditor.conflictColor(element),
      );
    });
    testWidgets('常用组：表头 1–6，与网格之间拖动为移动且工具只占一个键位，常用之间交换，拖到别处不变，方向键调整顺序（#1）', (
      tester,
    ) async {
      final saved = await pumpEditor(tester, ScreenshotToolbarPreferences());
      final digits = find.descendant(
        of: find.byKey(const ValueKey('toolbar-favorite-digits')),
        matching: find.byType(Text),
      );
      expect(
        [for (final text in tester.widgetList<Text>(digits)) text.data],
        ['1', '2', '3', '4', '5', '6'],
      );
      for (final (index, id) in ScreenshotActions.defaultFavorites.indexed) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('toolbar-favorite-$index')),
            matching: find.byKey(ValueKey('toolbar-favorite-cell-$id')),
          ),
          findsOneWidget,
        );
      }

      await drag(
        tester,
        ScreenshotActions.arrow,
        find.byKey(const ValueKey('toolbar-favorite-5')),
      );
      expect(saved().favorites.last, ScreenshotActions.arrow);
      expect(saved().shortcutLabel(ScreenshotActions.arrow), '6');
      expect(saved().shortcutLabel(ScreenshotActions.pin), '⌘1');

      await drag(
        tester,
        'favorite-${ScreenshotActions.arrow}',
        find.byKey(const ValueKey('toolbar-favorite-0')),
      );
      expect(saved().favorites.first, ScreenshotActions.arrow);
      expect(saved().favorites.last, ScreenshotActions.crop);

      await drag(
        tester,
        'favorite-${ScreenshotActions.record}',
        find.byKey(const ValueKey('toolbar-slot-1-5')),
      );
      expect(saved().favorites, isNot(contains(ScreenshotActions.record)));
      expect(saved().shortcutLabel(ScreenshotActions.record), '⌥6');
      final afterMove = saved().favorites;

      await drag(
        tester,
        'favorite-${ScreenshotActions.ocrCopy}',
        find.byKey(const ValueKey('toolbar-favorite-digits')),
      );
      expect(saved().favorites, afterMove);

      Focus.of(
        tester.element(
          find.byKey(
            const ValueKey('toolbar-favorite-cell-${ScreenshotActions.crop}'),
          ),
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(
        saved().favorites.indexOf(ScreenshotActions.crop),
        afterMove.indexOf(ScreenshotActions.crop) - 1,
      );
    });
  });
}
