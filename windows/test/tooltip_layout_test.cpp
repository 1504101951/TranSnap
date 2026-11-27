#include "tooltip_layout.h"

#include <gtest/gtest.h>

using tooltip_layout::Frame;
using tooltip_layout::Rect;

namespace {

const Rect kScreen{0, 0, 1000, 800};

}

TEST(TooltipLayout, PrefersAboveWhenItFitsAndCentersOnAnchor) {
  Rect frame = Frame(100, 20, {450, 300, 100, 30}, kScreen, true, 1);
  EXPECT_DOUBLE_EQ(frame.left, 450);
  EXPECT_DOUBLE_EQ(frame.top, 300 - 6 - 20);
}

TEST(TooltipLayout, FallsBelowWhenAboveWouldLeaveTheInsetArea) {
  Rect frame = Frame(100, 20, {450, 31, 100, 30}, kScreen, true, 1);
  EXPECT_DOUBLE_EQ(frame.top, 31 + 30 + 6);
}

TEST(TooltipLayout, PrefersBelowAndFallsAboveNearTheBottomEdge) {
  EXPECT_DOUBLE_EQ(Frame(100, 20, {450, 300, 100, 30}, kScreen, false, 1).top, 336);
  EXPECT_DOUBLE_EQ(Frame(100, 20, {450, 750, 100, 30}, kScreen, false, 1).top, 750 - 6 - 20);
}

TEST(TooltipLayout, ClampsHorizontallyInsideTheInsetArea) {
  EXPECT_DOUBLE_EQ(Frame(100, 20, {0, 300, 20, 20}, kScreen, true, 1).left, 6);
  EXPECT_DOUBLE_EQ(Frame(100, 20, {980, 300, 20, 20}, kScreen, true, 1).left, 1000 - 6 - 100);
}

TEST(TooltipLayout, ScalesInsetAndGapWithDisplayScale) {
  Rect frame = Frame(200, 40, {900, 600, 200, 60}, {0, 0, 2000, 1600}, true, 2);
  EXPECT_DOUBLE_EQ(frame.top, 600 - 12 - 40);
  EXPECT_DOUBLE_EQ(frame.left, 900);
}
