import 'text_mode.dart';

abstract final class PreferenceKeys {
  static const screenshotDrawing = 'screenshotDrawing';
  static const screenshotToolbarHidden = 'screenshotToolbarHidden';

  static const screenshotToolbarColumns = 'screenshotToolbarColumns';

  static const screenshotToolbarChildren = 'screenshotToolbarChildren';

  static const automatic = 'automatic';

  static const defaultServiceId = 'defaultServiceId';

  static const excludedApps = 'excludedApps';

  static const screenshotIncludesCursor = 'screenshotIncludesCursor';

  static const recordingClickEffect = 'recordingClickEffect';
  static const recordingClickRightDistinct = 'recordingClickRightDistinct';

  static const recordingDelay = 'recordingDelay';

  static const scrollCaptureMode = 'scrollCaptureMode';

  static const screenshotConfirmAction = 'screenshotConfirmAction';

  static const stickers = 'stickers';
  static const stickerDirectory = 'stickerDirectory';

  static const glossary = 'glossary';

  static const glassAppearance = 'glassAppearance';

  static const glassOpacity = 'glassOpacity';

  static const accentColor = 'accentColor';

  static const accentForeground = 'accentForeground';

  static const launchAtLogin = 'launchAtLogin';

  static const primaryLanguage = 'primaryLanguage';

  static const prompts = {
    TextMode.translate: 'translatePrompt',
    TextMode.polish: 'polishPrompt',
    TextMode.correct: 'correctPrompt',
    TextMode.explain: 'explainPrompt',
  };

  static const thinking = {
    TextMode.translate: 'translateThinking',
    TextMode.polish: 'polishThinking',
    TextMode.correct: 'correctThinking',
    TextMode.explain: 'explainThinking',
  };

  static const screenshotSaveDirectory = 'screenshotSaveDirectory';

  static const gifFramesPerSecond = 'gifFramesPerSecond';

  static const liveRecording = 'liveRecording';

  static const mcpEnabled = 'mcpEnabled';

  static const mcpControlEnabled = 'mcpControlEnabled';

  static const gifMaximumWidth = 'gifMaximumWidth';

  static const screenshotShortcutKeyCode = 'screenshotShortcutKeyCode';

  static const screenshotShortcutLabel = 'screenshotShortcutLabel';

  static const screenshotShortcutModifiers = 'screenshotShortcutModifiers';

  static const secondaryLanguage = 'secondaryLanguage';

  static const inputPrimaryLanguage = 'inputPrimaryLanguage';
  static const inputSecondaryLanguage = 'inputSecondaryLanguage';

  static const services = 'services';

  static const shortcutKeyCode = 'shortcutKeyCode';

  static const shortcutLabel = 'shortcutLabel';

  static const shortcutModifiers = 'shortcutModifiers';

  static const inputShortcutKeyCode = 'inputShortcutKeyCode';

  static const inputShortcutLabel = 'inputShortcutLabel';

  static const inputShortcutModifiers = 'inputShortcutModifiers';
}
