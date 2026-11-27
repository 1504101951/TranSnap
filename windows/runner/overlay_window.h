#ifndef RUNNER_OVERLAY_WINDOW_H_
#define RUNNER_OVERLAY_WINDOW_H_

#include <optional>
#include <string>

struct HWND__;

class OverlayWindow {
 public:
  explicit OverlayWindow(HWND__* window);
  ~OverlayWindow();

  OverlayWindow(const OverlayWindow&) = delete;
  OverlayWindow& operator=(const OverlayWindow&) = delete;

  void Show(const std::string& session_id, double x, double y, double width, double height);
  void Hide(const std::string& session_id);
  void Resize(const std::string& session_id, double width, double height);
  void Drag(const std::string& session_id);
  bool Contains(long x, long y) const;
  void ShowTooltip(const std::string& session_id, const std::string& message, double x, double y,
                   double width, double height, bool prefer_above, bool dark);
  void HideTooltip();
  void PaintTooltip();

 private:
  HWND__* window_;
  HWND__* tooltip_ = nullptr;
  std::wstring tooltip_text_;
  bool tooltip_dark_ = false;
  double tooltip_scale_ = 1;
  std::optional<std::string> session_;
};

#endif
