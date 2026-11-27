#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "auxiliary_window.h"
#include "overlay_window.h"
#include "platform_bridge.h"
#include "tray_icon.h"
#include "win32_window.h"

class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<OverlayWindow> overlay_;
  std::unique_ptr<PlatformBridge> bridge_;
  std::unique_ptr<AuxiliaryWindow> settings_window_;
  std::unique_ptr<AuxiliaryWindow> history_window_;
  std::unique_ptr<TrayIcon> tray_;
};

#endif
