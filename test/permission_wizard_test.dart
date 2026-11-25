import 'package:flutter_test/flutter_test.dart';
import 'package:transnap/src/common/utils/permission_utils.dart';

void main() {
  test('只有两项权限均授权才允许进入应用', () {
    expect(
      canEnterApp(accessibilityGranted: false, screenRecordingGranted: false),
      isFalse,
    );
    expect(
      canEnterApp(accessibilityGranted: true, screenRecordingGranted: false),
      isFalse,
    );
    expect(
      canEnterApp(accessibilityGranted: false, screenRecordingGranted: true),
      isFalse,
    );
    expect(
      canEnterApp(accessibilityGranted: true, screenRecordingGranted: true),
      isTrue,
    );
  });
}
