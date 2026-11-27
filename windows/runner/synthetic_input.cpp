#include "synthetic_input.h"

#include <windows.h>

#include <vector>

#include "protocol.h"

namespace synthetic_input {
namespace {

constexpr WORD kHeldModifiers[] = {VK_MENU, VK_SHIFT, VK_LWIN, VK_RWIN};

INPUT Key(WORD virtual_key, bool up) {
  INPUT input{};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = virtual_key;
  input.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
  input.ki.dwExtraInfo = static_cast<ULONG_PTR>(protocol::kSyntheticEventTag);
  return input;
}

}

void SendControlShortcut(unsigned short virtual_key) {
  std::vector<INPUT> inputs;
  bool control_held = (::GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
  if (!control_held) {
    inputs.push_back(Key(VK_CONTROL, false));
  }
  for (WORD modifier : kHeldModifiers) {
    if (::GetAsyncKeyState(modifier) & 0x8000) {
      inputs.push_back(Key(modifier, true));
    }
  }
  inputs.push_back(Key(virtual_key, false));
  inputs.push_back(Key(virtual_key, true));
  if (!control_held) {
    inputs.push_back(Key(VK_CONTROL, true));
  }
  ::SendInput(static_cast<UINT>(inputs.size()), inputs.data(), static_cast<int>(sizeof(INPUT)));
}

}
