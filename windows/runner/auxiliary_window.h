#ifndef RUNNER_AUXILIARY_WINDOW_H_
#define RUNNER_AUXILIARY_WINDOW_H_

#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include "platform_bridge.h"
#include "win32_window.h"

class AuxiliaryWindow : public Win32Window {
 public:
  struct Options {
    std::string entrypoint;
    std::wstring title;
    unsigned int width;
    unsigned int height;
    std::string refresh_method;
  };

  AuxiliaryWindow(PlatformBridge& bridge, Options options);
  ~AuxiliaryWindow() override;

  void Open();

  void Refresh();

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  static constexpr UINT_PTR kStartupTimer = 1;
  static constexpr UINT kStartupTimeoutMilliseconds = 5000;

  void Present();
  void HandleWindowRequest(const PlatformBridge::Call& call,
                           PlatformBridge::Result result);

  PlatformBridge& bridge_;
  Options options_;
  bool ready_ = false;
  int appearance_token_ = 0;
  std::unique_ptr<flutter::FlutterViewController> controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> startup_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;
};

#endif
