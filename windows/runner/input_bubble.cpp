#include "input_bubble.h"

#include <flutter_windows.h>
#include <windows.h>

#include <algorithm>
#include <cmath>

#include "text_encoding.h"


namespace {

constexpr wchar_t kWindowClass[] = L"TranSnapInputBubble";
constexpr wchar_t kProgressText[] = L"翻译中…";
constexpr wchar_t kWarningGlyph[] = L"";
constexpr UINT_PTR kDelayTimer = 1;
constexpr UINT_PTR kSpinnerTimer = 2;
constexpr UINT_PTR kDismissTimer = 3;
constexpr UINT kProgressDelayMs = 300;
constexpr UINT kSpinnerIntervalMs = 80;
constexpr UINT kFailureDurationMs = 2000;
constexpr int kSpinnerSpokes = 8;
constexpr double kProgressFontSize = 13;
constexpr double kProgressHeight = 24;
constexpr double kProgressRadius = 12;
constexpr double kProgressPaddingX = 10;
constexpr double kSpinnerSize = 12;
constexpr double kProgressSpacing = 6;
constexpr double kFailurePaddingX = 12;
constexpr double kFailurePaddingY = 5;
constexpr double kFailureMaxWidth = 240;
constexpr double kFailureRadius = 8;
constexpr double kFailureIconSize = 14;
constexpr double kFailureIconSpacing = 6;
constexpr double kFailureLineHeight = 18;
constexpr COLORREF kDarkSurface = RGB(0x17, 0x17, 0x17);
constexpr COLORREF kLightSurface = RGB(0xF7, 0xF7, 0xF7);
constexpr COLORREF kDarkLabel = RGB(0xFF, 0xFF, 0xFF);
constexpr COLORREF kLightLabel = RGB(0x1C, 0x1C, 0x1E);
constexpr COLORREF kDarkError = RGB(0xFF, 0x45, 0x3A);
constexpr COLORREF kLightError = RGB(0xFF, 0x3B, 0x30);

int Physical(double logical, double scale) {
  return static_cast<int>(std::lround(logical * scale));
}

HFONT Font(double size, double scale, const wchar_t* face) {
  return ::CreateFontW(-Physical(size, scale), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                       DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                       DEFAULT_PITCH, face);
}

SIZE Measure(HWND window, const std::wstring& text, HFONT font, int max_width) {
  HDC context = ::GetDC(window);
  HGDIOBJ previous = ::SelectObject(context, font);
  RECT bounds{0, 0, max_width, 0};
  UINT flags = DT_CALCRECT | (max_width > 0 ? DT_WORDBREAK : DT_SINGLELINE);
  ::DrawTextW(context, text.c_str(), -1, &bounds, flags);
  ::SelectObject(context, previous);
  ::ReleaseDC(window, context);
  return {bounds.right - bounds.left, bounds.bottom - bounds.top};
}

double Scale(const bubble_layout::InputAnchor& anchor) {
  POINT corner{static_cast<LONG>(anchor.selection.left), static_cast<LONG>(anchor.selection.top)};
  return FlutterDesktopGetDpiForMonitor(::MonitorFromPoint(corner, MONITOR_DEFAULTTONEAREST)) / 96.0;
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* bubble = reinterpret_cast<InputBubble*>(::GetWindowLongPtrW(window, GWLP_USERDATA));
  if (!bubble) {
    return ::DefWindowProcW(window, message, wparam, lparam);
  }
  switch (message) {
    case WM_PAINT:
      bubble->Paint();
      return 0;
    case WM_TIMER:
      bubble->Timer(wparam);
      return 0;
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_MOUSEMOVE:
      bubble->MouseMoved();
      return 0;
    case WM_MOUSELEAVE:
      bubble->MouseLeft();
      return 0;
    case WM_LBUTTONUP:
      bubble->Close();
      return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

}

InputBubble::InputBubble(std::function<bool()> dark) : dark_(std::move(dark)) {
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = kWindowClass;
  window_class.hCursor = ::LoadCursorW(nullptr, IDC_HAND);
  ::RegisterClassW(&window_class);
  window_ = ::CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED,
                              kWindowClass, L"", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr,
                              window_class.hInstance, nullptr);
  ::SetLayeredWindowAttributes(window_, 0, 255, LWA_ALPHA);
  ::SetWindowLongPtrW(window_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
}

InputBubble::~InputBubble() {
  ::DestroyWindow(window_);
}

void InputBubble::ShowProgress(const bubble_layout::InputAnchor& anchor) {
  Close();
  pending_anchor_ = anchor;
  ::SetTimer(window_, kDelayTimer, kProgressDelayMs, nullptr);
}

void InputBubble::ShowFailure(const std::string& message, const bubble_layout::InputAnchor& anchor) {
  Close();
  message_ = Utf16FromUtf8(message);
  scale_ = Scale(anchor);
  int max_text = Physical(kFailureMaxWidth - kFailurePaddingX * 2 - kFailureIconSize - kFailureIconSpacing,
                          scale_);
  HFONT font = Font(kProgressFontSize, scale_, L"Segoe UI");
  SIZE text = Measure(window_, message_, font, max_text);
  ::DeleteObject(font);
  double text_width = std::min<double>(text.cx, max_text) / scale_;
  double text_height = std::max(kFailureLineHeight, text.cy / scale_);
  double body = std::max(kFailureIconSize, text_height);
  Present(Kind::kFailure,
          std::ceil(kFailurePaddingX * 2 + kFailureIconSize + kFailureIconSpacing + text_width),
          std::ceil(kFailurePaddingY * 2 + body), anchor);
  ::SetTimer(window_, kDismissTimer, kFailureDurationMs, nullptr);
}

void InputBubble::Close() {
  ::KillTimer(window_, kDelayTimer);
  ::KillTimer(window_, kSpinnerTimer);
  ::KillTimer(window_, kDismissTimer);
  pending_anchor_.reset();
  kind_ = Kind::kNone;
  hovering_ = false;
  ::ShowWindow(window_, SW_HIDE);
}

void InputBubble::CloseProgress() {
  if (kind_ != Kind::kFailure) {
    Close();
  }
}

void InputBubble::Present(Kind kind, double width, double height, const bubble_layout::InputAnchor& anchor) {
  kind_ = kind;
  POINT corner{static_cast<LONG>(anchor.selection.left), static_cast<LONG>(anchor.selection.top)};
  MONITORINFO info{sizeof(info)};
  ::GetMonitorInfoW(::MonitorFromPoint(corner, MONITOR_DEFAULTTONEAREST), &info);
  bubble_layout::Rect visible{static_cast<double>(info.rcWork.left),
                              static_cast<double>(info.rcWork.top),
                              static_cast<double>(info.rcWork.right - info.rcWork.left),
                              static_cast<double>(info.rcWork.bottom - info.rcWork.top)};
  bubble_layout::Rect area =
      bubble_layout::AvailableArea(visible, anchor.window ? &*anchor.window : nullptr);
  bubble_layout::Rect frame = bubble_layout::InputFrame(width * scale_, height * scale_,
                                                        anchor.selection, area, scale_);
  int frame_width = static_cast<int>(std::ceil(frame.width));
  int frame_height = static_cast<int>(std::ceil(frame.height));
  int diameter = Physical((kind == Kind::kProgress ? kProgressRadius : kFailureRadius) * 2, scale_);
  LONG_PTR style = ::GetWindowLongPtrW(window_, GWL_EXSTYLE);
  style = kind == Kind::kProgress ? (style | WS_EX_TRANSPARENT) : (style & ~WS_EX_TRANSPARENT);
  ::SetWindowLongPtrW(window_, GWL_EXSTYLE, style);
  ::SetWindowRgn(window_,
                 ::CreateRoundRectRgn(0, 0, frame_width + 1, frame_height + 1, diameter, diameter),
                 FALSE);
  ::SetWindowPos(window_, HWND_TOPMOST, static_cast<int>(frame.left), static_cast<int>(frame.top),
                 frame_width, frame_height, SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_FRAMECHANGED);
  ::InvalidateRect(window_, nullptr, TRUE);
}

void InputBubble::Timer(unsigned long long id) {
  if (id == kDelayTimer) {
    ::KillTimer(window_, kDelayTimer);
    if (!pending_anchor_) {
      return;
    }
    bubble_layout::InputAnchor anchor = *pending_anchor_;
    pending_anchor_.reset();
    scale_ = Scale(anchor);
    HFONT font = Font(kProgressFontSize, scale_, L"Segoe UI");
    SIZE text = Measure(window_, kProgressText, font, 0);
    ::DeleteObject(font);
    Present(Kind::kProgress,
            std::ceil(kProgressPaddingX * 2 + kSpinnerSize + kProgressSpacing + text.cx / scale_),
            kProgressHeight, anchor);
    spinner_frame_ = 0;
    ::SetTimer(window_, kSpinnerTimer, kSpinnerIntervalMs, nullptr);
    return;
  }
  if (id == kSpinnerTimer) {
    spinner_frame_ = (spinner_frame_ + 1) % kSpinnerSpokes;
    ::InvalidateRect(window_, nullptr, FALSE);
    return;
  }
  if (id == kDismissTimer && !hovering_) {
    Close();
  }
}

void InputBubble::MouseMoved() {
  if (kind_ != Kind::kFailure || hovering_) {
    return;
  }
  hovering_ = true;
  ::KillTimer(window_, kDismissTimer);
  TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE, window_, 0};
  ::TrackMouseEvent(&track);
}

void InputBubble::MouseLeft() {
  hovering_ = false;
  if (kind_ == Kind::kFailure) {
    ::SetTimer(window_, kDismissTimer, kFailureDurationMs, nullptr);
  }
}

void InputBubble::Paint() {
  PAINTSTRUCT paint{};
  HDC context = ::BeginPaint(window_, &paint);
  RECT client{};
  ::GetClientRect(window_, &client);
  bool dark = dark_();
  HBRUSH surface = ::CreateSolidBrush(dark ? kDarkSurface : kLightSurface);
  ::FillRect(context, &client, surface);
  ::DeleteObject(surface);
  ::SetBkMode(context, TRANSPARENT);
  COLORREF label = dark ? kDarkLabel : kLightLabel;
  if (kind_ == Kind::kProgress) {
    int size = Physical(kSpinnerSize, scale_);
    int center_x = Physical(kProgressPaddingX, scale_) + size / 2;
    int center_y = (client.bottom - client.top) / 2;
    for (int spoke = 0; spoke < kSpinnerSpokes; ++spoke) {
      double angle = (spoke * 2 * 3.14159265358979) / kSpinnerSpokes;
      int age = (spinner_frame_ - spoke + kSpinnerSpokes) % kSpinnerSpokes;
      int fade = 255 - age * 24;
      COLORREF color = dark ? RGB(fade, fade, fade) : RGB(255 - fade, 255 - fade, 255 - fade);
      HPEN pen = ::CreatePen(PS_SOLID, std::max(1, Physical(1.5, scale_)), color);
      HGDIOBJ previous = ::SelectObject(context, pen);
      ::MoveToEx(context, center_x + static_cast<int>(std::cos(angle) * size * 0.22),
                 center_y + static_cast<int>(std::sin(angle) * size * 0.22), nullptr);
      ::LineTo(context, center_x + static_cast<int>(std::cos(angle) * size * 0.5),
               center_y + static_cast<int>(std::sin(angle) * size * 0.5));
      ::SelectObject(context, previous);
      ::DeleteObject(pen);
    }
    HFONT font = Font(kProgressFontSize, scale_, L"Segoe UI");
    HGDIOBJ previous = ::SelectObject(context, font);
    ::SetTextColor(context, label);
    RECT text = client;
    text.left = Physical(kProgressPaddingX + kSpinnerSize + kProgressSpacing, scale_);
    ::DrawTextW(context, kProgressText, -1, &text, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    ::SelectObject(context, previous);
    ::DeleteObject(font);
  }
  if (kind_ == Kind::kFailure) {
    COLORREF error = dark ? kDarkError : kLightError;
    HFONT icon_font = Font(kFailureIconSize, scale_, L"Segoe MDL2 Assets");
    HGDIOBJ previous = ::SelectObject(context, icon_font);
    ::SetTextColor(context, error);
    RECT icon{Physical(kFailurePaddingX, scale_), client.top,
              Physical(kFailurePaddingX + kFailureIconSize, scale_), client.bottom};
    ::DrawTextW(context, kWarningGlyph, -1, &icon, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    HFONT font = Font(kProgressFontSize, scale_, L"Segoe UI");
    ::SelectObject(context, font);
    RECT text{icon.right + Physical(kFailureIconSpacing, scale_), 0,
              client.right - Physical(kFailurePaddingX, scale_), 0};
    ::DrawTextW(context, message_.c_str(), -1, &text, DT_CALCRECT | DT_WORDBREAK);
    int text_height = text.bottom - text.top;
    text.top = (client.bottom - text_height) / 2;
    text.bottom = text.top + text_height;
    text.right = client.right - Physical(kFailurePaddingX, scale_);
    ::DrawTextW(context, message_.c_str(), -1, &text, DT_LEFT | DT_WORDBREAK);
    ::SelectObject(context, previous);
    ::DeleteObject(font);
    ::DeleteObject(icon_font);
  }
  ::EndPaint(window_, &paint);
}
