#include "shortcut_rules.h"

#include <gtest/gtest.h>

namespace {

std::optional<shortcut_rules::Shortcut> Parse(const std::string& key,
                                              const std::vector<std::string>& modifiers,
                                              std::string& error) {
  error.clear();
  return shortcut_rules::Parse(key, modifiers, error);
}

}

TEST(ShortcutRules, AcceptsKeyWithControlAltOrWin) {
  std::string error;
  auto shortcut = Parse("KeyT", {"control", "alt"}, error);
  ASSERT_TRUE(shortcut.has_value()) << error;
  EXPECT_EQ(shortcut->scan_code, 0x14u);
  EXPECT_TRUE(shortcut->modifiers.control && shortcut->modifiers.alt);
  EXPECT_TRUE(Parse("F2", {"meta"}, error).has_value()) << error;
  EXPECT_TRUE(Parse("Home", {"alt", "shift"}, error).has_value()) << error;
}

TEST(ShortcutRules, RejectsShiftOnlyEscapeAndUnknownNames) {
  std::string error;
  EXPECT_FALSE(Parse("KeyT", {"shift"}, error).has_value());
  EXPECT_EQ(error, "快捷键至少需要 Ctrl、Alt 或 Win，并搭配一个非 Esc 按键。");
  EXPECT_FALSE(Parse("Escape", {"control"}, error).has_value());
  EXPECT_FALSE(Parse("KeyT", {"control", "hyper"}, error).has_value());
  EXPECT_FALSE(Parse("Unknown", {"control"}, error).has_value());
}

TEST(ShortcutRules, ReservesControlTextEditingCombinations) {
  std::string error;
  for (const char* key : {"KeyA", "KeyZ", "KeyY", "KeyX", "KeyC", "KeyV"}) {
    EXPECT_FALSE(Parse(key, {"control"}, error).has_value()) << key;
    EXPECT_EQ(error, "这个组合是全选、撤销、重做、剪切、复制或粘贴快捷键，请换一个组合。");
    EXPECT_FALSE(Parse(key, {"control", "shift"}, error).has_value()) << key;
  }
  EXPECT_TRUE(Parse("KeyC", {"control", "alt"}, error).has_value()) << error;
  EXPECT_TRUE(Parse("KeyB", {"control"}, error).has_value()) << error;
}

TEST(ShortcutRules, SameComparesKeyAndEveryModifier) {
  std::string error;
  auto first = *Parse("KeyT", {"control", "alt"}, error);
  EXPECT_TRUE(shortcut_rules::Same(first, *Parse("KeyT", {"alt", "control"}, error)));
  EXPECT_FALSE(shortcut_rules::Same(first, *Parse("KeyT", {"control", "alt", "shift"}, error)));
  EXPECT_FALSE(shortcut_rules::Same(first, *Parse("KeyR", {"control", "alt"}, error)));
}
