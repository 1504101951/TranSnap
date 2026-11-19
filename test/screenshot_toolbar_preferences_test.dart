import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/preference_keys.dart';
import 'package:translate_app/src/common/constants/screenshot_actions.dart';
import 'package:translate_app/src/common/constants/toolbar_grid.dart';
import 'package:translate_app/src/settings/app_settings.dart';
import 'package:translate_app/src/common/constants/shortcut_keys.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/settings/screenshot_toolbar_editor.dart';
import 'package:translate_app/src/settings/screenshot_toolbar_preferences.dart';

/// 覆盖网格配置的推导、校验、读取补位与编辑器操作后的真实配置（#141），不检查下游调用次数。
void main() {
  const cmd = ToolbarModifiers.command;
  const opt = ToolbarModifiers.option;
  const ctrl = ToolbarModifiers.control;

  test('默认网格为无、⌘、⌥ 三列 6+6+4，格位推导快捷键', () {
    // 作用：默认按注册表顺序去掉默认子级后每列填 6 格，格位即快捷键。
    // 边界：第 1 列第 1 格为裸数字 1；第 2 列第 2 格为 ⌘2；第 3 列只有 4 个工具，第 5、6 格为空。
    final value = ScreenshotToolbarPreferences();
    expect(value.columns.map((c) => c.modifiers), [0, cmd, opt]);
    expect(value.columns[0].slots.first, ScreenshotActions.cursor);
    expect(value.columns[1].slots[1], ScreenshotActions.beautify);
    expect(value.columns[2].slots.sublist(4), [null, null]);
    expect(value.shortcutLabel(ScreenshotActions.cursor), '1');
    expect(value.shortcutLabel(ScreenshotActions.beautify), '⌘2');
    expect(value.shortcutLabel(ScreenshotActions.close), '⌥4');
    // 子级没有快捷键。
    expect(value.shortcutLabel(ScreenshotActions.record), isNull);
    expect(value.actionAt(cmd, 2), ScreenshotActions.beautify);
    expect(value.actionAt(opt, 5), isNull);
    expect(value.actionAt(ctrl, 1), isNull);
  });

  test('网格、子级与隐藏往返保存；空格存为空字符串', () {
    // 作用：保存后重新读取得到相同的格位、组合、子级与隐藏集合。
    // 边界：属性列表不能存 null，空格以空字符串保存，读回为 null。
    final value = ScreenshotToolbarPreferences(hidden: {ScreenshotActions.pin});
    final map = value.toMap();
    expect(
      (map[PreferenceKeys.screenshotToolbarColumns] as List).last,
      containsPair('slots', contains('')),
    );
    final restored = ScreenshotToolbarPreferences.fromMap(map);
    expect(
      restored.columns.map((c) => c.slots),
      value.columns.map((c) => c.slots),
    );
    expect(restored.columns.map((c) => c.modifiers), [0, cmd, opt]);
    expect(restored.children, value.children);
    expect(restored.hidden, {ScreenshotActions.pin});
  });

  test('没有网格的旧结构整体重置为默认网格，不迁移旧顺序与快捷键', () {
    // 作用：旧配置只有顺序与逐项快捷键时读取为默认网格（用户确认不迁移）。
    // 边界：旧键与旧的隐藏、子级都不保留。
    final restored = ScreenshotToolbarPreferences.fromMap({
      'screenshotToolbarOrder': [ScreenshotActions.close],
      'screenshotToolbarShortcuts': {
        ScreenshotActions.close: {'keyId': 0x31, 'modifiers': 0},
      },
      PreferenceKeys.screenshotToolbarHidden: [ScreenshotActions.copy],
    });
    final defaults = ScreenshotToolbarPreferences();
    expect(
      restored.columns.map((c) => c.slots),
      defaults.columns.map((c) => c.slots),
    );
    expect(restored.hidden, isEmpty);
  });

  test('已保存网格缺少的功能：默认父级是一级时挂回，否则放进第一个空格，满了新增一列', () {
    // 作用：增加可拼接功能后，旧网格读取不失败且新功能有位置。
    // 边界：缺失的「录制」默认父级「截图」仍在格位 → 挂回其子级；缺失的「关闭」放进第一个空格；
    // 网格全满时用第一个未使用的组合（⌥）新增一列。
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
      PreferenceKeys.screenshotToolbarChildren: {
        ScreenshotActions.crop: [
          ScreenshotActions.scrolling,
          ScreenshotActions.eyedropper,
          ScreenshotActions.ruler,
        ],
        ScreenshotActions.beautify: [ScreenshotActions.sticker],
      },
    });
    expect(
      restored.children[ScreenshotActions.crop],
      contains(ScreenshotActions.record),
    );
    expect(restored.shortcutLabel(ScreenshotActions.close), '⌥4');

    // 两列共 12 格放满一级之外的 4 个工具无处可放，需新增第三列。
    final twelve = topLevel.take(12).toList();
    final packed = ScreenshotToolbarPreferences.fromMap({
      PreferenceKeys.screenshotToolbarColumns: [
        ToolbarColumn(0, twelve.sublist(0, 6)).toMap(),
        ToolbarColumn(cmd, twelve.sublist(6, 12)).toMap(),
      ],
      PreferenceKeys.screenshotToolbarChildren:
          ScreenshotActions.defaultChildren,
    });
    expect(packed.columns.map((c) => c.modifiers), [0, cmd, opt]);
    expect(packed.columns[2].slots.whereType<String>(), topLevel.skip(12));
  });

  test('校验：组合只能是 ⌘⌥⌃ 的组合、不含 ⇧、各列不重复，每列 6 格，最多 8 列', () {
    // 作用：网格结构不合法时拒绝保存。
    // 边界：⇧(4) 单独或与 ⌘ 组合都拒绝；两列同为 ⌘ 拒绝；5 格拒绝；9 列超过上限拒绝。
    final base = ScreenshotToolbarPreferences();
    ScreenshotToolbarPreferences withModifiers(List<int> modifiers) =>
        base.copyWith(
          columns: [
            for (final (index, column) in base.columns.indexed)
              ToolbarColumn(modifiers[index], column.slots),
          ],
        );
    for (final invalid in [
      [0, ToolbarModifiers.shift, opt],
      [0, cmd | ToolbarModifiers.shift, opt],
      [0, cmd, cmd],
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
              ToolbarColumn(0, base.columns[0].slots.take(5).toList()),
              ...base.columns.skip(1),
            ],
          )
          .validate(),
      throwsFormatException,
    );
    final nine = [
      ...base.columns,
      for (final modifiers in ToolbarModifiers.allowed.skip(3))
        ToolbarColumn(modifiers, List.filled(ToolbarGrid.slots, null)),
      ToolbarColumn(cmd | opt, List.filled(ToolbarGrid.slots, null)),
    ];
    expect(nine.length, 9);
    expect(
      () => base.copyWith(columns: nine).validate(),
      throwsFormatException,
    );
  });

  test('校验：每个功能在格位与子级中恰好一次，只有一级的工具可以带子级', () {
    // 作用：重复、缺失或把子级挂到动作下时拒绝。
    // 边界：同一功能放进两个格位；子级挂在「保存」（动作）下；子级挂在不在格位中的父级下。
    final base = ScreenshotToolbarPreferences();
    final duplicate = base.copyWith(
      columns: [
        base.columns[0],
        base.columns[1],
        base.columns[2].withSlot(4, ScreenshotActions.cursor),
      ],
    );
    expect(duplicate.validate, throwsFormatException);
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

  test('全局快捷键与系统快捷键按数字行键码换算为格位，带 ⇧ 或 7 以外的键不落在网格', () {
    // 作用：冲突判断以格位为准，Carbon 与 NSEvent 两种修饰键表示都换算为工具栏位掩码。
    // 边界：键码 18 为 1、22 为 6（ANSI 键码不连续）；26 为 7 不在网格；带 ⇧ 时不属于工具栏。
    expect(ToolbarGrid.slotOfCarbon(18, ShortcutKeys.command), (
      modifiers: cmd,
      digit: 1,
    ));
    expect(
      ToolbarGrid.slotOfCarbon(22, ShortcutKeys.control | ShortcutKeys.option),
      (modifiers: ctrl | opt, digit: 6),
    );
    expect(ToolbarGrid.slotOfCarbon(26, ShortcutKeys.command), isNull);
    expect(
      ToolbarGrid.slotOfCarbon(18, ShortcutKeys.command | ShortcutKeys.shift),
      isNull,
    );
    // NSEvent：Control 1<<18、Command 1<<20、Shift 1<<17。
    expect(ToolbarGrid.slotOfCocoa(18, 1 << 18), (modifiers: ctrl, digit: 1));
    expect(ToolbarGrid.slotOfCocoa(19, (1 << 20) | (1 << 17)), isNull);
  });

  test('全局快捷键落在有工具的格位时拒绝保存，落在空格或网格外时允许', () {
    // 作用：全局快捷键独占注册，与工具栏格位互斥，两侧修改都在设置提交校验中拒绝。
    // 边界：⌘1 是默认网格中画笔的格位 → 拒绝；⌥5 是默认空格 → 允许；⌘7 不在网格 → 允许。
    AppSettings withTranslate(int code, int modifiers) => AppSettings(
      primaryLanguage: 'zh-CN',
      shortcutKeyCode: code,
      shortcutLabel: 'x',
      shortcutModifiers: modifiers,
    );
    expect(
      () => withTranslate(18, ShortcutKeys.command).validate(),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('画笔'),
        ),
      ),
    );
    expect(
      () => withTranslate(23, ShortcutKeys.option).validate(),
      returnsNormally,
    );
    expect(
      () => withTranslate(26, ShortcutKeys.command).validate(),
      returnsNormally,
    );
    expect(withTranslate(23, ShortcutKeys.option).globalShortcutSlots, {
      (modifiers: opt, digit: 5): '全局翻译',
    });
  });

  group('网格编辑器', () {
    /// tester 为测试驱动，value 为初始配置，reserved/systemSlots 为全局占用与系统冲突格位；
    /// 返回读取最新已保存配置的函数。
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

    /// tester 为测试驱动；把 id 的拖拽手柄拖到 target 部件中心后松手。
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
      // 作用：防冲突在编辑入口可见。
      // 边界：⌥5 被全局翻译占用，拖入关闭后配置不变；⌘1（画笔）与系统快捷键相同时键位说明为「⌘1 系统优先」。
      final saved = await pumpEditor(
        tester,
        ScreenshotToolbarPreferences(),
        reserved: {(modifiers: opt, digit: 5): '全局翻译'},
        systemSlots: {(modifiers: cmd, digit: 1)},
      );
      expect(find.text('⌥5 已用于全局翻译'), findsOneWidget);
      await drag(
        tester,
        ScreenshotActions.close,
        find.byKey(const ValueKey('toolbar-slot-2-4')),
      );
      expect(saved().shortcutLabel(ScreenshotActions.close), '⌥4');
      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey('toolbar-key-${ScreenshotActions.brush}'),
              ),
            )
            .data,
        '⌘1 系统优先',
      );
    });

    testWidgets('拖动列头手柄调整列顺序，组合与格位随列移动、快捷键不变；方向键左右移动列', (tester) async {
      // 作用：只改变工具栏上的列排列，不改变任何工具的快捷键（用户确认）。
      // 边界：把 ⌘ 列（第 2 列）拖到第 1 列上 → 顺序变为 ⌘、无、⌥，画笔仍是 ⌘1、光标仍是 1；
      // 聚焦 ⌘ 列手柄按右方向键 → 回到第 2 列；最左列再按左方向键不动。
      final saved = await pumpEditor(tester, ScreenshotToolbarPreferences());
      await drag(
        tester,
        'column-1',
        find.byKey(const ValueKey('toolbar-column-0')),
      );
      expect(saved().columns.map((c) => c.modifiers), [cmd, 0, opt]);
      expect(saved().shortcutLabel(ScreenshotActions.brush), '⌘1');
      expect(saved().shortcutLabel(ScreenshotActions.cursor), '1');

      await tester.tap(find.byKey(const ValueKey('drag-column-0')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(saved().columns.map((c) => c.modifiers), [cmd, 0, opt]);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(saved().columns.map((c) => c.modifiers), [0, cmd, opt]);
      expect(saved().shortcutLabel(ScreenshotActions.brush), '⌘1');
    });

    testWidgets('格子显示键位；拖到有工具的格子交换，拖到空格留下原位空格', (tester) async {
      // 作用：格位决定快捷键，拖动即改变快捷键且不会出现重复。
      // 边界：光标（1）拖到画笔（⌘1）交换；关闭（⌥4）拖到空格 ⌥6 后原格 ⌥4 变空。
      final saved = await pumpEditor(tester, ScreenshotToolbarPreferences());
      expect(
        tester
            .widget<Text>(
              find.byKey(
                const ValueKey('toolbar-key-${ScreenshotActions.brush}'),
              ),
            )
            .data,
        '⌘1',
      );
      await drag(
        tester,
        ScreenshotActions.cursor,
        find.byKey(const ValueKey('toolbar-slot-1-0')),
      );
      expect(saved().shortcutLabel(ScreenshotActions.cursor), '⌘1');
      expect(saved().shortcutLabel(ScreenshotActions.brush), '1');

      await drag(
        tester,
        ScreenshotActions.close,
        find.byKey(const ValueKey('toolbar-slot-2-5')),
      );
      expect(saved().shortcutLabel(ScreenshotActions.close), '⌥6');
      expect(saved().columns[2].slots[3], isNull);
    });

    testWidgets('添加列用第一个未使用的组合，只有空列可删除，组合下拉不含其他列已用的组合', (tester) async {
      // 作用：列组合不重复由编辑器入口保证。
      // 边界：默认已用无、⌘、⌥，新列为 ⌃；有工具的列没有删除入口。
      final saved = await pumpEditor(tester, ScreenshotToolbarPreferences());
      expect(
        find.byKey(const ValueKey('toolbar-remove-column-0')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('toolbar-add-column')));
      await tester.pumpAndSettle();
      expect(saved().columns.last.modifiers, ctrl);
      final menu = tester.widget<NativeGlassMenuButton<int>>(
        find.byKey(const ValueKey('toolbar-modifiers-3')),
      );
      expect(menu.items.keys, isNot(contains(cmd)));
      expect(menu.items.keys, contains(ctrl));
      await tester.tap(find.byKey(const ValueKey('toolbar-remove-column-3')));
      await tester.pumpAndSettle();
      expect(saved().columns.length, 3);
    });

    testWidgets('点按可承载子级的工具显示子级列表；格位工具拖入成为子级，子级拖出到格位成为一级', (tester) async {
      // 作用：子级没有快捷键，拖进格位才获得快捷键。
      // 边界：贴图（动作，无子级）拖进「截图」子级末尾，原格留空；录制拖到空格 ⌥5 获得键位；
      // 带子级的「美化」不能成为子级，拖入后配置不变。
      final saved = await pumpEditor(tester, ScreenshotToolbarPreferences());
      await tester.tap(
        find.byKey(const ValueKey('toolbar-cell-${ScreenshotActions.crop}')),
      );
      await tester.pumpAndSettle();
      expect(find.text('截图的子级'), findsOneWidget);
      final end = find.byKey(
        const ValueKey('toolbar-children-end-${ScreenshotActions.crop}'),
      );
      await tester.ensureVisible(end);
      await drag(tester, ScreenshotActions.pin, end);
      expect(
        saved().children[ScreenshotActions.crop]!.last,
        ScreenshotActions.pin,
      );
      expect(saved().shortcutLabel(ScreenshotActions.pin), isNull);

      await drag(tester, ScreenshotActions.beautify, end);
      expect(
        saved().children[ScreenshotActions.crop]!.contains(
          ScreenshotActions.beautify,
        ),
        isFalse,
      );

      await tester.ensureVisible(
        find.byKey(const ValueKey('drag-${ScreenshotActions.record}')),
      );
      await drag(
        tester,
        ScreenshotActions.record,
        find.byKey(const ValueKey('toolbar-slot-2-4')),
      );
      expect(saved().shortcutLabel(ScreenshotActions.record), '⌥5');
      expect(
        saved().children[ScreenshotActions.crop],
        isNot(contains(ScreenshotActions.record)),
      );
    });

    testWidgets('隐藏保留格位与键位；方向键与相邻格交换', (tester) async {
      // 作用：隐藏不改变快捷键；键盘可以完成排列。
      // 边界：隐藏光标后仍是 1；聚焦光标手柄按下方向键与第 2 格「截图」交换，按右方向键移到 ⌘ 列同一格。
      final saved = await pumpEditor(tester, ScreenshotToolbarPreferences());
      await tester.tap(
        find.byKey(const ValueKey('visibility-${ScreenshotActions.cursor}')),
      );
      await tester.pumpAndSettle();
      expect(saved().hidden, {ScreenshotActions.cursor});
      expect(saved().shortcutLabel(ScreenshotActions.cursor), '1');

      await tester.tap(
        find.byKey(const ValueKey('drag-${ScreenshotActions.cursor}')),
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(saved().shortcutLabel(ScreenshotActions.cursor), '2');
      expect(saved().shortcutLabel(ScreenshotActions.crop), '1');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(saved().shortcutLabel(ScreenshotActions.cursor), '⌘2');
    });
  });
}
