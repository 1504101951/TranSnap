#ifndef RUNNER_GLOBAL_HOTKEYS_H_
#define RUNNER_GLOBAL_HOTKEYS_H_

#include <functional>
#include <string>
#include <vector>

#include "shortcut_rules.h"

struct HWND__;

class GlobalHotkeys {
 public:
  struct Request {
    const shortcut_rules::Purpose* purpose;
    shortcut_rules::Shortcut shortcut;
  };

  explicit GlobalHotkeys(std::function<void(const std::string& gesture)> pressed);
  ~GlobalHotkeys();

  GlobalHotkeys(const GlobalHotkeys&) = delete;
  GlobalHotkeys& operator=(const GlobalHotkeys&) = delete;

  bool Apply(const std::vector<Request>& requests, std::string& error);
  void Pressed(int id);

 private:
  struct Registered {
    int id;
    const shortcut_rules::Purpose* purpose;
    shortcut_rules::Shortcut shortcut;
  };

  std::function<void(const std::string& gesture)> pressed_;
  HWND__* window_ = nullptr;
  std::vector<Registered> registered_;
  int next_id_ = 1;
};

#endif
