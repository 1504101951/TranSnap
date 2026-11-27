#include "selection_monitor.h"

#include <windows.h>

#include <cstdlib>
#include <utility>

#include "key_names.h"
#include "protocol.h"
#include "windows_system.h"

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

SelectionMonitor* g_monitor = nullptr;

bool Pressed(int key) {
  return (GetAsyncKeyState(key) & 0x8000) != 0;
}

key_names::Modifiers CurrentModifiers() {
  return {Pressed(VK_CONTROL), Pressed(VK_MENU), Pressed(VK_SHIFT),
          Pressed(VK_LWIN) || Pressed(VK_RWIN)};
}

bool ForegroundIsOwnProcess() {
  DWORD process = 0;
  GetWindowThreadProcessId(GetForegroundWindow(), &process);
  return process == GetCurrentProcessId();
}

LRESULT CALLBACK MouseProc(int code, WPARAM message, LPARAM data) {
  const auto* event = reinterpret_cast<const MSLLHOOKSTRUCT*>(data);
  if (code == HC_ACTION && g_monitor && (message == WM_LBUTTONDOWN || message == WM_LBUTTONUP) &&
      event->dwExtraInfo != protocol::kSyntheticEventTag) {
    g_monitor->HandleMouse(message == WM_LBUTTONDOWN, event->pt.x, event->pt.y, event->time);
  }
  return CallNextHookEx(nullptr, code, message, data);
}

LRESULT CALLBACK KeyboardProc(int code, WPARAM message, LPARAM data) {
  const auto* event = reinterpret_cast<const KBDLLHOOKSTRUCT*>(data);
  bool down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
  bool up = message == WM_KEYUP || message == WM_SYSKEYUP;
  if (code == HC_ACTION && g_monitor && (down || up) &&
      event->dwExtraInfo != protocol::kSyntheticEventTag) {
    unsigned extended = (event->flags & LLKHF_EXTENDED) ? key_names::kExtended : 0;
    if (g_monitor->HandleKey(down, event->scanCode | extended)) {
      return 1;
    }
  }
  return CallNextHookEx(nullptr, code, message, data);
}

}

SelectionMonitor::SelectionMonitor(Delegate delegate) : delegate_(std::move(delegate)) {
  g_monitor = this;
  HINSTANCE module = GetModuleHandleW(nullptr);
  mouse_hook_ = SetWindowsHookExW(WH_MOUSE_LL, MouseProc, module, 0);
  keyboard_hook_ = SetWindowsHookExW(WH_KEYBOARD_LL, KeyboardProc, module, 0);
}

SelectionMonitor::~SelectionMonitor() {
  if (mouse_hook_) {
    UnhookWindowsHookEx(mouse_hook_);
  }
  if (keyboard_hook_) {
    UnhookWindowsHookEx(keyboard_hook_);
  }
  g_monitor = nullptr;
}

void SelectionMonitor::HandleMouse(bool down, long x, long y, unsigned long time) {
  bool automatic = delegate_.automatic();
  if (!automatic && !down) {
    return;
  }
  if (down) {
    ClearPendingKey();
    ignore_mouse_ = delegate_.ignores(x, y) || ForegroundIsOwnProcess();
    bool repeated = time - last_down_time_ <= GetDoubleClickTime() &&
                    std::labs(x - last_down_x_) * 2 <= GetSystemMetrics(SM_CXDOUBLECLK) &&
                    std::labs(y - last_down_y_) * 2 <= GetSystemMetrics(SM_CYDOUBLECLK);
    click_count_ = repeated ? click_count_ + 1 : 1;
    last_down_x_ = x;
    last_down_y_ = y;
    last_down_time_ = time;
  }
  if (ignore_mouse_) {
    return;
  }
  if (down) {
    delegate_.invalidate(protocol::kSelectionInvalidatedEvent);
    ++pointer_generation_;
  }
  if (!automatic) {
    return;
  }
  auto [logical_x, logical_y] = windows_system::LogicalPoint(x, y);
  EncodableMap request{
      {EncodableValue("kind"), EncodableValue(down ? protocol::kPointerDownKind : protocol::kPointerUpKind)},
      {EncodableValue("clickCount"), EncodableValue(click_count_)},
      {EncodableValue("x"), EncodableValue(logical_x)},
      {EncodableValue("y"), EncodableValue(logical_y)},
  };
  unsigned generation = pointer_generation_;
  std::weak_ptr<char> alive = alive_;
  delegate_.request(protocol::kSelectionPointer, EncodableValue(request),
                    [this, alive, generation](const EncodableValue* reply) {
                      const auto* gesture = reply ? std::get_if<std::string>(reply) : nullptr;
                      if (alive.expired() || pointer_generation_ != generation || !gesture) {
                        return;
                      }
                      delegate_.capture(*gesture);
                    });
}

void SelectionMonitor::Record(Recorder recorder) {
  recorder_ = std::move(recorder);
}

bool SelectionMonitor::HandleKey(bool down, unsigned scan_code) {
  if (recorder_ && down && ForegroundIsOwnProcess() && recorder_(scan_code, CurrentModifiers())) {
    recorder_ = nullptr;
    return true;
  }
  bool automatic = delegate_.automatic();
  auto key = key_names::Name(scan_code);
  bool escape = key && *key == protocol::kEscapeKeyName;
  if (!automatic && down && !escape) {
    return false;
  }
  if (escape && down) {
    ClearPendingKey();
    delegate_.invalidate(protocol::kEscapePressedEvent);
    return false;
  }
  key_names::Modifiers modifiers = CurrentModifiers();
  auto name = down ? key_names::SelectionKey(scan_code, modifiers) : std::nullopt;
  if (down && !name) {
    return false;
  }
  key_events_.push_back({down, scan_code, name, key_names::ModifierNames(modifiers), key_generation_});
  DrainKeys();
  return false;
}

void SelectionMonitor::ClearPendingKey() {
  pending_key_.reset();
  ++key_generation_;
}

void SelectionMonitor::DrainKeys() {
  while (!key_request_in_flight_ && !key_events_.empty()) {
    KeyEvent event = std::move(key_events_.front());
    key_events_.pop_front();
    if (!event.down) {
      if (pending_key_ && pending_key_->first == event.scan_code) {
        std::string gesture = pending_key_->second;
        pending_key_.reset();
        delegate_.capture(gesture);
        continue;
      }
      delegate_.validate();
      continue;
    }
    EncodableList modifiers;
    for (const auto& modifier : event.modifiers) {
      modifiers.push_back(EncodableValue(modifier));
    }
    EncodableMap request{
        {EncodableValue("key"), EncodableValue(*event.name)},
        {EncodableValue("modifiers"), EncodableValue(modifiers)},
    };
    key_request_in_flight_ = true;
    std::weak_ptr<char> alive = alive_;
    unsigned scan_code = event.scan_code;
    unsigned generation = event.generation;
    delegate_.request(protocol::kSelectionKey, EncodableValue(request),
                      [this, alive, scan_code, generation](const EncodableValue* reply) {
                        if (alive.expired()) {
                          return;
                        }
                        key_request_in_flight_ = false;
                        const auto* gesture = reply ? std::get_if<std::string>(reply) : nullptr;
                        if (gesture && key_generation_ == generation) {
                          pending_key_ = std::make_pair(scan_code, *gesture);
                        }
                        DrainKeys();
                      });
  }
}
