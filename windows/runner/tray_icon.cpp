#include "tray_icon.h"

#include <shellapi.h>

#include <utility>

#include "resource.h"

namespace {

constexpr UINT kIconId = 1;

NOTIFYICONDATAW IconData(HWND window) {
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window;
  data.uID = kIconId;
  return data;
}

}

TrayIcon::TrayIcon(HWND window, Actions actions)
    : window_(window),
      actions_(std::move(actions)),
      taskbar_created_(::RegisterWindowMessageW(L"TaskbarCreated")) {
  Add();
}

TrayIcon::~TrayIcon() {
  NOTIFYICONDATAW data = IconData(window_);
  ::Shell_NotifyIconW(NIM_DELETE, &data);
}

void TrayIcon::Add() {
  NOTIFYICONDATAW data = IconData(window_);
  data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kCallbackMessage;
  data.hIcon = static_cast<HICON>(::LoadImageW(
      ::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      ::GetSystemMetrics(SM_CXSMICON), ::GetSystemMetrics(SM_CYSMICON),
      LR_DEFAULTCOLOR));
  wcscpy_s(data.szTip, L"TranSnap");
  ::Shell_NotifyIconW(NIM_ADD, &data);
  data.uVersion = NOTIFYICON_VERSION_4;
  ::Shell_NotifyIconW(NIM_SETVERSION, &data);
}

bool TrayIcon::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == taskbar_created_) {
    Add();
    return true;
  }
  if (message != kCallbackMessage) {
    return false;
  }
  UINT event = LOWORD(lparam);
  if (event == WM_CONTEXTMENU || event == NIN_SELECT || event == NIN_KEYSELECT) {
    ShowMenu();
  }
  return true;
}

void TrayIcon::ShowMenu() {
  HMENU menu = ::CreatePopupMenu();
  ::AppendMenuW(menu, MF_STRING, kOpenSettings, L"设置…");
  ::AppendMenuW(menu, MF_STRING, kOpenHistory, L"翻译历史…");
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING | (actions_.automatic() ? MF_UNCHECKED : MF_CHECKED),
                kToggleAutomatic, L"仅使用快捷键");
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kQuit, L"退出");
  POINT cursor;
  ::GetCursorPos(&cursor);
  ::SetForegroundWindow(window_);
  UINT command = static_cast<UINT>(::TrackPopupMenuEx(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, cursor.x, cursor.y,
      window_, nullptr));
  ::PostMessageW(window_, WM_NULL, 0, 0);
  ::DestroyMenu(menu);
  if (command == kOpenSettings) {
    actions_.open_settings();
  } else if (command == kOpenHistory) {
    actions_.open_history();
  } else if (command == kToggleAutomatic) {
    actions_.toggle_automatic();
  } else if (command == kQuit) {
    actions_.quit();
  }
}
