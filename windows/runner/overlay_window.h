#ifndef RUNNER_OVERLAY_WINDOW_H_
#define RUNNER_OVERLAY_WINDOW_H_

#include <optional>
#include <string>

struct HWND__;

class OverlayWindow {
 public:
  explicit OverlayWindow(HWND__* window);

  void Show(const std::string& session_id, double x, double y, double width, double height);
  void Hide(const std::string& session_id);
  void Resize(const std::string& session_id, double width, double height);
  void Drag(const std::string& session_id);
  bool Contains(long x, long y) const;

 private:
  HWND__* window_;
  std::optional<std::string> session_;
};

#endif
