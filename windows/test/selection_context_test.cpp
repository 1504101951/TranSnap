#include "selection_context.h"

#include <gtest/gtest.h>

TEST(SelectionContext, ChromiumAndGeckoDocumentsAreWebContent) {
  EXPECT_STREQ(selection_context::Kind(50030, L"Chrome"), "web");
  EXPECT_STREQ(selection_context::Kind(50030, L"Gecko"), "web");
  EXPECT_STREQ(selection_context::Kind(50030, L"Win32"), "text");
}

TEST(SelectionContext, ControlTypesMapToTextNonTextOrOther) {
  EXPECT_STREQ(selection_context::Kind(50004, L"Chrome"), "text");
  EXPECT_STREQ(selection_context::Kind(50003, L"WPF"), "text");
  EXPECT_STREQ(selection_context::Kind(50000, L"Win32"), "nonText");
  EXPECT_STREQ(selection_context::Kind(50029, L"WPF"), "nonText");
  EXPECT_STREQ(selection_context::Kind(50020, L"Win32"), "other");
  EXPECT_STREQ(selection_context::Kind(50033, L"Chrome"), "other");
}

TEST(SelectionContext, NearestTextOrNonTextAncestorDecidesReading) {
  EXPECT_TRUE(selection_context::ShouldReadSelectedText({}));
  EXPECT_TRUE(selection_context::ShouldReadSelectedText({"other", "other"}));
  EXPECT_TRUE(selection_context::ShouldReadSelectedText({"other", "web", "nonText"}));
  EXPECT_FALSE(selection_context::ShouldReadSelectedText({"other", "nonText", "text"}));
}
