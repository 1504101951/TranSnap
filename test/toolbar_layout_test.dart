import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/screenshot_actions.dart';
import 'package:transnap/src/common/constants/toolbar_grid.dart';
import 'package:transnap/src/screenshot/toolbar_layout.dart';
import 'package:transnap/src/settings/screenshot_toolbar_preferences.dart';

void main() {
  final toolbar = ScreenshotToolbarPreferences(
    favorites: [ScreenshotActions.crop, ScreenshotActions.rect],
    columns: [
      ToolbarColumn(ToolbarGrid.defaultModifiers[0], [
        ScreenshotActions.arrow,
        ...List<String?>.filled(ToolbarGrid.slots - 1, null),
      ]),
      ToolbarColumn(
        ToolbarGrid.defaultModifiers[1],
        List<String?>.filled(ToolbarGrid.slots, null),
      ),
    ],
  );

  List<ToolbarLine> lines({
    bool expanded = false,
    List<String> children = const [],
    String anchor = ScreenshotActions.crop,
    bool busy = false,
    String? busyId,
  }) => ToolbarLayout.lines(
    toolbar: toolbar,
    expanded: expanded,
    children: children,
    attributes: const [],
    anchor: anchor,
    closing: null,
    reveal: false,
    busy: busy,
    busyId: busyId,
    strips: const {},
    perLine: 4,
  );

  test('收起时只有常用块；展开后接非空分组，全空分组不占位', () {
    expect(lines().single.groups.map((group) => group.key), [
      ToolbarLayout.favoritesKey,
    ]);
    expect(lines(expanded: true).single.groups.map((group) => group.key), [
      ToolbarLayout.favoritesKey,
      '${ToolbarLayout.gridPrefix}0',
    ]);
  });

  test('子级托盘插在锚点所在行之后，缩进使三角对准锚点按钮中心（常用第 2 格中心 84pt）', () {
    final placed = lines(
      expanded: true,
      children: [ScreenshotActions.scrolling, ScreenshotActions.eyedropper],
      anchor: ScreenshotActions.rect,
    );
    expect(placed, hasLength(2));
    final tray = placed[1];
    expect(tray.groups.single.cells, [
      ScreenshotActions.scrolling,
      ScreenshotActions.eyedropper,
    ]);
    expect(tray.indent, 68);
    expect(tray.caret, 16);
    expect(
      ToolbarLayout.extent(placed, const {}).thickness,
      ToolbarGrid.blockThickness +
          ToolbarGrid.trayThickness +
          ToolbarGrid.lineGap,
    );
  });

  test('忙碌的动作不在当前格子里时追加状态组显示忙碌环，已显示时不追加', () {
    final status = lines(
      busy: true,
      busyId: ScreenshotActions.save,
    ).single.groups.last;
    expect(status.key, ToolbarLayout.statusKey);
    expect(status.cells, [ToolbarLayout.busyCell]);
    expect(
      lines(
        busy: true,
        busyId: ScreenshotActions.crop,
      ).single.groups.map((group) => group.key),
      [ToolbarLayout.favoritesKey],
    );
  });
}
