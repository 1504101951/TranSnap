#ifndef RUNNER_BUBBLE_LAYOUT_H_
#define RUNNER_BUBBLE_LAYOUT_H_

#include <optional>

namespace bubble_layout {

struct Rect {
  double left;
  double top;
  double width;
  double height;
};

struct InputAnchor {
  Rect selection;
  std::optional<Rect> window;
};

Rect Frame(double width, double height, const Rect& anchor, const Rect& screen, bool prefer_above,
           double scale);

Rect AvailableArea(const Rect& visible, const Rect* window);

Rect InputFrame(double width, double height, const Rect& anchor, const Rect& area, double scale);

}

#endif
