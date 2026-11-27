#include "platform_bridge.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <cwctype>
#include <map>
#include <optional>
#include <system_error>
#include <utility>
#include <vector>

#include "credentials.h"
#include "file_dialogs.h"
#include "language_detection.h"
#include "preferences_store.h"
#include "protocol.h"
#include "text_file.h"
#include "utils.h"
#include "windows_system.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

const std::map<std::string, std::pair<int64_t, int64_t>>& AccentSwatches() {
  static const std::map<std::string, std::pair<int64_t, int64_t>> swatches{
      {"blue", {0xFF2F6FE4, 0xFF4C8DFF}},
      {"purple", {0xFF6E56CF, 0xFF9B8AFB}},
      {"pink", {0xFFC9356E, 0xFFF06A97}},
      {"orange", {0xFFC2560F, 0xFFFF8F4D}},
      {"green", {0xFF0B7F72, 0xFF2EC4AE}},
      {"graphite", {0xFF57606C, 0xFFA3AAB4}},
  };
  return swatches;
}

std::optional<std::pair<int64_t, int64_t>> AccentPair(const std::string& mode) {
  auto swatch = AccentSwatches().find(mode);
  if (swatch != AccentSwatches().end()) {
    return swatch->second;
  }
  if (mode.size() != 7 || mode[0] != '#') {
    return std::nullopt;
  }
  char* end = nullptr;
  int64_t rgb = std::strtoll(mode.c_str() + 1, &end, 16);
  if (end != mode.c_str() + mode.size()) {
    return std::nullopt;
  }
  auto lift = [](int64_t channel) {
    return channel + static_cast<int64_t>(
                         std::llround(static_cast<double>(255 - channel) * protocol::kAccentCustomDarkLift));
  };
  int64_t dark = lift((rgb >> 16) & 0xFF) << 16 | lift((rgb >> 8) & 0xFF) << 8 |
                 lift(rgb & 0xFF);
  return std::make_pair(0xFF000000 | rgb, 0xFF000000 | dark);
}

const EncodableValue* Find(const EncodableMap& map, const char* key) {
  auto entry = map.find(EncodableValue(key));
  return entry == map.end() ? nullptr : &entry->second;
}

template <typename T>
std::optional<T> Get(const EncodableMap& map, const char* key) {
  const auto* value = Find(map, key);
  const auto* typed = value ? std::get_if<T>(value) : nullptr;
  return typed ? std::optional<T>(*typed) : std::nullopt;
}

std::optional<EncodableMap> StringMap(const EncodableValue& value) {
  const auto* map = std::get_if<EncodableMap>(&value);
  if (!map) {
    return std::nullopt;
  }
  for (const auto& [key, item] : *map) {
    if (!std::holds_alternative<std::string>(key) ||
        !std::holds_alternative<std::string>(item)) {
      return std::nullopt;
    }
  }
  return *map;
}

}

PlatformBridge::PlatformBridge(flutter::BinaryMessenger* messenger)
    : data_directory_(windows_system::DataDirectory()) {
  auto loaded = preferences_store::Load(
      data_directory_ / protocol::kPreferencesFile, preferences_error_);
  if (loaded) {
    preferences_ = std::move(*loaded);
  }
  const auto& codec = flutter::StandardMethodCodec::GetInstance();
  platform_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, protocol::kPlatformChannel, &codec);
  platform_->SetMethodCallHandler([this](const Call& call, Result result) {
    HandlePlatform(call, std::move(result));
  });
  appearance_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, protocol::kAppearanceChannel, &codec);
  appearance_->SetMethodCallHandler([this](const Call& call, Result result) {
    HandleAppearance(call, std::move(result));
  });
  events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
      messenger, protocol::kPlatformEventsChannel, &codec);
  events_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
          [this](const EncodableValue*,
                 std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            sink_ = std::move(sink);
            return nullptr;
          },
          [this](const EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
            sink_ = nullptr;
            return nullptr;
          }));
  capture_ = std::make_unique<SelectionCapture>(SelectionCapture::Delegate{
      [this](const char* method, EncodableValue arguments, SelectionMonitor::Reply reply) {
        RequestApplication(method, std::move(arguments), std::move(reply));
      },
      [this](const EncodableMap& event) { Emit(event); },
      [this]() { return Automatic(); },
      [this](const std::wstring& executable) { return Excluded(executable); },
  });
}

