#ifndef RUNNER_UIA_SELECTION_H_
#define RUNNER_UIA_SELECTION_H_

#include <optional>
#include <string>
#include <vector>

namespace uia_selection {

struct Read {
  std::optional<std::string> text;
  std::vector<std::string> context;
  bool secure = false;
};

unsigned long ForegroundProcess();

Read ReadSelection(unsigned long process);

bool FocusIsSecure(unsigned long process);

bool PermitsKeyboardTrigger(unsigned long process);

bool IsUsable(const std::optional<std::string>& text);

}

#endif
