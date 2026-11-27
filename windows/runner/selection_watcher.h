#ifndef RUNNER_SELECTION_WATCHER_H_
#define RUNNER_SELECTION_WATCHER_H_

#include <functional>
#include <memory>

class SelectionWatcher {
 public:
  explicit SelectionWatcher(std::function<void()> changed);
  ~SelectionWatcher();

  SelectionWatcher(const SelectionWatcher&) = delete;
  SelectionWatcher& operator=(const SelectionWatcher&) = delete;

  void Watch(unsigned long process);
  void Stop();

 private:
  struct State;
  std::shared_ptr<State> state_;
  std::shared_ptr<char> alive_ = std::make_shared<char>();
  std::function<void()> changed_;
};

#endif
