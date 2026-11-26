import 'dart:math' as math;

import '../common/constants/screenshot_actions.dart';
import '../common/constants/toolbar_grid.dart';
import '../settings/screenshot_toolbar_preferences.dart';

typedef ToolbarCells = ({String key, List<String?> cells, int? modifiers});

typedef ToolbarLine = ({
  List<ToolbarCells> groups,
  String? strip,
  String? anchor,
  double indent,
  double? caret,
});

typedef ToolbarStrip = ({int count, String anchor, Map<String, int> hosts});

typedef ToolbarTray = ({String parent, String kind, List<String> cells});

typedef ToolbarExtent = ({
  List<double> lengths,
  double grouped,
  double blocks,
  double thickness,
});

abstract final class ToolbarLayout {
  static const favoritesKey = 'screenshot-favorites-group';
  static const busyCell = 'screenshot-busy';
  static const statusKey = 'screenshot-status-group';
  static const gridPrefix = 'screenshot-grid-group-';
  static const childrenPrefix = 'screenshot-children-group-';
  static const attributesPrefix = 'screenshot-attributes-group-';
  static const closingPrefix = 'screenshot-closing-group-';

  static ToolbarCells favorites(ScreenshotToolbarPreferences toolbar) =>
      (key: favoritesKey, cells: <String?>[...toolbar.favorites], modifiers: 0);

  static List<ToolbarCells> grid(ScreenshotToolbarPreferences toolbar) => [
    for (final (index, column) in toolbar.columns.indexed)
      (
        key: '$gridPrefix$index',
        cells: [
          for (final id in column.slots)
            id == null || toolbar.hidden.contains(id) ? null : id,
        ],
        modifiers: column.modifiers,
      ),
  ];

  static List<ToolbarLine> lines({
    required ScreenshotToolbarPreferences toolbar,
    required bool expanded,
    required List<String> children,
    required List<String> attributes,
    required String anchor,
    required ToolbarTray? closing,
    required bool reveal,
    required bool busy,
    required String? busyId,
    required Map<String, ToolbarStrip> strips,
    required int perLine,
  }) {
    List<ToolbarLine> pair(List<ToolbarCells> groups, {String? anchor}) => [
      for (var start = 0; start < groups.length; start += perLine)
        (
          groups: groups.sublist(
            start,
            math.min(start + perLine, groups.length),
          ),
          strip: null,
          anchor: anchor,
          indent: 0.0,
          caret: null,
        ),
    ];
    List<List<String>> chunk(List<String> ids) => [
      for (var start = 0; start < ids.length; start += ToolbarGrid.slots)
        ids.sublist(start, math.min(start + ToolbarGrid.slots, ids.length)),
    ];
    final inserted = <ToolbarCells>[
      for (final (index, cells) in chunk(children).indexed)
        (
          key: '$childrenPrefix$index',
          cells: <String?>[...cells],
          modifiers: null,
        ),
      for (final (index, cells) in chunk(attributes).indexed)
        (
          key: '$attributesPrefix$index',
          cells: <String?>[...cells],
          modifiers: null,
        ),
    ];
    final groups = <ToolbarCells>[];
    int? anchorGroup;
    int? closingGroup;
    for (final source in [favorites(toolbar), if (expanded) ...grid(toolbar)]) {
      if (source.key != favoritesKey &&
          source.cells.every((id) => id == null)) {
        continue;
      }
      if (anchorGroup == null && source.cells.contains(anchor)) {
        anchorGroup = groups.length;
      }
      if (closing != null &&
          closingGroup == null &&
          source.cells.contains(closing.parent)) {
        closingGroup = groups.length;
      }
      groups.add(source);
    }
    final shown = {
      for (final group in [...groups, ...inserted]) ...group.cells,
    };
    final status = [
      if (reveal) ScreenshotActions.reveal,
      if (busy && !shown.contains(busyId)) busyCell,
    ];
    if (status.isNotEmpty) {
      groups.add((key: statusKey, cells: status, modifiers: null));
    }
    final lines = pair(groups);
    final extra = <int, List<ToolbarLine>>{};
    final leaving = [
      for (final id in closing?.cells ?? const <String>[])
        if (!shown.contains(id)) id,
    ];
    if (closing != null && leaving.isNotEmpty) {
      final at = closingGroup == null
          ? lines.length
          : closingGroup ~/ perLine + 1;
      (extra[at] ??= []).addAll(
        pair([
          for (final (index, cells) in chunk(leaving).indexed)
            (
              key: '$closingPrefix$index',
              cells: <String?>[...cells],
              modifiers: null,
            ),
        ], anchor: closing.parent),
      );
    }
    final after = anchorGroup == null
        ? lines.length
        : anchorGroup ~/ perLine + 1;
    (extra[after] ??= []).addAll([
      ...pair(inserted, anchor: anchor),
      for (final MapEntry(:key, :value) in strips.entries)
        (
          groups: const <ToolbarCells>[],
          strip: key,
          anchor: value.anchor,
          indent: 0.0,
          caret: null,
        ),
    ]);
    return _placeTrays([
      for (var index = 0; index <= lines.length; index++) ...[
        ...?extra[index],
        if (index < lines.length) lines[index],
      ],
    ], strips);
  }

