#ifndef RUNNER_PLATFORM_BRIDGE_H_
#define RUNNER_PLATFORM_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>

#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <string>

#include "selection_capture.h"
#include "speech_service.h"

class PlatformBridge {
 public:
  explicit PlatformBridge(flutter::BinaryMessenger* messenger);

  void Emit(const flutter::EncodableMap& event);

  bool Automatic() const;

  void ToggleAutomatic();

  void SetWindowRefreshHandlers(std::function<void()> settings_changed,
                                std::function<void()> history_changed);

  using Call = flutter::MethodCall<flutter::EncodableValue>;
  using Result = std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;

  void RouteWindowRequest(const Call& call, Result result);

  int AddAppearanceEngine(flutter::BinaryMessenger* messenger);

  void RemoveAppearanceEngine(int token);

 private:
  void HandlePlatform(const Call& call, Result result);
  bool HandleLocal(const Call& call, Result& result);
  void HandleAppearance(const Call& call, Result result);
  void ApplySettings(const flutter::EncodableMap& arguments, Result& result);
  void ReadCredentials(const flutter::EncodableMap& arguments, Result& result);
  void CredentialIds(const flutter::EncodableMap& arguments, Result& result);
  flutter::EncodableMap LoadSettings() const;
  flutter::EncodableMap AppearanceSnapshot() const;
  void RequestApplication(const char* method, flutter::EncodableValue arguments,
                          SelectionMonitor::Reply reply);
  bool Excluded(const std::wstring& executable) const;
  void BroadcastAppearance();

  std::filesystem::path data_directory_;
  flutter::EncodableMap preferences_;
  std::string preferences_error_;
  flutter::EncodableMap font_state_;
  flutter::EncodableMap preview_;
  std::map<int, std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>>
      window_appearance_;
  int next_appearance_token_ = 1;
  std::function<void()> settings_changed_;
  std::function<void()> history_changed_;
  std::unique_ptr<SpeechService> speech_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> platform_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> appearance_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  std::unique_ptr<SelectionCapture> capture_;
};

#endif
