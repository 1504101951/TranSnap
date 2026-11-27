#include "global_hotkeys.h"

#include <windows.h>

#include <algorithm>

namespace {

constexpr wchar_t kWindowClass[] = L"TranSnapGlobalHotkeys";

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* hotkeys = reinterpret_cast<GlobalHotkeys*>(::GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_HOTKEY && hotkeys) {
    hotkeys->Pressed(static_cast<int>(wparam));
    return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

UINT Modifiers(const key_names::Modifiers& modifiers) {
  return MOD_NOREPEAT | (modifiers.control ? MOD_CONTROL : 0) | (modifiers.alt ? MOD_ALT : 0) |
         (modifiers.shift ? MOD_SHIFT : 0) | (modifiers.meta ? MOD_WIN : 0);
}

UINT VirtualKey(unsigned scan_code) {
  unsigned extended = (scan_code & key_names::kExtended) != 0 ? 0xE000 : 0;
  return ::MapVirtualKeyW((scan_code & 0xFF) | extended, MAPVK_VSC_TO_VK_EX);
}

}

GlobalHotkeys::GlobalHotkeys(std::function<void(const std::string& gesture)> pressed)
    : pressed_(std::move(pressed)) {
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = kWindowClass;
  ::RegisterClassW(&window_class);
  window_ = ::CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                              window_class.hInstance, nullptr);
  ::SetWindowLongPtrW(window_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
}

GlobalHotkeys::~GlobalHotkeys() {
  for (const auto& entry : registered_) {
    ::UnregisterHotKey(window_, entry.id);
  }
  ::DestroyWindow(window_);
}

bool GlobalHotkeys::Apply(const std::vector<Request>& requests, std::string& error) {
  for (size_t index = 0; index < requests.size(); ++index) {
    for (size_t other = index + 1; other < requests.size(); ++other) {
      if (shortcut_rules::Same(requests[index].shortcut, requests[other].shortcut)) {
        error = shortcut_rules::kDuplicateMessage;
        return false;
      }
    }
  }
  std::vector<Registered> replacements;
  std::vector<int> created;
  for (const auto& request : requests) {
    auto existing = std::find_if(registered_.begin(), registered_.end(), [&](const Registered& entry) {
      return shortcut_rules::Same(entry.shortcut, request.shortcut);
    });
    if (existing != registered_.end()) {
      replacements.push_back({existing->id, request.purpose, request.shortcut});
      continue;
    }
    int id = next_id_++;
    if (!::RegisterHotKey(window_, id, Modifiers(request.shortcut.modifiers),
                          VirtualKey(request.shortcut.scan_code))) {
      for (int created_id : created) {
        ::UnregisterHotKey(window_, created_id);
      }
      error = std::string("「") + request.purpose->title + "」已被其他应用占用，请换一个组合。";
      return false;
    }
    created.push_back(id);
    replacements.push_back({id, request.purpose, request.shortcut});
  }
  for (const auto& old : registered_) {
    bool kept = std::any_of(replacements.begin(), replacements.end(),
                            [&](const Registered& entry) { return entry.id == old.id; });
    if (!kept) {
      ::UnregisterHotKey(window_, old.id);
    }
  }
  registered_ = std::move(replacements);
  return true;
}

void GlobalHotkeys::Pressed(int id) {
  auto entry = std::find_if(registered_.begin(), registered_.end(),
                            [id](const Registered& registered) { return registered.id == id; });
  if (entry != registered_.end()) {
    pressed_(entry->purpose->gesture);
  }
}
