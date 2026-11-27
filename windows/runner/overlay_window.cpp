#include "overlay_window.h"

#include <windows.h>
#include <dwmapi.h>

#include <algorithm>
#include <cmath>

#include "bubble_layout.h"
#include "text_encoding.h"
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

constexpr wchar_t kTooltipClass[] = L"TranSnapOverlayTooltip";
constexpr double kTooltipFontSize = 12;
constexpr double kTooltipPaddingX = 16;
constexpr double kTooltipPaddingY = 8;
constexpr double kTooltipRadius = 8;
constexpr COLORREF kTooltipLightBackground = RGB(44, 44, 46);
constexpr COLORREF kTooltipLightText = RGB(255, 255, 255);
constexpr COLORREF kTooltipDarkBackground = RGB(229, 229, 234);
constexpr COLORREF kTooltipDarkText = RGB(28, 28, 30);

HFONT TooltipFont(double scale) {
  return ::CreateFontW(-Physical(kTooltipFontSize, scale), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                       DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                       DEFAULT_PITCH, L"Segoe UI");
}

LRESULT CALLBACK TooltipProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_PAINT) {
    auto* overlay = reinterpret_cast<OverlayWindow*>(::GetWindowLongPtrW(window, GWLP_USERDATA));
    if (overlay) {
      overlay->PaintTooltip();
      return 0;
    }
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
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
  WNDCLASSW tooltip_class{};
  tooltip_class.lpfnWndProc = TooltipProc;
  tooltip_class.hInstance = ::GetModuleHandleW(nullptr);
  tooltip_class.lpszClassName = kTooltipClass;
  ::RegisterClassW(&tooltip_class);
  tooltip_ = ::CreateWindowExW(
      WS_EX_NOACTIVATE | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_TRANSPARENT,
      kTooltipClass, L"", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr, tooltip_class.hInstance, nullptr);
  ::SetLayeredWindowAttributes(tooltip_, 0, 255, LWA_ALPHA);
  ::SetWindowLongPtrW(tooltip_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
}

OverlayWindow::~OverlayWindow() {
  if (tooltip_) {
    ::DestroyWindow(tooltip_);
  }
}

void OverlayWindow::ShowTooltip(const std::string& session_id, const std::string& message,
                                double x, double y, double width, double height,
                                bool prefer_above, bool dark) {
  if (session_ != session_id || !::IsWindowVisible(window_)) {
    return;
  }
  RECT overlay{};
  ::GetWindowRect(window_, &overlay);
  double scale = ::GetDpiForWindow(window_) / 96.0;
  tooltip_scale_ = scale;
  tooltip_text_ = Utf16FromUtf8(message);
  tooltip_dark_ = dark;
  HDC context = ::GetDC(tooltip_);
  HFONT font = TooltipFont(scale);
  HGDIOBJ previous = ::SelectObject(context, font);
  RECT measured{};
  ::DrawTextW(context, tooltip_text_.c_str(), -1, &measured, DT_CALCRECT | DT_SINGLELINE);
  ::SelectObject(context, previous);
  ::DeleteObject(font);
  ::ReleaseDC(tooltip_, context);
  double bubble_width = std::ceil(measured.right - measured.left + kTooltipPaddingX * scale);
  double bubble_height = std::ceil(measured.bottom - measured.top + kTooltipPaddingY * scale);
  MONITORINFO info{sizeof(info)};
  ::GetMonitorInfoW(::MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST), &info);
  bubble_layout::Rect anchor{overlay.left + x * scale, overlay.top + y * scale, width * scale,
                              height * scale};
  bubble_layout::Rect screen{static_cast<double>(info.rcWork.left),
                              static_cast<double>(info.rcWork.top),
                              static_cast<double>(info.rcWork.right - info.rcWork.left),
                              static_cast<double>(info.rcWork.bottom - info.rcWork.top)};
  bubble_layout::Rect frame =
      bubble_layout::Frame(bubble_width, bubble_height, anchor, screen, prefer_above, scale);
  int frame_width = static_cast<int>(frame.width);
  int frame_height = static_cast<int>(frame.height);
  int diameter = static_cast<int>(Physical(kTooltipRadius * 2, scale));
  ::SetWindowRgn(tooltip_,
                 ::CreateRoundRectRgn(0, 0, frame_width + 1, frame_height + 1, diameter, diameter),
                 FALSE);
  ::SetWindowPos(tooltip_, HWND_TOPMOST, static_cast<int>(frame.left), static_cast<int>(frame.top),
                 frame_width, frame_height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
  ::InvalidateRect(tooltip_, nullptr, TRUE);
}

void OverlayWindow::HideTooltip() {
  if (tooltip_ && ::IsWindowVisible(tooltip_)) {
    ::ShowWindow(tooltip_, SW_HIDE);
  }
}

void OverlayWindow::PaintTooltip() {
  PAINTSTRUCT paint{};
  HDC context = ::BeginPaint(tooltip_, &paint);
  RECT client{};
  ::GetClientRect(tooltip_, &client);
  HBRUSH background = ::CreateSolidBrush(tooltip_dark_ ? kTooltipDarkBackground : kTooltipLightBackground);
  ::FillRect(context, &client, background);
  ::DeleteObject(background);
  HFONT font = TooltipFont(tooltip_scale_);
  HGDIOBJ previous = ::SelectObject(context, font);
  ::SetBkMode(context, TRANSPARENT);
  ::SetTextColor(context, tooltip_dark_ ? kTooltipDarkText : kTooltipLightText);
  ::DrawTextW(context, tooltip_text_.c_str(), -1, &client, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  ::SelectObject(context, previous);
  ::DeleteObject(font);
  ::EndPaint(tooltip_, &paint);
}

void OverlayWindow::Show(const std::string& session_id, double x, double y, double width,
                         double height) {
  HideTooltip();
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
  HideTooltip();
  session_.reset();
  ::ShowWindow(window_, SW_HIDE);
}

void OverlayWindow::Resize(const std::string& session_id, double width, double height) {
  if (session_ != session_id) {
    return;
  }
  HideTooltip();
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
  HideTooltip();
  ::ReleaseCapture();
  ::SendMessageW(window_, WM_NCLBUTTONDOWN, HTCAPTION, 0);
}

bool OverlayWindow::Contains(long x, long y) const {
  RECT frame{};
  return ::IsWindowVisible(window_) && ::GetWindowRect(window_, &frame) &&
         ::PtInRect(&frame, POINT{x, y});
}