void PlatformBridge::RequestApplication(const char* method, EncodableValue arguments,
                                        SelectionMonitor::Reply reply) {
  auto shared = std::make_shared<SelectionMonitor::Reply>(std::move(reply));
  platform_->InvokeMethod(
      method, std::make_unique<EncodableValue>(std::move(arguments)),
      std::make_unique<flutter::MethodResultFunctions<EncodableValue>>(
          [shared](const EncodableValue* value) { (*shared)(value); },
          [shared](const std::string&, const std::string&, const EncodableValue*) {
            (*shared)(nullptr);
          },
          [shared]() { (*shared)(nullptr); }));
}

bool PlatformBridge::Excluded(const std::wstring& executable) const {
  const auto* excluded = Find(preferences_, protocol::kExcludedAppsKey);
  const auto* apps = excluded ? std::get_if<EncodableMap>(excluded) : nullptr;
  if (!apps || executable.empty()) {
    return false;
  }
  auto lower = [](std::wstring text) {
    std::transform(text.begin(), text.end(), text.begin(),
                   [](wchar_t character) { return static_cast<wchar_t>(std::towlower(character)); });
    return text;
  };
  std::wstring target = lower(executable);
  return std::any_of(apps->begin(), apps->end(), [&](const auto& entry) {
    const auto* id = std::get_if<std::string>(&entry.first);
    return id && lower(Utf16FromUtf8(*id)) == target;
  });
}

void PlatformBridge::Emit(const EncodableMap& event) {
  if (sink_) {
    sink_->Success(EncodableValue(event));
  }
}

bool PlatformBridge::Automatic() const {
  return Get<bool>(preferences_, protocol::kAutomaticKey).value_or(true);
}

void PlatformBridge::SetWindowRefreshHandlers(
    std::function<void()> settings_changed,
    std::function<void()> history_changed) {
  settings_changed_ = std::move(settings_changed);
  history_changed_ = std::move(history_changed);
}

void PlatformBridge::ToggleAutomatic() {
  platform_->InvokeMethod(
      protocol::kToggleAutomatic, nullptr,
      std::make_unique<flutter::MethodResultFunctions<EncodableValue>>(
          [this](const EncodableValue*) {
            if (settings_changed_) {
              settings_changed_();
            }
          },
          [](const std::string& code, const std::string& message,
             const EncodableValue*) {
            windows_system::ShowWarning("设置未保存", message.empty() ? code : message);
          },
          nullptr));
}

void PlatformBridge::HandlePlatform(const Call& call, Result result) {
  if (!HandleLocal(call, result)) {
    result->NotImplemented();
  }
}

void PlatformBridge::RouteWindowRequest(const Call& call, Result result) {
  if (HandleLocal(call, result)) {
    return;
  }
  std::shared_ptr<flutter::MethodResult<EncodableValue>> shared(std::move(result));
  platform_->InvokeMethod(
      call.method_name(),
      call.arguments() ? std::make_unique<EncodableValue>(*call.arguments())
                       : nullptr,
      std::make_unique<flutter::MethodResultFunctions<EncodableValue>>(
          [shared](const EncodableValue* value) {
            shared->Success(value ? *value : EncodableValue());
          },
          [shared](const std::string& code, const std::string& message,
                   const EncodableValue* details) {
            shared->Error(code, message, details ? *details : EncodableValue());
          },
          [shared]() { shared->NotImplemented(); }));
}

int PlatformBridge::AddAppearanceEngine(flutter::BinaryMessenger* messenger) {
  int token = next_appearance_token_++;
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, protocol::kAppearanceChannel,
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([this](const Call& call, Result result) {
    HandleAppearance(call, std::move(result));
  });
  window_appearance_[token] = std::move(channel);
  return token;
}

void PlatformBridge::RemoveAppearanceEngine(int token) {
  auto entry = window_appearance_.find(token);
  if (entry == window_appearance_.end()) {
    return;
  }
  entry->second->SetMethodCallHandler(nullptr);
  window_appearance_.erase(entry);
}

