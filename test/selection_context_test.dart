import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/selection_gesture_types.dart';
import 'package:transnap/src/selection/selection_context.dart';

const text = SelectionContextKinds.text;
const nonText = SelectionContextKinds.nonText;
const web = SelectionContextKinds.web;
const other = SelectionContextKinds.other;

void main() {
  test('不允许复制或上下文含非文本时从不复制；文本读不到、网页内容或行内列表符号时复制兜底', () {
    for (final context in [
      [other, other],
      [web],
      [text],
      <String>[],
    ]) {
      for (final value in [null, 'Selected']) {
        expect(
          SelectionContext.shouldCopy(
            context: context,
            text: value,
            allowCopy: false,
          ),
          isFalse,
        );
      }
    }
    for (final context in [
      [other, nonText, nonText],
      [nonText, nonText],
      [nonText],
    ]) {
      for (final value in [null, 'Selected']) {
        expect(
          SelectionContext.shouldCopy(
            context: context,
            text: value,
            allowCopy: true,
          ),
          isFalse,
        );
      }
    }
    for (final context in [
      [text],
      [other, web],
      [other, other],
    ]) {
      expect(
        SelectionContext.shouldCopy(
          context: context,
          text: null,
          allowCopy: true,
        ),
        isTrue,
      );
      expect(
        SelectionContext.shouldCopy(
          context: context,
          text: ' \n',
          allowCopy: true,
        ),
        isTrue,
      );
    }
    expect(
      SelectionContext.shouldCopy(
        context: [other, web],
        text: 'Selected',
        allowCopy: true,
      ),
      isTrue,
    );
    expect(
      SelectionContext.shouldCopy(
        context: [text],
        text: 'Selected',
        allowCopy: true,
      ),
      isFalse,
    );
    expect(
      SelectionContext.shouldCopy(
        context: [other],
        text: 'First item.• Second item.',
        allowCopy: true,
      ),
      isTrue,
    );
    expect(
      SelectionContext.shouldCopy(
        context: [other],
        text: '• First item.\n  • Second item.',
        allowCopy: true,
      ),
      isFalse,
    );
  });

  test('复制结果与读到的文本去掉空白、不可见字符与列表符号后相同，或较短一方是不短于一半的有序子序列时视为同一选区', () {
    expect(
      SelectionContext.matchesCopiedSelection(
        '• First item.• Second item.',
        'First item.\nSecond item.',
      ),
      isTrue,
    );
    expect(
      SelectionContext.matchesCopiedSelection(
        'Paragraph one​Paragraph two',
        'Paragraph one\n\nParagraph two',
      ),
      isTrue,
    );
    expect(
      SelectionContext.matchesCopiedSelection(
        '• First item.',
        'Unrelated clipboard text',
      ),
      isFalse,
    );
    expect(SelectionContext.matchesCopiedSelection('•', ''), isFalse);
    expect(
      SelectionContext.matchesCopiedSelection(
        'Adding tests.已运行 1 个命令已运行 1 个命令The three new tests pass.',
        'Adding tests.\n已运行 1 个命令\nThe three new tests pass.',
      ),
      isTrue,
    );
    expect(
      SelectionContext.matchesCopiedSelection(
        'Adding tests for batching, ordering, and failure in the provider.',
        'Adding tests.',
      ),
      isFalse,
    );
    expect(
      SelectionContext.matchesCopiedSelection('Adding tests.', 'Tests adding.'),
      isFalse,
    );
  });

  test('采用复制结果：空白结果不采用，网页内容或没有读到文本时直接采用，否则要求与读到的文本相符', () {
    expect(
      SelectionContext.acceptsCopied(
        context: [other, other, web],
        text: 'Done.已运行 1 个命令已运行 1 个命令Next step.',
        copied: 'Done.\nRan 1 command\nNext step.',
      ),
      isTrue,
    );
    expect(
      SelectionContext.acceptsCopied(
        context: [other, web],
        text: 'Done.',
        copied: ' \n　',
      ),
      isFalse,
    );
    expect(
      SelectionContext.acceptsCopied(
        context: [text],
        text: null,
        copied: 'Line one\nLine two',
      ),
      isTrue,
    );
    expect(
      SelectionContext.acceptsCopied(
        context: [text],
        text: '• First item.',
        copied: 'Unrelated clipboard text',
      ),
      isFalse,
    );
  });

  test('原生请求按方法名分发到对应规则，未知方法报错', () {
    expect(
      handleSelectionContextRequest(
        const MethodCall(MethodNames.shouldCopySelection, {
          'context': [web],
          'text': 'Selected',
          'allowCopy': true,
        }),
      ),
      isTrue,
    );
    expect(
      handleSelectionContextRequest(
        const MethodCall(MethodNames.acceptsCopiedSelection, {
          'context': [text],
          'text': null,
          'allowCopy': true,
          'copied': 'Copied',
        }),
      ),
      isTrue,
    );
    expect(
      () => handleSelectionContextRequest(
        const MethodCall('unknown', {'context': [], 'text': null}),
      ),
      throwsA(isA<MissingPluginException>()),
    );
  });
}
