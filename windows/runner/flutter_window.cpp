#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "main_thread.h"
#include "protocol.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  main_thread::Start();

  RECT frame = GetClientArea();
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  overlay_ = std::make_unique<OverlayWindow>(GetHandle());
  bridge_ = std::make_unique<PlatformBridge>(
      flutter_controller_->engine()->messenger(), *overlay_);
  settings_window_ = std::make_unique<AuxiliaryWindow>(
      *bridge_, AuxiliaryWindow::Options{protocol::kSettingsEntrypoint, L"设置",
                                         760, 640, protocol::kRefreshSettings});
  history_window_ = std::make_unique<AuxiliaryWindow>(
      *bridge_, AuxiliaryWindow::Options{protocol::kHistoryEntrypoint, L"翻译历史",
                                         520, 640, protocol::kHistoryChanged});
  bridge_->SetWindowRefreshHandlers([this]() { settings_window_->Refresh(); },
                                    [this]() { history_window_->Refresh(); });
  tray_ = std::make_unique<TrayIcon>(
      GetHandle(),
      TrayIcon::Actions{[this]() { settings_window_->Open(); },
                        [this]() { history_window_->Open(); },
                        [this]() { return bridge_->Automatic(); },
                        [this]() { bridge_->ToggleAutomatic(); },
                        [this]() { ::PostMessageW(GetHandle(), WM_CLOSE, 0, 0); }});
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  tray_ = nullptr;
  settings_window_ = nullptr;
  history_window_ = nullptr;
  bridge_ = nullptr;
  overlay_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  main_thread::Stop();

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (tray_ && tray_->HandleMessage(message, wparam, lparam)) {
    return 0;
  }

  switch (message) {
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
