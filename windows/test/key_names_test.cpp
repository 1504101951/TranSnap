#include "key_names.h"

#include <gtest/gtest.h>

using key_names::kExtended;
using key_names::Modifiers;

TEST(KeyNames, ExtendedFlagSeparatesNavigationFromNumpadKeys) {
  EXPECT_EQ(key_names::Name(0x47), "Numpad7");
  EXPECT_EQ(key_names::Name(kExtended | 0x47), "Home");
  EXPECT_EQ(key_names::Name(0x1C), "Enter");
  EXPECT_EQ(key_names::Name(kExtended | 0x1C), "NumpadEnter");
  EXPECT_EQ(key_names::Name(kExtended | 0x4B), "ArrowLeft");
}

TEST(KeyNames, UnknownScanCodeHasNoName) {
  EXPECT_FALSE(key_names::Name(0x00).has_value());
  EXPECT_FALSE(key_names::Name(kExtended | 0x1E).has_value());
  EXPECT_FALSE(key_names::ScanCode("KeyÅ").has_value());
}

TEST(KeyNames, ScanCodeReversesName) {
  for (const char* name : {"KeyA", "Digit0", "F20", "Home", "NumpadEnter", "Escape"}) {
    auto code = key_names::ScanCode(name);
    ASSERT_TRUE(code.has_value()) << name;
    EXPECT_EQ(key_names::Name(*code), name);
  }
}

TEST(KeyNames, ModifierNamesFollowProtocolOrder) {
  EXPECT_EQ(key_names::ModifierNames({true, true, true, true}),
            (std::vector<std::string>{"control", "alt", "shift", "meta"}));
  EXPECT_TRUE(key_names::ModifierNames({}).empty());
}

TEST(KeyNames, OnlyControlAIsReportedAsSelectAll) {
  EXPECT_EQ(key_names::SelectionKey(0x1E, {true, false, false, false}), "SelectAll");
  EXPECT_EQ(key_names::SelectionKey(0x1E, {true, false, true, false}), "KeyA");
  EXPECT_EQ(key_names::SelectionKey(0x1E, {false, false, false, true}), "KeyA");
  EXPECT_EQ(key_names::SelectionKey(kExtended | 0x4F, {false, false, true, false}), "End");
}
