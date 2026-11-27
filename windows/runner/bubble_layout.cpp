#include "bubble_layout.h"

#include <algorithm>
#include <cmath>

namespace bubble_layout {
namespace {

constexpr double kInset = 6;
constexpr double kGap = 6;
constexpr double kInputGap = 8;

}

Rect Frame(double width, double height, const Rect& anchor, const Rect& screen, bool prefer_above,
           double scale) {
  double inset = kInset * scale;
  double gap = kGap * scale;
  double area_top = screen.top + inset;
  double area_bottom = screen.top + screen.height - inset;
  double area_left = screen.left + inset;
  double area_right = screen.left + screen.width - inset;
  double above = anchor.top - gap - height;
  double below = anchor.top + anchor.height + gap;
  double top = prefer_above ? (above >= area_top ? above : std::min(area_bottom - height, below))
                            : (below + height <= area_bottom ? below : std::max(area_top, above));
  double centered = anchor.left + anchor.width / 2 - width / 2;
  double left = std::min(std::max(centered, area_left), std::max(area_left, area_right - width));
  return {std::round(left), std::round(top), width, height};
}

Rect AvailableArea(const Rect& visible, const Rect* window) {
  if (!window) {
    return visible;
  }
  double left = std::max(visible.left, window->left);
  double top = std::max(visible.top, window->top);
  double right = std::min(visible.left + visible.width, window->left + window->width);
  double bottom = std::min(visible.top + visible.height, window->top + window->height);
  if (right <= left || bottom <= top) {
    return visible;
  }
  return {left, top, right - left, bottom - top};
}

Rect InputFrame(double width, double height, const Rect& anchor, const Rect& area, double scale) {
  double gap = kInputGap * scale;
  double area_bottom = area.top + area.height;
  double below = anchor.top + anchor.height + gap;
  double above = anchor.top - gap - height;
  double top = below + height <= area_bottom ? below
               : above >= area.top           ? above
                                             : std::max(area.top, area_bottom - height);
  double left = std::min(std::max(anchor.left, area.left), area.left + area.width - width);
  return {std::round(left), std::round(top), width, height};
}

}
