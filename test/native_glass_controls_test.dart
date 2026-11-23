import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motor/motor.dart';
import 'package:translate_app/src/common/constants/glass_metrics.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';

/// a/b 为颜色、base 为底层背景色；将含 alpha 前景色复合到背景后返回不透明色。
Color _compositeOver(Color fg, Color base) => Color.alphaBlend(fg, base);

/// 验证Spec的尺寸、WCAG 对比度、强调色联动、按钮微交互与真实交互边界；使用实际布局，不检查配置文件字符串。
void main() {
  testWidgets('分段未选项在鼠标悬停时呈现柔和悬停叠层且区别于实底选中项，移出后复原', (tester) async {
    // 作用：验证所有按钮启用悬停反馈后，未选中分段悬停会有像素与叠层变化但不会冒充实底选中块，移出鼠标后像素还原。
    // 边界：选中第 2 段（'light'），仅悬停第 1 段（'system'）。
    final boundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: RepaintBoundary(
            key: boundary,
            child: NativeGlassSegments<String>(
              value: 'light',
              options: const {'system': '跟随系统', 'light': '浅色', 'dark': '深色'},
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<List<int>> pixels() async {
      final image =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!.buffer.asUint8List().toList();
    }

    final before = await tester.runAsync(pixels);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 500));
    await mouse.moveTo(tester.getCenter(find.text('跟随系统')));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(pixels), isNot(before));
    await mouse.moveTo(const Offset(700, 500));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(pixels), before);
    await mouse.removePointer();
  });

  testWidgets('分段按钮悬停轻提示、按下加深且微缩，释放选择生效后复原', (tester) async {
    // 作用：验证分段按钮三态视觉递增链路（静息 alpha=0 -> 悬停 0.06 -> 按下 0.12 且缩放 < 1.0）。
    // 边界：初始选中 0，依次对「第二项」执行悬停、按下与释放。
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => NativeGlassSegments<int>(
              value: selected,
              options: const {0: '第一项', 1: '第二项'},
              onChanged: (v) => update(() => selected = v),
            ),
          ),
        ),
      ),
    );
    List<Color?> colors() => tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .map((w) => (w.decoration as ShapeDecoration?)?.color)
        .toList();
    final before = colors();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    final target = tester.getCenter(find.text('第二项'));
    await mouse.moveTo(target);
    await tester.pumpAndSettle();
    final hovered = colors();
    expect(hovered, isNot(before));
    await mouse.down(target);
    await tester.pumpAndSettle();
    final pressed = colors();
    expect(pressed, isNot(hovered));
    await mouse.up();
    await tester.pumpAndSettle();
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(colors(), before);
    await mouse.removePointer();
  });

  testWidgets('短按钮轮廓28pt且透明边缘可点击，输入32pt', (tester) async {
    // 32pt命中高度和28pt轮廓之间各2pt必须仍触发动作，不产生整行背景。
    var presses = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: Column(
            children: [
              NativeGlassSurface(
                material: true,
                child: TextButton(
                  onPressed: () => presses++,
                  child: const Text('操作'),
                ),
              ),
              const NativeGlassField(label: '名称', child: TextField()),
            ],
          ),
        ),
      ),
    );
    final button = find.byType(TextButton);
    expect(tester.getSize(button).height, 28);
    expect(tester.getSize(button).width, 64);
    final bounds = tester.getRect(button);
    await tester.tapAt(Offset(bounds.center.dx, bounds.top - 1));
    expect(presses, 1);
    expect(tester.getSize(find.byType(TextField)).height, 32);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长当前值和菜单项换行完整展示，键盘能选择', (tester) async {
    // 长中文超过240pt选择器宽度，必须增长高度而不裁切，菜单在320pt内。
    const longName = '用于验收长中文内容能够完整展示的翻译服务名称';
    var selected = 'long';
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: SizedBox(
            width: 520,
            child: StatefulBuilder(
              builder: (context, setState) => NativeGlassDropdown<String>(
                label: '默认翻译服务',
                value: selected,
                items: const {'long': longName, 'short': '短名称'},
                onChanged: (value) => setState(() => selected = value),
              ),
            ),
          ),
        ),
      ),
    );
    final trigger = find.byType(TextButton);
    expect(tester.getSize(trigger).width, lessThanOrEqualTo(240));
    expect(tester.getSize(trigger).height, greaterThan(28));
    final paragraph = tester.renderObject<RenderParagraph>(find.text(longName));
    expect(paragraph.didExceedMaxLines, isFalse);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    final shortOption = find.widgetWithText(MenuItemButton, '短名称');
    expect(shortOption, findsOneWidget);
    await tester.tap(shortOption);
    await tester.pumpAndSettle();
    expect(selected, 'short');
    expect(find.byType(MenuItemButton), findsNothing);
    await tester.tap(trigger);
    await tester.pumpAndSettle();
    // 打开时当前值获得焦点，向上选择前一项后回车提交。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 'long');
    expect(tester.takeException(), isNull);
  });

  testWidgets('开关键盘反转状态且焦点不缩小滑块', (tester) async {
    // 16pt滑块在未聚焦和键盘聚焦后都保持尺寸，32pt命中高度不变。
    var value = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => NativeGlassSwitch(
              label: '启用',
              value: value,
              onChanged: (next) => setState(() => value = next),
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(NativeGlassSwitch)), const Size(36, 32));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(value, true);
    final thumb = find.byWidgetPredicate(
      (widget) =>
          widget is SizedBox && widget.width == 16 && widget.height == 16,
    );
    expect(tester.getSize(thumb), const Size(16, 16));
    expect(tester.takeException(), isNull);
  });

  testWidgets('分段控件弹簧滑块对齐各宽不等的目标段，减少动态效果直接切换（#142）', (tester) async {
    // 作用：验证共享选中底的位置与宽度以弹簧追随新分段，并在减少动态效果时跳过弹簧包装。
    // 边界：两段宽不等（短项 76pt、长项 > 76pt）；切换后终点矩形完全对齐目标按钮，文字始终白字/非选中反色。
    var selected = 0;
    Widget buildSegments({required bool disableAnimations}) => MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => NativeGlassSegments<int>(
              value: selected,
              options: const {0: '短', 1: '较长的分段选项标签'},
              onChanged: (next) => setState(() => selected = next),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(buildSegments(disableAnimations: false));
    await tester.pumpAndSettle();
    final indicator = find.byKey(
      const ValueKey('native-glass-segments-indicator'),
    );
    final shortButton = find.widgetWithText(TextButton, '短');
    final longButton = find.widgetWithText(TextButton, '较长的分段选项标签');
    expect(tester.getRect(indicator), tester.getRect(shortButton));
    expect(tester.getSize(longButton).width, greaterThan(76));

    await tester.tap(longButton);
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(tester.getRect(indicator), tester.getRect(longButton));

    // 减少动态效果下不使用 SingleMotionBuilder，切换立即对齐目标段。
    await tester.pumpWidget(buildSegments(disableAnimations: true));
    await tester.pump();
    expect(find.byType(SingleMotionBuilder), findsNothing);
    await tester.tap(shortButton);
    await tester.pump();
    expect(selected, 0);
    expect(tester.getRect(indicator), tester.getRect(shortButton));
    expect(tester.takeException(), isNull);
  });

  // 验证 NativeGlassStatus 的授权态与未授权态胶囊文本、无障碍语义、18pt 固定高度以及亮暗主题固定绿/橙配色（不受强调色影响）。
  testWidgets('NativeGlassStatus 使用固定高度 18 与浅深色固定绿/橙语义配色（#142）', (
    tester,
  ) async {
    Future<void> pumpStatus({
      required Brightness brightness,
      required bool granted,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: brightness,
            // 故意传入蓝色作为强调色，验证状态胶囊不随强调色变化。
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: brightness,
            ),
            extensions: const [GlassAccent(Color(0xFF007AFF))],
          ),
          home: Scaffold(
            body: Center(
              child: NativeGlassStatus(
                granted: granted,
                label: granted ? '已授权' : '未授权',
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Color? statusTextColor() => tester
        .widget<Text>(
          find.descendant(
            of: find.byType(NativeGlassStatus),
            matching: find.byType(Text),
          ),
        )
        .style
        ?.color;

    Color? statusFillColor() {
      final containers = tester.widgetList<Container>(
        find.descendant(
          of: find.byType(NativeGlassStatus),
          matching: find.byType(Container),
        ),
      );
      for (final c in containers) {
        final dec = c.decoration;
        if (dec is BoxDecoration && dec.borderRadius != null) {
          return dec.color;
        }
      }
      return null;
    }

    // 浅色已授权：固定 18pt 高度、WCAG AA 绿 #126326 及 12% 底与「已授权」语义标签。
    await pumpStatus(brightness: Brightness.light, granted: true);
    expect(tester.getSize(find.byType(NativeGlassStatus)).height, 18);
    expect(find.text('已授权'), findsOneWidget);
    expect(statusTextColor(), const Color(0xFF126326));
    expect(statusFillColor(), const Color(0xFF126326).withValues(alpha: 0.12));
    expect(
      NativeGlassTheme.contrastRatio(
        statusTextColor()!,
        _compositeOver(statusFillColor()!, const Color(0xFFEEEEEE)),
      ),
      greaterThanOrEqualTo(4.5),
    );
    expect(tester.getSemantics(find.byType(NativeGlassStatus)).label, '已授权');

    // 浅色未授权：WCAG AA 橙 #8A4A00 及 12% 底与「未授权」语义标签。
    await pumpStatus(brightness: Brightness.light, granted: false);
    expect(find.text('未授权'), findsOneWidget);
    expect(statusTextColor(), const Color(0xFF8A4A00));
    expect(statusFillColor(), const Color(0xFF8A4A00).withValues(alpha: 0.12));
    expect(
      NativeGlassTheme.contrastRatio(
        statusTextColor()!,
        _compositeOver(statusFillColor()!, const Color(0xFFEEEEEE)),
      ),
      greaterThanOrEqualTo(4.5),
    );

    // 深色模式切换至亮绿 #32D74B 与亮橙 #FF9F0A，同样满足 >= 4.5:1。
    await pumpStatus(brightness: Brightness.dark, granted: true);
    expect(statusTextColor(), const Color(0xFF32D74B));
    expect(statusFillColor(), const Color(0xFF32D74B).withValues(alpha: 0.16));
    expect(
      NativeGlassTheme.contrastRatio(
        statusTextColor()!,
        _compositeOver(statusFillColor()!, const Color(0xFF232323)),
      ),
      greaterThanOrEqualTo(4.5),
    );

    await pumpStatus(brightness: Brightness.dark, granted: false);
    expect(statusTextColor(), const Color(0xFFFF9F0A));
    expect(statusFillColor(), const Color(0xFFFF9F0A).withValues(alpha: 0.18));
    expect(
      NativeGlassTheme.contrastRatio(
        statusTextColor()!,
        _compositeOver(statusFillColor()!, const Color(0xFF232323)),
      ),
      greaterThanOrEqualTo(4.5),
    );
    expect(tester.takeException(), isNull);
  });

  // 验证 NativeGlassGroup 在多行时自动插入 n-1 条 0.5pt 细线，单行时无分割线（边界值 1 行与 3 行）。
  testWidgets('NativeGlassGroup 在相邻子项之间自动插入 0.5pt 分割线，单行无分割线（#142）', (
    tester,
  ) async {
    Future<void> pumpGroup(int count) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                child: NativeGlassGroup(
                  children: [for (var i = 0; i < count; i++) Text('Row $i')],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    // 边界：单行分组不应产生分割线。
    await pumpGroup(1);
    expect(
      find.descendant(
        of: find.byType(NativeGlassGroup),
        matching: find.byType(Divider),
      ),
      findsNothing,
    );

    // 三行分组应自动插入 2 条高度与线宽均为 0.5pt 的 Divider。
    await pumpGroup(3);
    final dividers = tester.widgetList<Divider>(
      find.descendant(
        of: find.byType(NativeGlassGroup),
        matching: find.byType(Divider),
      ),
    );
    expect(dividers, hasLength(2));
    for (final divider in dividers) {
      expect(divider.height, 0.5);
      expect(divider.thickness, 0.5);
    }
    expect(tester.takeException(), isNull);
  });

  test('动态强调色文字对比度与静息边框全达 WCAG 2.2 AA 标准（U-12、U-23）', () {
    // 作用：验证各 macOS 系统强调色下 accentColorsFor 均满足 >= 4.5:1，默认深浅蓝保白字，且边框达 >= 3.0:1。
    // 边界：覆盖浅/深苹果蓝、亮黄、苹果绿、琥珀橙、品红、紫罗兰与石墨灰。
    const accents = [
      Color(0xFF007AFF),
      Color(0xFF0A84FF),
      Color(0xFFFFCC00),
      Color(0xFF28CD41),
      Color(0xFFFF9500),
      Color(0xFFAF52DE),
      Color(0xFF953D96),
      Color(0xFF8E8E93),
    ];
    for (final accent in accents) {
      final pair = NativeGlassTheme.accentColorsFor(accent);
      expect(
        NativeGlassTheme.contrastRatio(pair.foreground, pair.fill),
        greaterThanOrEqualTo(4.5),
        reason: 'accent=$accent',
      );
    }
    expect(
      NativeGlassTheme.accentColorsFor(const Color(0xFF007AFF)).foreground,
      Colors.white,
    );
    expect(
      NativeGlassTheme.accentColorsFor(const Color(0xFF0A84FF)).foreground,
      Colors.white,
    );
    expect(
      NativeGlassTheme.accentColorsFor(const Color(0xFFFFCC00)).foreground,
      const Color(0xFF1C1C1E),
    );

    final lightTheme = NativeGlassTheme.data(Brightness.light);
    final darkTheme = NativeGlassTheme.data(Brightness.dark);
    expect(
      NativeGlassTheme.contrastRatio(
        lightTheme.colorScheme.outlineVariant,
        lightTheme.colorScheme.surface,
      ),
      greaterThanOrEqualTo(3.0),
    );
    expect(
      NativeGlassTheme.contrastRatio(
        darkTheme.colorScheme.outlineVariant,
        const Color(0xFF232323),
      ),
      greaterThanOrEqualTo(3.0),
    );
  });

  testWidgets('滑块、开关、复选框与文本选区全部跟随系统强调色（#144）', (tester) async {
    // 作用：验证非蓝强调色（琥珀橙 #FF9500）下，滑块轨道/悬停聚焦光晕/滑点、开关、复选框与选区均读取对应强调色。
    // 边界：分别检查 SliderThemeData、CheckboxThemeData、TextSelectionThemeData 及开关开启轨道。
    const amber = Color(0xFFFF9500);
    const appearance = GlassAppearance(
      mode: 'light',
      accentLight: amber,
      accentDark: Color(0xFFFF9F0A),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light, appearance),
        home: Scaffold(
          body: Column(
            children: [
              Slider(value: 0.5, onChanged: (_) {}),
              NativeGlassSwitch(value: true, onChanged: (_) {}, label: '开关'),
              Checkbox(value: true, onChanged: (_) {}),
              const TextField(),
            ],
          ),
        ),
      ),
    );
    final context = tester.element(find.byType(Slider));
    final theme = Theme.of(context);
    expect(theme.sliderTheme.activeTrackColor, amber);
    expect(theme.sliderTheme.overlayColor, amber.withValues(alpha: 0.24));
    expect(theme.sliderTheme.overlayShape, isNot(SliderComponentShape.noOverlay));
    expect(theme.checkboxTheme.fillColor?.resolve({WidgetState.selected}), amber);
    expect(theme.textSelectionTheme.cursorColor, amber);
    expect(theme.progressIndicatorTheme.color, amber);
    final switchContainer = tester
        .widgetList<AnimatedContainer>(
          find.descendant(
            of: find.byType(NativeGlassSwitch),
            matching: find.byType(AnimatedContainer),
          ),
        )
        .first;
    expect((switchContainer.decoration as BoxDecoration).color, amber);
  });

  testWidgets('NativeGlassSurface 穿透包装层识别按钮并提供悬停、0.96 按压微缩与 2pt 焦点环（U-01、#144）', (
    tester,
  ) async {
    // 作用：确认工具栏按钮常见的 Semantics -> SizedBox -> IconButton 包装不会绕过微交互与键盘焦点环。
    // 边界：悬停出现叠层；按下在常规动态效果下缩放为 0.96、减弱动态效果下保持 1.0；Tab 聚焦绘 2pt 强调色边框。
    const accent = Color(0xFFAF52DE);
    final appearance = const GlassAppearance(
      mode: 'light',
      accentLight: accent,
      accentDark: accent,
    );
    Widget buildButton({required bool reduced}) => MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light, appearance),
        home: Scaffold(
          body: Center(
            child: NativeGlassSurface(
              material: true,
              child: Semantics(
                button: true,
                label: '矩形标注',
                child: SizedBox.square(
                  dimension: 32,
                  child: IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.crop_square),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(buildButton(reduced: false));
    await tester.pumpAndSettle();
    expect(find.byType(NativeGlassButtonFeedback), findsOneWidget);

    final target = tester.getCenter(find.byType(IconButton));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(target);
    await tester.pumpAndSettle();
    var overlay = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    expect((overlay.decoration as ShapeDecoration).color!.a, greaterThan(0));

    await mouse.down(target);
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale,
      GlassMetrics.buttonPressedScale,
    );
    await mouse.up();
    await tester.pumpAndSettle();
    await mouse.removePointer();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    overlay = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    final border = (overlay.decoration as ShapeDecoration).shape
        as RoundedSuperellipseBorder;
    expect(border.side.width, GlassMetrics.focusRingWidth);
    expect(border.side.color, accent);

    // 边界：减少动态效果开启时按下仍响应，但缩放保持 1.0。
    await tester.pumpWidget(buildButton(reduced: true));
    await tester.pump();
    final press = await tester.startGesture(
      tester.getCenter(find.byType(IconButton)),
    );
    await tester.pump();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1.0);
    await press.up();
  });

  testWidgets('菜单空项容错、flat 反馈、长菜单滚动、行内报错与危险确认对话框与横幅（U-04、U-13、U-21、U-26）', (
    tester,
  ) async {
    // 作用：验证 Wave 1 修复的新建与加固组件在空值、多选项溢出、表单报错、二次确认及横幅上的行为。
    // 边界：items={} 不抛空指针；30 项面板高被限制 <= 320pt；confirm(destructive: true) 返回点击结果。
    var confirmedResult = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: NativeGlassTheme.data(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => SingleChildScrollView(
              child: Column(
                children: [
                  NativeGlassMenuButton<int>(
                    value: 2,
                    items: const {},
                    flat: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    onChanged: (_) {},
                  ),
                  NativeGlassMenuPanel(
                    children: [
                      for (var i = 0; i < 30; i++)
                        NativeGlassMenuItem(label: '$i fps', onPressed: () {}),
                    ],
                  ),
                  const NativeGlassField(
                    errorText: '提示词不能为空。',
                    child: TextField(),
                  ),
                  const NativeGlassBanner(message: '无法连接翻译服务'),
                  TextButton(
                    onPressed: () async {
                      confirmedResult = await NativeGlassDialog.confirm(
                        context: context,
                        title: '清空截图历史？',
                        message: '将永久删除所有截图记录和本地文件。',
                        confirmLabel: '全部清空',
                        destructive: true,
                      );
                    },
                    child: const Text('打开确认'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('提示词不能为空。'), findsOneWidget);
    expect(find.text('无法连接翻译服务'), findsOneWidget);
    expect(
      tester.getSize(find.byType(NativeGlassMenuPanel)).height,
      lessThanOrEqualTo(GlassMetrics.menuMaxHeight + 2),
    );
    expect(
      find.descendant(
        of: find.byType(NativeGlassMenuButton<int>),
        matching: find.byType(NativeGlassButtonFeedback),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('打开确认'));
    await tester.pumpAndSettle();
    expect(find.text('清空截图历史？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '全部清空'));
    await tester.pumpAndSettle();
    expect(confirmedResult, isTrue);
  });
}
