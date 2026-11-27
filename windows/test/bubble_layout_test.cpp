#include "bubble_layout.h"

#include <gtest/gtest.h>

using bubble_layout::AvailableArea;
using bubble_layout::Frame;
using bubble_layout::InputFrame;
using bubble_layout::Rect;

namespace {

const Rect kScreen{0, 0, 1000, 800};

}

TEST(BubbleLayout, PrefersAboveWhenItFitsAndCentersOnAnchor) {
  Rect frame = Frame(100, 20, {450, 300, 100, 30}, kScreen, true, 1);
  EXPECT_DOUBLE_EQ(frame.left, 450);
  EXPECT_DOUBLE_EQ(frame.top, 300 - 6 - 20);
}

TEST(BubbleLayout, FallsBelowWhenAboveWouldLeaveTheInsetArea) {
  Rect frame = Frame(100, 20, {450, 31, 100, 30}, kScreen, true, 1);
  EXPECT_DOUBLE_EQ(frame.top, 31 + 30 + 6);
}

TEST(BubbleLayout, PrefersBelowAndFallsAboveNearTheBottomEdge) {
  EXPECT_DOUBLE_EQ(Frame(100, 20, {450, 300, 100, 30}, kScreen, false, 1).top, 336);
  EXPECT_DOUBLE_EQ(Frame(100, 20, {450, 750, 100, 30}, kScreen, false, 1).top, 750 - 6 - 20);
}

TEST(BubbleLayout, ClampsHorizontallyInsideTheInsetArea) {
  EXPECT_DOUBLE_EQ(Frame(100, 20, {0, 300, 20, 20}, kScreen, true, 1).left, 6);
  EXPECT_DOUBLE_EQ(Frame(100, 20, {980, 300, 20, 20}, kScreen, true, 1).left, 1000 - 6 - 100);
}

TEST(BubbleLayout, ScalesInsetAndGapWithDisplayScale) {
  Rect frame = Frame(200, 40, {900, 600, 200, 60}, {0, 0, 2000, 1600}, true, 2);
  EXPECT_DOUBLE_EQ(frame.top, 600 - 12 - 40);
  EXPECT_DOUBLE_EQ(frame.left, 900);
}

TEST(BubbleLayout, InputBubbleGoesBelowThenAboveThenPinsToBottom) {
  Rect area{0, 0, 1000, 800};
  EXPECT_DOUBLE_EQ(InputFrame(200, 24, {100, 300, 50, 20}, area, 1).top, 328);
  EXPECT_DOUBLE_EQ(InputFrame(200, 24, {100, 770, 50, 20}, area, 1).top, 770 - 8 - 24);
  EXPECT_DOUBLE_EQ(InputFrame(200, 790, {100, 400, 50, 20}, area, 1).top, 10);
}

TEST(BubbleLayout, InputBubbleAlignsLeftEdgeInsideTheArea) {
  Rect area{0, 0, 1000, 800};
  EXPECT_DOUBLE_EQ(InputFrame(200, 24, {100, 300, 50, 20}, area, 1).left, 100);
  EXPECT_DOUBLE_EQ(InputFrame(200, 24, {900, 300, 50, 20}, area, 1).left, 800);
  EXPECT_DOUBLE_EQ(InputFrame(200, 24, {-40, 300, 50, 20}, area, 1).left, 0);
}

TEST(BubbleLayout, AvailableAreaIsWindowOverlapOrWholeScreen) {
  Rect visible{0, 0, 1000, 800};
  Rect window{900, 700, 400, 400};
  Rect overlap = AvailableArea(visible, &window);
  EXPECT_DOUBLE_EQ(overlap.left, 900);
  EXPECT_DOUBLE_EQ(overlap.width, 100);
  EXPECT_DOUBLE_EQ(overlap.height, 100);
  Rect outside{1200, 0, 100, 100};
  EXPECT_DOUBLE_EQ(AvailableArea(visible, &outside).width, 1000);
  EXPECT_DOUBLE_EQ(AvailableArea(visible, nullptr).height, 800);
}
