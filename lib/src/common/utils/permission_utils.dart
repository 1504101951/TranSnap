bool canEnterApp({
  required bool accessibilityGranted,
  required bool screenRecordingGranted,
}) {
  return accessibilityGranted && screenRecordingGranted;
}
