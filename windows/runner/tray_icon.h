#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>

#include <functional>

class TrayIcon {
 public:
  struct Actions {
    std::function<bool()> automatic;
    std::function<void()> toggle_automatic;
    std::function<void()> quit;
  };

  static constexpr UINT kCallbackMessage = WM_APP + 1;

  TrayIcon(HWND window, Actions actions);
  ~TrayIcon();

  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  enum Command : UINT { kToggleAutomatic = 1, kQuit };

  void Add();
  void ShowMenu();

  HWND window_;
  Actions actions_;
  UINT taskbar_created_;
};

#endif
