#ifndef RUNNER_SHORTCUT_RULES_H_
#define RUNNER_SHORTCUT_RULES_H_

#include <optional>
#include <string>
#include <vector>

#include "key_names.h"

namespace shortcut_rules {

struct Shortcut {
  unsigned scan_code;
  key_names::Modifiers modifiers;
};

struct Purpose {
  const char* preference_key;
  const char* title;
  const char* gesture;
};

inline constexpr Purpose kPurposes[] = {
    {"shortcut", "全局翻译快捷键", "hotkey"},
    {"inputShortcut", "输入翻译快捷键", "inputHotkey"},
};

inline constexpr char kDuplicateMessage[] = "全局翻译与输入翻译快捷键不能相同。";

std::optional<Shortcut> Parse(const std::string& key, const std::vector<std::string>& modifiers,
                              std::string& error);

bool Same(const Shortcut& left, const Shortcut& right);

}

#endif
