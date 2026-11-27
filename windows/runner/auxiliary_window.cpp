#include "auxiliary_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <utility>

#include "flutter/generated_plugin_registrant.h"
#include "protocol.h"
#include "utils.h"
#include "windows_system.h"

AuxiliaryWindow::AuxiliaryWindow(PlatformBridge& bridge, Options options)
    : bridge_(bridge), options_(std::move(options)) {}

AuxiliaryWindow::~AuxiliaryWindow() {
  Destroy();
}

void AuxiliaryWindow::Open() {
  if (GetHandle()) {
    if (ready_) {
      Refresh();
      Present();
    }
    return;
  }
  RECT work = {};
  ::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  double scale = ::GetDpiForSystem() / 96.0;
  int left = static_cast<int>((work.left + work.right) / 2 / scale - options_.width / 2.0);
  int top = static_cast<int>((work.top + work.bottom) / 2 / scale - options_.height / 2.0);
  Create(options_.title,
         Point(static_cast<unsigned int>(left > 0 ? left : 0),
               static_cast<unsigned int>(top > 0 ? top : 0)),
         Size(options_.width, options_.height));
}

bool AuxiliaryWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }
  ready_ = false;
  flutter::DartProject project(L"data");
  project.set_dart_entrypoint(options_.entrypoint);
  RECT frame = GetClientArea();
  controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project);
  if (!controller_->engine() || !controller_->view()) {
    return false;
  }
  RegisterPlugins(controller_->engine());
  flutter::BinaryMessenger* messenger = controller_->engine()->messenger();
  const auto& codec = flutter::StandardMethodCodec::GetInstance();
  startup_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, protocol::kWindowStartupChannel, &codec);
  startup_->SetMethodCallHandler(
      [this](const PlatformBridge::Call& call, PlatformBridge::Result result) {
        if (call.method_name() != protocol::kWindowReady) {
          result->NotImplemented();
          return;
        }
        result->Success();
        if (ready_) {
          return;
        }
        ready_ = true;
        ::KillTimer(GetHandle(), kStartupTimer);
        Present();
      });
  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, protocol::kSettingsChannel, &codec);
  window_channel_->SetMethodCallHandler(
      [this](const PlatformBridge::Call& call, PlatformBridge::Result result) {
        HandleWindowRequest(call, std::move(result));
      });
  appearance_token_ = bridge_.AddAppearanceEngine(messenger);
  SetChildContent(controller_->view()->GetNativeWindow());
  ::SetTimer(GetHandle(), kStartupTimer, kStartupTimeoutMilliseconds, nullptr);
  return true;
}

void AuxiliaryWindow::OnDestroy() {
  if (appearance_token_ != 0) {
    bridge_.RemoveAppearanceEngine(appearance_token_);
    appearance_token_ = 0;
  }
  if (startup_) {
    startup_->SetMethodCallHandler(nullptr);
  }
  if (window_channel_) {
    window_channel_->SetMethodCallHandler(nullptr);
  }
  startup_ = nullptr;
  window_channel_ = nullptr;
  controller_ = nullptr;
  ready_ = false;
  Win32Window::OnDestroy();
}

void AuxiliaryWindow::Refresh() {
  if (window_channel_ && ready_ && !options_.refresh_method.empty()) {
    window_channel_->InvokeMethod(options_.refresh_method, nullptr);
  }
}

void AuxiliaryWindow::Present() {
  HWND window = GetHandle();
  ::ShowWindow(window, ::IsIconic(window) ? SW_RESTORE : SW_SHOWNORMAL);
  ::SetForegroundWindow(window);
}

void AuxiliaryWindow::HandleWindowRequest(const PlatformBridge::Call& call,
                                          PlatformBridge::Result result) {
  const auto* arguments = call.arguments()
                              ? std::get_if<flutter::EncodableMap>(call.arguments())
                              : nullptr;
  if (call.method_name() == protocol::kSetWindowTitle) {
    const std::string* text = nullptr;
    if (arguments) {
      auto title = arguments->find(flutter::EncodableValue("title"));
      if (title != arguments->end()) {
        text = std::get_if<std::string>(&title->second);
      }
    }
    if (!text) {
      result->Error(protocol::kBadArgsError, "缺少窗口标题");
      return;
    }
    ::SetWindowTextW(GetHandle(), Utf16FromUtf8(*text).c_str());
    result->Success();
    return;
  }
  if (call.method_name() == protocol::kStartWindowDrag) {
    ::ReleaseCapture();
    ::SendMessageW(GetHandle(), WM_NCLBUTTONDOWN, HTCAPTION, 0);
    result->Success();
    return;
  }
  bridge_.RouteWindowRequest(call, std::move(result));
}

LRESULT AuxiliaryWindow::MessageHandler(HWND hwnd, UINT const message,
                                        WPARAM const wparam,
                                        LPARAM const lparam) noexcept {
  if (controller_) {
    std::optional<LRESULT> result =
        controller_->HandleTopLevelWindowProc(hwnd, message, wparam, lparam);
    if (result) {
      return *result;
    }
  }
  if (message == WM_TIMER && wparam == kStartupTimer) {
    ::KillTimer(hwnd, kStartupTimer);
    if (!ready_) {
      ::PostMessageW(hwnd, WM_CLOSE, 0, 0);
      windows_system::ShowWarning(
          "TranSnap", Utf8FromUtf16(options_.title.c_str()) + "窗口启动超时，请重试。");
    }
    return 0;
  }
  if (message == WM_FONTCHANGE && controller_) {
    controller_->engine()->ReloadSystemFonts();
  }
  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
