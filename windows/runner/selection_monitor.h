#ifndef RUNNER_SELECTION_MONITOR_H_
#define RUNNER_SELECTION_MONITOR_H_

#include <flutter/encodable_value.h>

#include <deque>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

struct HHOOK__;

class SelectionMonitor {
 public:
  using Reply = std::function<void(const flutter::EncodableValue* value)>;

  struct Delegate {
    std::function<void(const char* method, flutter::EncodableValue arguments, Reply reply)> request;
    std::function<bool()> automatic;
    std::function<void(const std::string& gesture)> capture;
    std::function<void(const char* event_type)> invalidate;
    std::function<void()> validate;
  };

  explicit SelectionMonitor(Delegate delegate);
  ~SelectionMonitor();

  SelectionMonitor(const SelectionMonitor&) = delete;
  SelectionMonitor& operator=(const SelectionMonitor&) = delete;

  void HandleMouse(bool down, long x, long y, unsigned long time);
  void HandleKey(bool down, unsigned scan_code);

 private:
  struct KeyEvent {
    bool down;
    unsigned scan_code;
    std::optional<std::string> name;
    std::vector<std::string> modifiers;
    unsigned generation;
  };

  void ClearPendingKey();
  void DrainKeys();

  Delegate delegate_;
  HHOOK__* mouse_hook_ = nullptr;
  HHOOK__* keyboard_hook_ = nullptr;
  std::shared_ptr<char> alive_ = std::make_shared<char>();
  unsigned pointer_generation_ = 0;
  unsigned key_generation_ = 0;
  bool ignore_mouse_ = false;
  int click_count_ = 0;
  long last_down_x_ = 0;
  long last_down_y_ = 0;
  unsigned long last_down_time_ = 0;
  std::optional<std::pair<unsigned, std::string>> pending_key_;
  std::deque<KeyEvent> key_events_;
  bool key_request_in_flight_ = false;
};

#endif