bool PlatformBridge::HandleLocal(const Call& call, Result& result) {
  const std::string& method = call.method_name();
  const auto* arguments = call.arguments()
                              ? std::get_if<EncodableMap>(call.arguments())
                              : nullptr;
  EncodableMap empty;
  const EncodableMap& args = arguments ? *arguments : empty;
  if (method == protocol::kCapabilities) {
    result->Success(EncodableValue(EncodableList{}));
  } else if (method == protocol::kLoadSettings) {
    if (!preferences_error_.empty()) {
      result->Error(protocol::kBadSettingsError, preferences_error_);
      return true;
    }
    result->Success(EncodableValue(LoadSettings()));
  } else if (method == protocol::kApplicationSupportPath) {
    std::error_code code;
    std::filesystem::create_directories(data_directory_, code);
    if (data_directory_.empty() || code) {
      result->Error(protocol::kSettingsFailedError, "无法创建应用数据目录。");
      return true;
    }
    result->Success(EncodableValue(Utf8FromUtf16(data_directory_.wstring().c_str())));
  } else if (method == protocol::kApplySettings) {
    ApplySettings(args, result);
  } else if (method == protocol::kReadCredentials) {
    ReadCredentials(args, result);
  } else if (method == protocol::kCredentialIds) {
    CredentialIds(args, result);
  } else if (method == protocol::kPublishFontState) {
    font_state_ = args;
    BroadcastAppearance();
    result->Success();
  } else if (method == protocol::kAppReady || method == protocol::kPerfMark) {
    result->Success();
  } else if (method == protocol::kAppStartFailed) {
    result->Success();
    windows_system::ShowStartFailure(
        Get<std::string>(args, "message").value_or(std::string()));
  } else if (method == protocol::kPreviewAppearance) {
    preview_ = args;
    BroadcastAppearance();
    result->Success();
  } else if (method == protocol::kLanguageCandidates) {
    auto text = Get<std::string>(args, "text");
    if (!text || !Get<EncodableMap>(args, "hints")) {
      result->Error(protocol::kBadArgsError, "缺少待识别文本或语言权重");
      return true;
    }
    std::string error;
    auto candidates = language_detection::Candidates(*text, error);
    if (!candidates) {
      result->Error(protocol::kDetectFailedError, error);
      return true;
    }
    result->Success(EncodableValue(*candidates));
  } else if (method == protocol::kToggleSpeech) {
    auto text = Get<std::string>(args, "text");
    auto language = Get<std::string>(args, "language");
    if (!text || !language) {
      result->Error(protocol::kBadArgsError, "toggleSpeech 需要 text/language");
      return true;
    }
    if (!speech_) {
      speech_ = std::make_unique<SpeechService>();
    }
    result->Success(EncodableValue(speech_->Toggle(*text, *language)));
  } else if (method == protocol::kStopSpeech) {
    if (speech_) {
      speech_->Stop();
    }
    result->Success();
  } else if (method == protocol::kRetainOverlay) {
    auto session = Get<std::string>(args, "sessionId");
    if (!session) {
      result->Error(protocol::kBadArgsError, "retainOverlay 需要 sessionId");
      return true;
    }
    capture_->Retain(*session);
    result->Success();
  } else if (method == protocol::kOpenGlossaryFile) {
    std::string error;
    auto file = file_dialogs::ChooseGlossaryFile(error);
    auto text = file ? text_file::ReadUtf8(*file, error) : std::nullopt;
    if (!error.empty()) {
      result->Error(protocol::kSettingsFailedError, error);
      return true;
    }
    if (!text) {
      result->Success();
      return true;
    }
    std::string format = Utf8FromUtf16(file->extension().wstring().c_str());
    format.erase(0, format.empty() ? 0 : 1);
    std::transform(format.begin(), format.end(), format.begin(),
                   [](unsigned char character) { return static_cast<char>(std::tolower(character)); });
    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("name"), EncodableValue(Utf8FromUtf16(file->filename().wstring().c_str()))},
        {EncodableValue("format"), EncodableValue(format)},
        {EncodableValue("text"), EncodableValue(*text)},
    }));
  } else if (method == protocol::kSaveTextFile) {
    auto text = Get<std::string>(args, "text");
    auto name = Get<std::string>(args, "suggestedName");
    if (!text || !name) {
      result->Error(protocol::kBadArgsError, "saveTextFile 需要 text/suggestedName");
      return true;
    }
    std::string error;
    auto file = file_dialogs::ChooseSaveLocation(*name, error);
    if (!error.empty()) {
      result->Error(protocol::kSaveFailedError, error);
      return true;
    }
    if (!file) {
      result->Success();
      return true;
    }
    if (!text_file::WriteAtomically(*file, *text)) {
      result->Error(protocol::kSaveFailedError, "无法写入文件：" + Utf8FromUtf16(file->wstring().c_str()));
      return true;
    }
    result->Success(EncodableValue(Utf8FromUtf16(file->wstring().c_str())));
  } else if (method == protocol::kHistoryChanged) {
    if (history_changed_) {
      history_changed_();
    }
    result->Success();
  } else if (method == protocol::kSystemStatus) {
    result->Success(EncodableValue(EncodableMap{
        {EncodableValue(protocol::kLoginNeedsApprovalKey), EncodableValue(false)},
    }));
  } else {
    return false;
  }
  return true;
}

