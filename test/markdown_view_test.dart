import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/screenshot/markdown_view.dart';

void main() {
  test('按原生 OCR 生成的格式拆分标题、段落、列表与表格，未知内容按段落保留', () {
    final blocks = parseMarkdownBlocks(
      '# Report\n\nIntro line\nsecond line\n\nNext paragraph\n\n- first\n- second\n\n'
      '| Name | Value |\n| --- | --- |\n| a\\|b | 1 |\n| short |\n\n#not heading',
    );
    expect(blocks.map((b) => b.runtimeType), [
      MarkdownHeading,
      MarkdownParagraph,
      MarkdownParagraph,
      MarkdownList,
      MarkdownTable,
      MarkdownParagraph,
    ]);
    expect((blocks[0] as MarkdownHeading).text, 'Report');
    expect((blocks[1] as MarkdownParagraph).text, 'Intro line\nsecond line');
    expect((blocks[3] as MarkdownList).items, ['first', 'second']);
    expect((blocks[4] as MarkdownTable).rows, [
      ['Name', 'Value'],
      ['a|b', '1'],
      ['short', ''],
    ]);
    expect((blocks[5] as MarkdownParagraph).text, '#not heading');
  });

  test('块间距：标题之后与相邻段落之间为 8，其他为 12', () {
    const heading = MarkdownHeading('T');
    const paragraph = MarkdownParagraph('p');
    const list = MarkdownList(['a']);
    expect(MarkdownView.gap(heading, paragraph), 8);
    expect(MarkdownView.gap(paragraph, paragraph), 8);
    expect(MarkdownView.gap(paragraph, list), 12);
    expect(MarkdownView.gap(list, paragraph), 12);
  });

  testWidgets('渲染时不显示 Markdown 符号，表头加粗，宽表格在表格内横向滚动且文字完整', (tester) async {
    const wide =
        'a very long cell value that is much wider than the panel body width';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            child: SingleChildScrollView(
              child: MarkdownView(
                source:
                    '# Title\n\n- item\n\n| H1 | H2 |\n| --- | --- |\n| $wide | x |',
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('Title'), findsOneWidget);
    expect(find.textContaining('#'), findsNothing);
    expect(find.text('•'), findsOneWidget);
    expect(find.text('item'), findsOneWidget);
    expect(find.textContaining('---'), findsNothing);
    expect(
      tester.widget<Text>(find.text('H1')).style?.fontWeight,
      FontWeight.w600,
    );
    expect(
      tester.widget<Text>(find.text(wide)).style?.fontWeight,
      isNot(FontWeight.w600),
    );

    final horizontal = find.byWidgetPredicate(
      (w) => w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
    );
    expect(horizontal, findsOneWidget);
    expect(tester.getSize(find.text(wide)).width, greaterThan(240));
  });
}
