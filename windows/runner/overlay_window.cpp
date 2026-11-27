#include "overlay_window.h"

#include <windows.h>
#include <dwmapi.h>

#include <algorithm>
#include <cmath>

#include "windows_system.h"

namespace {

constexpr double kCursorGap = 8;
constexpr double kScreenInset = 8;

RECT Clamp(RECT frame, HMONITOR monitor, double scale) {
  MONITORINFO info{sizeof(info)};
  ::GetMonitorInfoW(monitor, &info);
  LONG inset = static_cast<LONG>(std::lround(kScreenInset * scale));
  RECT visible{info.rcWork.left + inset, info.rcWork.top + inset, info.rcWork.right - inset,
               info.rcWork.bottom - inset};
  LONG width = frame.right - frame.left;
  LONG height = frame.bottom - frame.top;
  LONG left = std::min(std::max(frame.left, visible.left), std::max(visible.left, visible.right - width));
  LONG top = std::min(std::max(frame.top, visible.top), std::max(visible.top, visible.bottom - height));
  return {left, top, left + width, top + height};
}

LONG Physical(double logical, double scale) {
  return static_cast<LONG>(std::lround(logical * scale));
}

}

OverlayWindow::OverlayWindow(HWND__* window) : window_(window) {
  ::SetWindowLongPtrW(window_, GWL_STYLE, WS_POPUP);
  ::SetWindowLongPtrW(window_, GWL_EXSTYLE, WS_EX_NOACTIVATE | WS_EX_TOPMOST | WS_EX_TOOLWINDOW);
  DWM_WINDOW_CORNER_PREFERENCE corner = DWMWCP_ROUND;
  ::DwmSetWindowAttribute(window_, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof(corner));
  if (windows_system::SupportsAcrylic()) {
    windows_system::ApplyAcrylic(window_);
  }
  ::SetWindowPos(window_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
}

void OverlayWindow::Show(const std::string& session_id, double x, double y, double width,
                         double height) {
  session_ = session_id;
  windows_system::ScreenPoint point = windows_system::PhysicalPoint(x, y);
  POINT anchor{point.x, point.y};
  double scale = point.scale;
  HMONITOR monitor = ::MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST);
  LONG gap = Physical(kCursorGap, scale);
  RECT frame{anchor.x + gap, anchor.y + gap, anchor.x + gap + Physical(width, scale),
             anchor.y + gap + Physical(height, scale)};
  frame = Clamp(frame, monitor, scale);
  ::SetWindowPos(window_, HWND_TOPMOST, frame.left, frame.top, frame.right - frame.left,
                 frame.bottom - frame.top, SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

void OverlayWindow::Hide(const std::string& session_id) {
  if (session_ != session_id) {
    return;
  }
  session_.reset();
  ::ShowWindow(window_, SW_HIDE);
}

void OverlayWindow::Resize(const std::string& session_id, double width, double height) {
  if (session_ != session_id) {
    return;
  }
  RECT current{};
  ::GetWindowRect(window_, &current);
  HMONITOR monitor = ::MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
  double scale = ::GetDpiForWindow(window_) / 96.0;
  RECT frame{current.left, current.top, current.left + Physical(width, scale),
             current.top + Physical(height, scale)};
  frame = Clamp(frame, monitor, scale);
  ::SetWindowPos(window_, HWND_TOPMOST, frame.left, frame.top, frame.right - frame.left,
                 frame.bottom - frame.top, SWP_NOACTIVATE);
}

void OverlayWindow::Drag(const std::string& session_id) {
  if (session_ != session_id || !(::GetAsyncKeyState(VK_LBUTTON) & 0x8000)) {
    return;
  }
  ::ReleaseCapture();
  ::SendMessageW(window_, WM_NCLBUTTONDOWN, HTCAPTION, 0);
}

bool OverlayWindow::Contains(long x, long y) const {
  RECT frame{};
  return ::IsWindowVisible(window_) && ::GetWindowRect(window_, &frame) &&
         ::PtInRect(&frame, POINT{x, y});
}