void PlatformBridge::HandleAppearance(const Call& call, Result result) {
  if (call.method_name() == protocol::kGetAppearance) {
    result->Success(EncodableValue(AppearanceSnapshot()));
    return;
  }
  result->NotImplemented();
}

EncodableMap PlatformBridge::LoadSettings() const {
  EncodableMap settings = preferences_;
  settings[EncodableValue(protocol::kSystemLanguageKey)] =
      EncodableValue(windows_system::SystemLanguage());
  settings[EncodableValue(protocol::kLaunchAtLoginKey)] =
      EncodableValue(windows_system::LaunchAtLogin());
  return settings;
}

void PlatformBridge::ApplySettings(const EncodableMap& arguments, Result& result) {
  auto settings = Get<EncodableMap>(arguments, "settings");
  auto credentials = Get<EncodableMap>(arguments, "credentials");
  auto login = settings ? Get<bool>(*settings, protocol::kLaunchAtLoginKey)
                        : std::nullopt;
  if (!settings || !credentials || !login) {
    result->Error(protocol::kBadSettingsError, "系统设置参数不完整。");
    return;
  }
  std::vector<std::pair<std::string, std::optional<EncodableMap>>> requested;
  for (const auto& [key, value] : *credentials) {
    const auto* id = std::get_if<std::string>(&key);
    auto map = value.IsNull() ? std::nullopt : StringMap(value);
    if (!id || (!value.IsNull() && !map)) {
      result->Error(protocol::kBadSettingsError, "系统设置参数不完整。");
      return;
    }
    requested.emplace_back(*id, map);
  }
  std::string error;
  std::vector<std::pair<std::string, std::optional<EncodableMap>>> previous;
  for (const auto& [id, value] : requested) {
    EncodableMap existing;
    auto lookup = credentials::Read(id, existing, error);
    if (lookup == credentials::Lookup::kFailed) {
      result->Error(protocol::kSettingsFailedError, error);
      return;
    }
    previous.emplace_back(id, lookup == credentials::Lookup::kFound
                                  ? std::optional<EncodableMap>(existing)
                                  : std::nullopt);
  }
  bool previous_login = windows_system::LaunchAtLogin();
  size_t written = 0;
  bool login_changed = false;
  bool succeeded = true;
  for (const auto& [id, value] : requested) {
    if (!credentials::Store(id, value, error)) {
      succeeded = false;
      break;
    }
    ++written;
  }
  if (succeeded && *login != previous_login) {
    succeeded = windows_system::SetLaunchAtLogin(*login, error);
    login_changed = succeeded;
  }
  if (succeeded) {
    succeeded = preferences_store::Save(
        data_directory_ / protocol::kPreferencesFile, *settings, error);
  }
  if (!succeeded) {
    std::string rollback_error;
    bool restored = true;
    for (size_t index = written; index > 0; --index) {
      const auto& [id, value] = previous[index - 1];
      restored = credentials::Store(id, value, rollback_error) && restored;
    }
    if (login_changed) {
      restored = windows_system::SetLaunchAtLogin(previous_login, rollback_error) &&
                 restored;
    }
    if (!restored) {
      result->Error(protocol::kRollbackFailedError,
                    "设置未保存，无法恢复部分系统设置或凭据，请检查凭据管理器与登录时启动设置。");
      return;
    }
    result->Error(protocol::kSettingsFailedError, error);
    return;
  }
  preferences_ = *settings;
  preferences_error_.clear();
  preview_.clear();
  BroadcastAppearance();
  result->Success();
}

