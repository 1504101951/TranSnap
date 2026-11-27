#ifndef RUNNER_INPUT_BUBBLE_H_
#define RUNNER_INPUT_BUBBLE_H_

#include <functional>
#include <optional>
#include <string>

#include "bubble_layout.h"

struct HWND__;

class InputBubble {
 public:
  explicit InputBubble(std::function<bool()> dark);
  ~InputBubble();

  InputBubble(const InputBubble&) = delete;
  InputBubble& operator=(const InputBubble&) = delete;

  void ShowProgress(const bubble_layout::InputAnchor& anchor);
  void ShowFailure(const std::string& message, const bubble_layout::InputAnchor& anchor);
  void Close();
  void CloseProgress();

  void Paint();
  void Timer(unsigned long long id);
  void MouseMoved();
  void MouseLeft();

 private:
  enum class Kind { kNone, kProgress, kFailure };

  void Present(Kind kind, double width, double height, const bubble_layout::InputAnchor& anchor);

  std::function<bool()> dark_;
  HWND__* window_ = nullptr;
  Kind kind_ = Kind::kNone;
  std::optional<bubble_layout::InputAnchor> pending_anchor_;
  std::wstring message_;
  double scale_ = 1;
  int spinner_frame_ = 0;
  bool hovering_ = false;
};

#endif
