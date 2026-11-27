#include "windows_system.h"

#include <flutter_windows.h>
#include <windows.h>
#include <dwmapi.h>
#include <shlobj.h>
#include <uxtheme.h>

#include <cmath>
#include <cwchar>
#include <optional>
#include <iterator>
#include <vector>

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

void ApplyAcrylic(HWND__* window) {
  MARGINS margins = {-1, -1, -1, -1};
  ::DwmExtendFrameIntoClientArea(window, &margins);
  DWM_SYSTEMBACKDROP_TYPE backdrop = DWMSBT_TRANSIENTWINDOW;
  ::DwmSetWindowAttribute(window, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop,
                          sizeof(backdrop));
}

std::pair<double, double> LogicalPoint(long x, long y) {
  HMONITOR monitor = ::MonitorFromPoint(POINT{x, y}, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{sizeof(info)};
  ::GetMonitorInfoW(monitor, &info);
  double scale = FlutterDesktopGetDpiForMonitor(reinterpret_cast<intptr_t>(monitor)) / 96.0;
  return {info.rcMonitor.left + (x - info.rcMonitor.left) / scale,
          info.rcMonitor.top + (y - info.rcMonitor.top) / scale};
}

ScreenPoint PhysicalPoint(double x, double y) {
  struct Search {
    double x;
    double y;
    std::optional<ScreenPoint> found;
  } search{x, y, std::nullopt};
  ::EnumDisplayMonitors(
      nullptr, nullptr,
      [](HMONITOR monitor, HDC, LPRECT bounds, LPARAM data) -> BOOL {
        auto* search = reinterpret_cast<Search*>(data);
        double scale = FlutterDesktopGetDpiForMonitor(reinterpret_cast<intptr_t>(monitor)) / 96.0;
        double right = bounds->left + (bounds->right - bounds->left) / scale;
        double bottom = bounds->top + (bounds->bottom - bounds->top) / scale;
        if (search->x < bounds->left || search->x >= right || search->y < bounds->top ||
            search->y >= bottom) {
          return TRUE;
        }
        search->found = ScreenPoint{
            std::lround(bounds->left + (search->x - bounds->left) * scale),
            std::lround(bounds->top + (search->y - bounds->top) * scale), scale};
        return FALSE;
      },
      reinterpret_cast<LPARAM>(&search));
  if (search.found) {
    return *search.found;
  }
  POINT point{std::lround(x), std::lround(y)};
  HMONITOR monitor = ::MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST);
  return {point.x, point.y,
          FlutterDesktopGetDpiForMonitor(reinterpret_cast<intptr_t>(monitor)) / 96.0};
}

std::wstring ProcessImagePath(unsigned long process) {
  HANDLE handle = ::OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process);
  if (!handle) {
    return L"";
  }
  wchar_t path[MAX_PATH * 4] = {};
  DWORD size = static_cast<DWORD>(std::size(path));
  BOOL queried = ::QueryFullProcessImageNameW(handle, 0, path, &size);
  ::CloseHandle(handle);
  return queried ? std::wstring(path, size) : L"";
}

std::string ApplicationDisplayName(const std::wstring& executable) {
  DWORD size = executable.empty() ? 0 : ::GetFileVersionInfoSizeW(executable.c_str(), nullptr);
  std::vector<BYTE> data(size);
  struct Translation {
    WORD language;
    WORD code_page;
  };
  Translation* translations = nullptr;
  UINT translations_size = 0;
  if (size && ::GetFileVersionInfoW(executable.c_str(), 0, size, data.data()) &&
      ::VerQueryValueW(data.data(), L"\\VarFileInfo\\Translation",
                       reinterpret_cast<void**>(&translations), &translations_size) &&
      translations_size >= sizeof(Translation)) {
    wchar_t key[64] = {};
    swprintf_s(key, L"\\StringFileInfo\\%04x%04x\\FileDescription", translations->language,
               translations->code_page);
    wchar_t* description = nullptr;
    UINT length = 0;
    if (::VerQueryValueW(data.data(), key, reinterpret_cast<void**>(&description), &length) &&
        length > 1) {
      return Utf8FromUtf16(description);
    }
  }
  return Utf8FromUtf16(std::filesystem::path(executable).stem().wstring().c_str());
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
