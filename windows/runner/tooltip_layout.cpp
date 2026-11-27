#include "tooltip_layout.h"

#include <algorithm>
#include <cmath>

namespace tooltip_layout {
namespace {

constexpr double kInset = 6;
constexpr double kGap = 6;

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

}
