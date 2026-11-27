#ifndef RUNNER_KEY_NAMES_H_
#define RUNNER_KEY_NAMES_H_

#include <optional>
#include <string>
#include <vector>

namespace key_names {

inline constexpr unsigned kExtended = 0xE000;

struct Modifiers {
  bool control = false;
  bool alt = false;
  bool shift = false;
  bool meta = false;
};

std::optional<std::string> Name(unsigned scan_code);

std::optional<unsigned> ScanCode(const std::string& name);

std::vector<std::string> ModifierNames(const Modifiers& modifiers);

std::optional<std::string> SelectionKey(unsigned scan_code, const Modifiers& modifiers);

}

#endif