void PlatformBridge::ReadCredentials(const EncodableMap& arguments, Result& result) {
  auto id = Get<std::string>(arguments, "id");
  if (!id) {
    result->Error(protocol::kBadArgsError, "缺少服务标识。");
    return;
  }
  EncodableMap value;
  std::string error;
  if (credentials::Read(*id, value, error) == credentials::Lookup::kFailed) {
    result->Error(protocol::kCredentialsFailedError, error);
    return;
  }
  result->Success(EncodableValue(value));
}

void PlatformBridge::CredentialIds(const EncodableMap& arguments, Result& result) {
  EncodableList saved;
  for (const auto& item : Get<EncodableList>(arguments, "ids").value_or(EncodableList{})) {
    const auto* id = std::get_if<std::string>(&item);
    if (!id) {
      continue;
    }
    EncodableMap value;
    std::string error;
    auto lookup = credentials::Read(*id, value, error);
    if (lookup == credentials::Lookup::kFailed) {
      result->Error(protocol::kCredentialsFailedError, error);
      return;
    }
    if (lookup == credentials::Lookup::kFound) {
      saved.push_back(EncodableValue(*id));
    }
  }
  result->Success(EncodableValue(saved));
}

EncodableMap PlatformBridge::AppearanceSnapshot() const {
  EncodableMap visual = preferences_;
  for (const auto& [key, value] : preview_) {
    visual[key] = value;
  }
  auto accent = AccentPair(Get<std::string>(visual, protocol::kAccentColorKey)
                               .value_or(protocol::kAppearanceSystem));
  int64_t system = windows_system::SystemAccent();
  return EncodableMap{
      {EncodableValue(protocol::kGlassAppearanceKey),
       EncodableValue(Get<std::string>(visual, protocol::kGlassAppearanceKey)
                          .value_or(protocol::kAppearanceSystem))},
      {EncodableValue(protocol::kGlassOpacityKey),
       EncodableValue(Get<double>(visual, protocol::kGlassOpacityKey)
                          .value_or(protocol::kGlassOpacityFallback))},
      {EncodableValue(protocol::kAccentForegroundKey),
       EncodableValue(Get<std::string>(visual, protocol::kAccentForegroundKey)
                          .value_or(protocol::kAccentForegroundAuto))},
      {EncodableValue(protocol::kAccentLightKey),
       EncodableValue(accent ? accent->first : system)},
      {EncodableValue(protocol::kAccentDarkKey),
       EncodableValue(accent ? accent->second : system)},
      {EncodableValue(protocol::kFontSetKey),
       EncodableValue(Get<std::string>(visual, protocol::kFontSetKey)
                          .value_or(protocol::kFontSetFallback))},
      {EncodableValue(protocol::kFontsDirectoryKey),
       EncodableValue(Utf8FromUtf16((data_directory_ / protocol::kFontsDirectoryName).wstring().c_str()))},
      {EncodableValue(protocol::kFontStateKey), EncodableValue(font_state_)},
      {EncodableValue(protocol::kGlassMaterialKey),
       EncodableValue(windows_system::SupportsAcrylic()
                          ? protocol::kGlassMaterialAcrylic
                          : protocol::kGlassMaterialOpaque)},
  };
}

void PlatformBridge::BroadcastAppearance() {
  EncodableMap snapshot = AppearanceSnapshot();
  appearance_->InvokeMethod(protocol::kAppearanceChanged,
                            std::make_unique<EncodableValue>(snapshot));
  for (const auto& entry : window_appearance_) {
    entry.second->InvokeMethod(protocol::kAppearanceChanged,
                               std::make_unique<EncodableValue>(snapshot));
  }
}
