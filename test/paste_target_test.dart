import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/constants/method_names.dart';
import 'package:transnap/src/common/constants/selection_gesture_types.dart';
import 'package:transnap/src/selection/paste_target.dart';

void main() {
  String decide({
    bool hasFocus = true,
    bool focusIsSelection = false,
    bool focusIsTextInput = false,
    bool focusIsSecure = false,
    int? candidates,
  }) => PasteTarget.decide(
    hasFocus: hasFocus,
    focusIsSelection: focusIsSelection,
    focusIsTextInput: focusIsTextInput,
    focusIsSecure: focusIsSecure,
    candidates: candidates,
  );

  test('没有焦点、焦点即持有选区的节点、或焦点为非密码框文本输入控件时直接粘贴', () {
    expect(decide(hasFocus: false), PasteTargetActions.paste);
    expect(decide(focusIsSelection: true), PasteTargetActions.paste);
    expect(
      decide(focusIsSelection: true, focusIsSecure: true),
      PasteTargetActions.paste,
    );
    expect(decide(focusIsTextInput: true), PasteTargetActions.paste);
  });

  test('焦点为密码框或非文本控件时先查找；可写输入框恰好一个时设焦点后粘贴，0 个或多个时不粘贴', () {
    expect(
      decide(focusIsTextInput: true, focusIsSecure: true),
      PasteTargetActions.search,
    );
    expect(decide(), PasteTargetActions.search);
    expect(decide(candidates: 1), PasteTargetActions.focusCandidate);
    expect(decide(candidates: 0), PasteTargetActions.none);
    expect(decide(candidates: 2), PasteTargetActions.none);
  });

  test('原生请求的焦点事实与候选数量按同一规则判定', () {
    expect(
      PasteTarget.handle(
        const MethodCall(MethodNames.pasteTarget, {
          'hasFocus': true,
          'focusIsSelection': false,
          'focusIsTextInput': false,
          'focusIsSecure': false,
          'candidates': 1,
        }),
      ),
      PasteTargetActions.focusCandidate,
    );
  });
}
