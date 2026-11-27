#ifndef RUNNER_PROTOCOL_H_
#define RUNNER_PROTOCOL_H_

namespace protocol {

inline constexpr char kPlatformChannel[] = "transnap/platform";
inline constexpr char kPlatformEventsChannel[] = "transnap/platform/events";
inline constexpr char kAppearanceChannel[] = "transnap/appearance";

inline constexpr char kCapabilities[] = "capabilities";
inline constexpr char kLoadSettings[] = "loadSettings";
inline constexpr char kApplySettings[] = "applySettings";
inline constexpr char kApplicationSupportPath[] = "applicationSupportPath";
inline constexpr char kReadCredentials[] = "readCredentials";
inline constexpr char kCredentialIds[] = "credentialIds";
inline constexpr char kPublishFontState[] = "publishFontState";
inline constexpr char kAppReady[] = "appReady";
inline constexpr char kPerfMark[] = "perfMark";
inline constexpr char kAppStartFailed[] = "appStartFailed";
inline constexpr char kGetAppearance[] = "getAppearance";
inline constexpr char kAppearanceChanged[] = "appearanceChanged";
inline constexpr char kToggleAutomatic[] = "toggleAutomatic";
inline constexpr char kPreviewAppearance[] = "previewAppearance";
inline constexpr char kSystemStatus[] = "systemStatus";
inline constexpr char kLanguageCandidates[] = "languageCandidates";
inline constexpr char kToggleSpeech[] = "toggleSpeech";
inline constexpr char kStopSpeech[] = "stopSpeech";
inline constexpr char kDetectFailedError[] = "detect_failed";
inline constexpr char kHistoryChanged[] = "historyChanged";
inline constexpr char kRefreshSettings[] = "refreshSettings";
inline constexpr char kWindowStartupChannel[] = "transnap/window_startup";
inline constexpr char kSettingsChannel[] = "transnap/settings";
inline constexpr char kWindowReady[] = "windowReady";
inline constexpr char kSetWindowTitle[] = "setWindowTitle";
inline constexpr char kStartWindowDrag[] = "startWindowDrag";
inline constexpr char kSettingsEntrypoint[] = "settingsMain";
inline constexpr char kHistoryEntrypoint[] = "historyMain";

inline constexpr char kBadArgsError[] = "bad_args";
inline constexpr char kBadSettingsError[] = "bad_settings";
inline constexpr char kSettingsFailedError[] = "settings_failed";
inline constexpr char kRollbackFailedError[] = "rollback_failed";
inline constexpr char kCredentialsFailedError[] = "keychain_failed";

inline constexpr char kSystemLanguageKey[] = "systemLanguage";
inline constexpr char kAutomaticKey[] = "automatic";
inline constexpr char kLoginNeedsApprovalKey[] = "loginNeedsApproval";
inline constexpr char kLaunchAtLoginKey[] = "launchAtLogin";
inline constexpr char kGlassAppearanceKey[] = "glassAppearance";
inline constexpr char kGlassOpacityKey[] = "glassOpacity";
inline constexpr char kAccentColorKey[] = "accentColor";
inline constexpr char kAccentForegroundKey[] = "accentForeground";
inline constexpr char kAccentLightKey[] = "accentLight";
inline constexpr char kAccentDarkKey[] = "accentDark";
inline constexpr char kFontSetKey[] = "fontSet";
inline constexpr char kFontsDirectoryKey[] = "fontsDirectory";
inline constexpr char kFontStateKey[] = "fontState";
inline constexpr char kGlassMaterialKey[] = "glassMaterial";

inline constexpr char kGlassMaterialAcrylic[] = "acrylic";
inline constexpr char kGlassMaterialOpaque[] = "opaque";
inline constexpr unsigned long kAcrylicMinimumBuild = 22621;

inline constexpr char kAppearanceSystem[] = "system";
inline constexpr char kAccentForegroundAuto[] = "auto";
inline constexpr char kFontSetFallback[] = "neutral";
inline constexpr double kGlassOpacityFallback = 0.8;
inline constexpr double kAccentCustomDarkLift = 0.35;

inline constexpr wchar_t kDataDirectoryName[] = L"TranSnap";
inline constexpr wchar_t kPreferencesFile[] = L"preferences.json";
inline constexpr wchar_t kFontsDirectoryName[] = L"Fonts";
inline constexpr wchar_t kCredentialTargetPrefix[] = L"TranSnap/credentials/";
inline constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
inline constexpr wchar_t kRunValue[] = L"TranSnap";

}

#endif
