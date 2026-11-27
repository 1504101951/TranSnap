#include "windows_system.h"

#include <windows.h>
#include <dwmapi.h>
#include <shlobj.h>
#include <uxtheme.h>

#include "protocol.h"
#include "utils.h"

namespace windows_system {

std::filesystem::path DataDirectory() {
  PWSTR roaming = nullptr;
  std::filesystem::path directory;
  if (SUCCEEDED(::SHGetKnownFolderPath(FOLDERID_RoamingAppData, KF_FLAG_CREATE,
                                       nullptr, &roaming))) {
    directory = std::filesystem::path(roaming) / protocol::kDataDirectoryName;
  }
  ::CoTaskMemFree(roaming);
  return directory;
}

std::string SystemLanguage() {
  wchar_t locale[LOCALE_NAME_MAX_LENGTH] = {};
  if (::GetUserDefaultLocaleName(locale, LOCALE_NAME_MAX_LENGTH) == 0) {
    return "en";
  }
  return Utf8FromUtf16(locale);
}

bool LaunchAtLogin() {
  return ::RegGetValueW(HKEY_CURRENT_USER, protocol::kRunKey, protocol::kRunValue,
                        RRF_RT_REG_SZ, nullptr, nullptr, nullptr) == ERROR_SUCCESS;
}

bool SetLaunchAtLogin(bool enabled, std::string& error) {
  LSTATUS status;
  if (enabled) {
    wchar_t path[MAX_PATH] = {};
    DWORD length = ::GetModuleFileNameW(nullptr, path, MAX_PATH);
    if (length == 0 || length == MAX_PATH) {
      error = "无法取得程序路径，未能设置登录时启动。";
      return false;
    }
    std::wstring command = L"\"" + std::wstring(path, length) + L"\"";
    status = ::RegSetKeyValueW(
        HKEY_CURRENT_USER, protocol::kRunKey, protocol::kRunValue, REG_SZ,
        command.c_str(),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    status = ::RegDeleteKeyValueW(HKEY_CURRENT_USER, protocol::kRunKey,
                                  protocol::kRunValue);
    if (status == ERROR_FILE_NOT_FOUND) {
      status = ERROR_SUCCESS;
    }
  }
  if (status != ERROR_SUCCESS) {
    error = "无法修改登录时启动设置（错误 " + std::to_string(status) + "）。";
    return false;
  }
  return true;
}

int64_t SystemAccent() {
  DWORD abgr = 0;
  DWORD size = sizeof(abgr);
  if (::RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\DWM",
                     L"AccentColor", RRF_RT_REG_DWORD, nullptr, &abgr,
                     &size) != ERROR_SUCCESS) {
    return 0xFF0078D4;
  }
  int64_t red = abgr & 0xFF;
  int64_t green = (abgr >> 8) & 0xFF;
  int64_t blue = (abgr >> 16) & 0xFF;
  return 0xFF000000 | (red << 16) | (green << 8) | blue;
}

bool SupportsAcrylic() {
  using RtlGetVersion = LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
  auto get_version = reinterpret_cast<RtlGetVersion>(
      ::GetProcAddress(::GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion"));
  RTL_OSVERSIONINFOW version = {};
  version.dwOSVersionInfoSize = sizeof(version);
  return get_version && get_version(&version) == 0 &&
         version.dwBuildNumber >= protocol::kAcrylicMinimumBuild;
}

void ApplyAcrylic(HWND window) {
  MARGINS margins = {-1, -1, -1, -1};
  ::DwmExtendFrameIntoClientArea(window, &margins);
  DWM_SYSTEMBACKDROP_TYPE backdrop = DWMSBT_TRANSIENTWINDOW;
  ::DwmSetWindowAttribute(window, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop,
                          sizeof(backdrop));
}

void ShowWarning(const std::string& title, const std::string& message) {
  std::wstring caption = Utf16FromUtf8(title);
  std::wstring text = Utf16FromUtf8(message);
  ::MessageBoxW(nullptr, text.c_str(), caption.c_str(),
                MB_OK | MB_ICONWARNING | MB_TOPMOST);
}

void ShowStartFailure(const std::string& message) {
  ShowWarning("TranSnap 无法启动", "主程序初始化失败：" + message);
  ::ExitProcess(EXIT_FAILURE);
}

}
