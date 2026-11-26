import 'package:flutter/material.dart';

import '../common/constants/glass_metrics.dart';
import '../common/widgets/native_glass.dart';

sealed class MarkdownBlock {
  const MarkdownBlock();
}

class MarkdownHeading extends MarkdownBlock {
  const MarkdownHeading(this.text);
  final String text;
}

class MarkdownParagraph extends MarkdownBlock {
  const MarkdownParagraph(this.text);
  final String text;
}

class MarkdownList extends MarkdownBlock {
  const MarkdownList(this.items);
  final List<String> items;
}

class MarkdownTable extends MarkdownBlock {
  const MarkdownTable(this.rows);
  final List<List<String>> rows;
}

List<MarkdownBlock> parseMarkdownBlocks(String source) {
  final blocks = <MarkdownBlock>[];
  final paragraph = <String>[];
  final list = <String>[];
  final table = <String>[];

  void flush() {
    if (paragraph.isNotEmpty) {
      blocks.add(MarkdownParagraph(paragraph.join('\n')));
    }
    if (list.isNotEmpty) blocks.add(MarkdownList(List.of(list)));
    if (table.isNotEmpty) blocks.add(MarkdownTable(_tableRows(table)));
    paragraph.clear();
    list.clear();
    table.clear();
  }

  for (final raw in source.split('\n')) {
    final line = raw.trimRight();
    if (line.trim().isEmpty) {
      flush();
    } else if (line.startsWith('# ')) {
      flush();
      blocks.add(MarkdownHeading(line.substring(2).trim()));
    } else if (line.startsWith('- ')) {
      if (list.isEmpty) flush();
      list.add(line.substring(2).trim());
    } else if (line.startsWith('|')) {
      if (table.isEmpty) flush();
      table.add(line);
    } else {
      if (paragraph.isEmpty) flush();
      paragraph.add(line);
    }
  }
  flush();
  return blocks;
}

List<List<String>> _tableRows(List<String> lines) {
  final separator = RegExp(r'^:?-{3,}:?$');
  final rows = <List<String>>[];
  for (final line in lines) {
    final cells = _tableCells(line);
    if (cells.isNotEmpty && cells.every(separator.hasMatch)) continue;
    rows.add(cells);
  }
  final columns = rows.fold(
    0,
    (max, row) => row.length > max ? row.length : max,
  );
  return [
    for (final row in rows) [...row, ...List.filled(columns - row.length, '')],
  ];
}

List<String> _tableCells(String line) {
  final cells = <String>[];
  final cell = StringBuffer();
  for (var index = 0; index < line.length; index++) {
    final char = line[index];
    if (char == r'\' && index + 1 < line.length && line[index + 1] == '|') {
      cell.write('|');
      index++;
    } else if (char == '|') {
      cells.add(cell.toString().trim());
      cell.clear();
    } else {
      cell.write(char);
    }
  }
  cells.add(cell.toString().trim());
  if (cells.isNotEmpty && cells.first.isEmpty) cells.removeAt(0);
  if (cells.isNotEmpty &&
      cells.last.isEmpty &&
      line.trimRight().endsWith('|')) {
    cells.removeLast();
  }
  return cells;
}

class MarkdownView extends StatelessWidget {
  const MarkdownView({super.key, required this.source});

  final String source;

  static (String, List<MarkdownBlock>)? _parsed;

  static double gap(MarkdownBlock previous, MarkdownBlock next) {
    if (previous is MarkdownHeading) return 8;
    if (previous is MarkdownParagraph && next is MarkdownParagraph) return 8;
    return 12;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final body = GlassFonts.resolve(context).body.copyWith(
      fontSize: GlassMetrics.bodyFont,
      height: GlassMetrics.bodyLine / GlassMetrics.bodyFont,
      color: colors.onSurface,
    );
    if (_parsed?.$1 != source) _parsed = (source, parseMarkdownBlocks(source));
    final blocks = _parsed!.$2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, block) in blocks.indexed) ...[
          if (index > 0) SizedBox(height: gap(blocks[index - 1], block)),
          _block(block, body, colors),
        ],
      ],
    );
  }

  Widget _block(MarkdownBlock block, TextStyle body, ColorScheme colors) =>
      switch (block) {
        MarkdownHeading(:final text) => Text(
          text,
          style: body.copyWith(
            fontSize: 15,
            height: 22 / 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        MarkdownParagraph(:final text) => Text(text, style: body),
        MarkdownList(:final items) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, item) in items.indexed)
              Padding(
                padding: EdgeInsets.only(top: index == 0 ? 0 : 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('•', style: body),
                    const SizedBox(width: 6),
                    Expanded(child: Text(item, style: body)),
                  ],
                ),
              ),
          ],
        ),
        MarkdownTable(:final rows) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            border: TableBorder.all(color: colors.outlineVariant, width: 1),
            defaultColumnWidth: const IntrinsicColumnWidth(),
            children: [
              for (final (index, row) in rows.indexed)
                TableRow(
                  children: [
                    for (final cell in row)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Text(
                          cell,
                          style: index == 0
                              ? body.copyWith(fontWeight: FontWeight.w600)
                              : body,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      };
}
