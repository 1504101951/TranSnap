#ifndef RUNNER_TOOLTIP_LAYOUT_H_
#define RUNNER_TOOLTIP_LAYOUT_H_

namespace tooltip_layout {

struct Rect {
  double left;
  double top;
  double width;
  double height;
};

Rect Frame(double width, double height, const Rect& anchor, const Rect& screen, bool prefer_above,
           double scale);

}

#endif
