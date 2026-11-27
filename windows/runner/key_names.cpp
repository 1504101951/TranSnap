#include "key_names.h"

#include <utility>

namespace key_names {
namespace {

constexpr std::pair<unsigned, const char*> kKeys[] = {
    {0x01, "Escape"}, {0x02, "Digit1"}, {0x03, "Digit2"}, {0x04, "Digit3"},
    {0x05, "Digit4"}, {0x06, "Digit5"}, {0x07, "Digit6"}, {0x08, "Digit7"},
    {0x09, "Digit8"}, {0x0A, "Digit9"}, {0x0B, "Digit0"}, {0x0C, "Minus"},
    {0x0D, "Equal"}, {0x0E, "Backspace"}, {0x0F, "Tab"}, {0x10, "KeyQ"},
    {0x11, "KeyW"}, {0x12, "KeyE"}, {0x13, "KeyR"}, {0x14, "KeyT"},
    {0x15, "KeyY"}, {0x16, "KeyU"}, {0x17, "KeyI"}, {0x18, "KeyO"},
    {0x19, "KeyP"}, {0x1A, "BracketLeft"}, {0x1B, "BracketRight"}, {0x1C, "Enter"},
    {0x1E, "KeyA"}, {0x1F, "KeyS"}, {0x20, "KeyD"}, {0x21, "KeyF"},
    {0x22, "KeyG"}, {0x23, "KeyH"}, {0x24, "KeyJ"}, {0x25, "KeyK"},
    {0x26, "KeyL"}, {0x27, "Semicolon"}, {0x28, "Quote"}, {0x29, "Backquote"},
    {0x2B, "Backslash"}, {0x2C, "KeyZ"}, {0x2D, "KeyX"}, {0x2E, "KeyC"},
    {0x2F, "KeyV"}, {0x30, "KeyB"}, {0x31, "KeyN"}, {0x32, "KeyM"},
    {0x33, "Comma"}, {0x34, "Period"}, {0x35, "Slash"}, {0x37, "NumpadMultiply"},
    {0x39, "Space"}, {0x3B, "F1"}, {0x3C, "F2"}, {0x3D, "F3"},
    {0x3E, "F4"}, {0x3F, "F5"}, {0x40, "F6"}, {0x41, "F7"},
    {0x42, "F8"}, {0x43, "F9"}, {0x44, "F10"}, {0x47, "Numpad7"},
    {0x48, "Numpad8"}, {0x49, "Numpad9"}, {0x4A, "NumpadSubtract"}, {0x4B, "Numpad4"},
    {0x4C, "Numpad5"}, {0x4D, "Numpad6"}, {0x4E, "NumpadAdd"}, {0x4F, "Numpad1"},
    {0x50, "Numpad2"}, {0x51, "Numpad3"}, {0x52, "Numpad0"}, {0x53, "NumpadDecimal"},
    {0x56, "IntlBackslash"}, {0x57, "F11"}, {0x58, "F12"}, {0x59, "NumpadEqual"},
    {0x64, "F13"}, {0x65, "F14"}, {0x66, "F15"}, {0x67, "F16"},
    {0x68, "F17"}, {0x69, "F18"}, {0x6A, "F19"}, {0x6B, "F20"},
    {0x71, "Lang2"}, {0x72, "Lang1"}, {0x73, "IntlRo"}, {0x7D, "IntlYen"},
    {0x7E, "NumpadComma"},
    {kExtended | 0x1C, "NumpadEnter"}, {kExtended | 0x20, "AudioVolumeMute"},
    {kExtended | 0x2E, "AudioVolumeDown"}, {kExtended | 0x30, "AudioVolumeUp"},
    {kExtended | 0x35, "NumpadDivide"}, {kExtended | 0x45, "NumLock"},
    {kExtended | 0x47, "Home"}, {kExtended | 0x48, "ArrowUp"},
    {kExtended | 0x49, "PageUp"}, {kExtended | 0x4B, "ArrowLeft"},
    {kExtended | 0x4D, "ArrowRight"}, {kExtended | 0x4F, "End"},
    {kExtended | 0x50, "ArrowDown"}, {kExtended | 0x51, "PageDown"},
    {kExtended | 0x52, "Insert"}, {kExtended | 0x53, "Delete"},
    {kExtended | 0x5D, "ContextMenu"},
};

constexpr char kSelectAll[] = "SelectAll";
constexpr unsigned kKeyA = 0x1E;

}

std::optional<std::string> Name(unsigned scan_code) {
  for (const auto& [code, name] : kKeys) {
    if (code == scan_code) {
      return name;
    }
  }
  return std::nullopt;
}

std::optional<unsigned> ScanCode(const std::string& name) {
  for (const auto& [code, key] : kKeys) {
    if (name == key) {
      return code;
    }
  }
  return std::nullopt;
}

std::vector<std::string> ModifierNames(const Modifiers& modifiers) {
  std::vector<std::string> names;
  if (modifiers.control) {
    names.push_back("control");
  }
  if (modifiers.alt) {
    names.push_back("alt");
  }
  if (modifiers.shift) {
    names.push_back("shift");
  }
  if (modifiers.meta) {
    names.push_back("meta");
  }
  return names;
}

std::optional<std::string> SelectionKey(unsigned scan_code, const Modifiers& modifiers) {
  if (scan_code == kKeyA && modifiers.control && !modifiers.alt && !modifiers.shift &&
      !modifiers.meta) {
    return kSelectAll;
  }
  return Name(scan_code);
}

}
