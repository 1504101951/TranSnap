#include "main_thread.h"

#include <windows.h>

#include <map>
#include <memory>
#include <thread>

namespace main_thread {
namespace {

constexpr wchar_t kWindowClass[] = L"TranSnapMainThread";
constexpr UINT kRunTask = WM_APP + 1;

HWND g_window = nullptr;
UINT_PTR g_next_timer = 1;
std::map<UINT_PTR, std::function<void()>> g_timers;

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kRunTask) {
    std::unique_ptr<std::function<void()>> task(reinterpret_cast<std::function<void()>*>(lparam));
    (*task)();
    return 0;
  }
  if (message == WM_TIMER) {
    ::KillTimer(window, wparam);
    auto found = g_timers.find(wparam);
    if (found == g_timers.end()) {
      return 0;
    }
    auto task = std::move(found->second);
    g_timers.erase(found);
    task();
    return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

}

void Start() {
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = kWindowClass;
  ::RegisterClassW(&window_class);
  g_window = ::CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                               window_class.hInstance, nullptr);
}

void Stop() {
  HWND window = g_window;
  g_window = nullptr;
  g_timers.clear();
  if (window) {
    ::DestroyWindow(window);
  }
}

HWND__* Window() {
  return g_window;
}

void Background(std::function<void()> task) {
  std::thread([task = std::move(task)]() {
    ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    task();
    ::CoUninitialize();
  }).detach();
}

void Post(std::function<void()> task) {
  auto pending = std::make_unique<std::function<void()>>(std::move(task));
  HWND window = g_window;
  if (window && ::PostMessageW(window, kRunTask, 0, reinterpret_cast<LPARAM>(pending.get()))) {
    pending.release();
  }
}

void After(unsigned milliseconds, std::function<void()> task) {
  UINT_PTR timer = g_next_timer++;
  g_timers[timer] = std::move(task);
  ::SetTimer(g_window, timer, milliseconds, nullptr);
}

}