  static List<ToolbarLine> _placeTrays(
    List<ToolbarLine> lines,
    Map<String, ToolbarStrip> strips,
  ) {
    final centers = <String, double>{};
    void record(ToolbarLine line) {
      if (line.strip != null) {
        const step = ToolbarGrid.trayButton + 4;
        for (final MapEntry(:key, :value)
            in strips[line.strip]!.hosts.entries) {
          centers[key] =
              line.indent +
              ToolbarGrid.trayPadding +
              value * step +
              ToolbarGrid.trayButton / 2;
        }
        return;
      }
      final tray = isTray(line);
      var start = tray ? line.indent + ToolbarGrid.trayPadding : 0.0;
      for (final group in line.groups) {
        final step = tray ? ToolbarGrid.trayButton + 4 : 36.0;
        final head = tray ? 0.0 : ToolbarGrid.blockPadding + _hintRun(group);
        for (final (slot, id) in group.cells.indexed) {
          if (id == null) continue;
          centers[id] = start + head + slot * step + step / 2 - 2;
        }
        start += tray
            ? _trayRun(group.cells.length) +
                  ToolbarGrid.traySeparatorGap * 2 +
                  1
            : _blockLength(group) + ToolbarGrid.blockGap;
      }
    }

    ToolbarLine hang(ToolbarLine line, double limit) {
      const first = ToolbarGrid.trayPadding + ToolbarGrid.trayButton / 2;
      final center = centers[line.anchor];
      final bare = lineLength(line, strips);
      final indent = center == null
          ? 0.0
          : math.min(
              math.max(0.0, center - first),
              math.max(0.0, limit - bare),
            );
      return (
        groups: line.groups,
        strip: line.strip,
        anchor: line.anchor,
        indent: indent,
        caret: center == null ? first : center - indent,
      );
    }

    final placed = <ToolbarLine>[];
    for (final line in lines) {
      final next = isTray(line) ? hang(line, double.infinity) : line;
      if (next.strip == null) record(next);
      placed.add(next);
    }
    final widest = [
      0.0,
      for (final line in placed)
        if (line.strip == null) lineLength(line, strips),
    ].reduce(math.max);
    for (final (index, line) in placed.indexed) {
      if (line.strip == null) continue;
      placed[index] = hang(line, widest);
      record(placed[index]);
    }
    return placed;
  }

  static double _cellsLength(int count) =>
      count * 32.0 + math.max(0, count - 1) * 4;

  static double _trayRun(int count) =>
      count * ToolbarGrid.trayButton + math.max(0, count - 1) * 4;

  static double _hintRun(ToolbarCells group) =>
      group.modifiers == null ? 0 : ToolbarGrid.hintExtent + 4;

  static double _blockLength(ToolbarCells group) =>
      ToolbarGrid.blockPadding * 2 +
      _hintRun(group) +
      _cellsLength(group.cells.length);

  static bool isTray(ToolbarLine line) =>
      line.groups.isNotEmpty &&
      line.groups.first.modifiers == null &&
      line.groups.first.key != statusKey;

  static double lineLength(ToolbarLine line, Map<String, ToolbarStrip> strips) {
    if (line.strip != null) {
      return line.indent +
          ToolbarGrid.trayPadding * 2 +
          _trayRun(strips[line.strip]!.count);
    }
    if (isTray(line)) {
      return line.indent +
          ToolbarGrid.trayPadding * 2 +
          line.groups.fold(
            0.0,
            (sum, group) => sum + _trayRun(group.cells.length),
          ) +
          (line.groups.length - 1) * (ToolbarGrid.traySeparatorGap * 2 + 1);
    }
    return line.groups.fold(0.0, (sum, group) => sum + _blockLength(group)) +
        (line.groups.length - 1) * ToolbarGrid.blockGap;
  }

  static double lineThickness(ToolbarLine line) =>
      line.strip != null || isTray(line)
      ? ToolbarGrid.trayThickness
      : ToolbarGrid.blockThickness;

  static ToolbarExtent extent(
    List<ToolbarLine> lines,
    Map<String, ToolbarStrip> strips,
  ) => (
    lengths: [for (final line in lines) lineLength(line, strips)],
    grouped: [
      0.0,
      for (final line in lines)
        if (line.strip == null) lineLength(line, strips),
    ].reduce(math.max),
    blocks: [
      0.0,
      for (final line in lines)
        if (line.strip == null && !isTray(line)) lineLength(line, strips),
    ].reduce(math.max),
    thickness:
        lines.fold(0.0, (sum, line) => sum + lineThickness(line)) +
        math.max(0, lines.length - 1) * ToolbarGrid.lineGap,
  );
}
