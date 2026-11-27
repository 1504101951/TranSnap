#include "shortcut_rules.h"

#include <algorithm>
#include <iterator>

namespace shortcut_rules {
namespace {

constexpr char kInvalidMessage[] = "快捷键至少需要 Ctrl、Alt 或 Win，并搭配一个非 Esc 按键。";
constexpr char kTextEditingMessage[] =
    "这个组合是全选、撤销、重做、剪切、复制或粘贴快捷键，请换一个组合。";
constexpr const char* kTextEditingKeys[] = {"KeyA", "KeyZ", "KeyY", "KeyX", "KeyC", "KeyV"};
constexpr const char* kModifierNames[] = {"control", "alt", "shift", "meta"};

}

std::optional<Shortcut> Parse(const std::string& key, const std::vector<std::string>& modifiers,
                              std::string& error) {
  auto scan_code = key_names::ScanCode(key);
  bool known_modifiers = std::all_of(modifiers.begin(), modifiers.end(), [](const std::string& name) {
    return std::find(std::begin(kModifierNames), std::end(kModifierNames), name) !=
           std::end(kModifierNames);
  });
  auto has = [&](const char* name) {
    return std::find(modifiers.begin(), modifiers.end(), name) != modifiers.end();
  };
  key_names::Modifiers parsed{has("control"), has("alt"), has("shift"), has("meta")};
  if (!scan_code || key == "Escape" || !known_modifiers ||
      !(parsed.control || parsed.alt || parsed.meta)) {
    error = kInvalidMessage;
    return std::nullopt;
  }
  bool control_only = parsed.control && !parsed.alt && !parsed.meta;
  if (control_only && std::find(std::begin(kTextEditingKeys), std::end(kTextEditingKeys), key) !=
                          std::end(kTextEditingKeys)) {
    error = kTextEditingMessage;
    return std::nullopt;
  }
  return Shortcut{*scan_code, parsed};
}

bool Same(const Shortcut& left, const Shortcut& right) {
  return left.scan_code == right.scan_code && left.modifiers.control == right.modifiers.control &&
         left.modifiers.alt == right.modifiers.alt && left.modifiers.shift == right.modifiers.shift &&
         left.modifiers.meta == right.modifiers.meta;
}

}
