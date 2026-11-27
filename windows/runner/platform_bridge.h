#ifndef RUNNER_PLATFORM_BRIDGE_H_
#define RUNNER_PLATFORM_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>

#include <filesystem>
#include <memory>
#include <string>

class PlatformBridge {
 public:
  explicit PlatformBridge(flutter::BinaryMessenger* messenger);

  void Emit(const flutter::EncodableMap& event);

  bool Automatic() const;

  void ToggleAutomatic();

 private:
  using Call = flutter::MethodCall<flutter::EncodableValue>;
  using Result = std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;

  void HandlePlatform(const Call& call, Result result);
  void HandleAppearance(const Call& call, Result result);
  void ApplySettings(const flutter::EncodableMap& arguments, Result& result);
  void ReadCredentials(const flutter::EncodableMap& arguments, Result& result);
  void CredentialIds(const flutter::EncodableMap& arguments, Result& result);
  flutter::EncodableMap LoadSettings() const;
  flutter::EncodableMap AppearanceSnapshot() const;
  void BroadcastAppearance();

  std::filesystem::path data_directory_;
  flutter::EncodableMap preferences_;
  std::string preferences_error_;
  flutter::EncodableMap font_state_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> platform_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> appearance_;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>> events_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
};

#endif
