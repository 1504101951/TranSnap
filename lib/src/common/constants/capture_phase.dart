enum CapturePhase {
  idle,
  preparing,
  recording,
  pausing,
  paused,
  finalizing,
  videoReady,
  scrolling,
  imageReady,
  converting,
  failed;

  static CapturePhase parse(String wire) => values.byName(wire);
}

enum RecordingExport {
  mp4,
  gif,
  apng,
  webm;

  static RecordingExport parse(String wire) => values.byName(wire);
}
