#include "preferences_store.h"

#include <gtest/gtest.h>

#include <fstream>

using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

std::filesystem::path TemporaryDirectory(const char* name) {
  auto directory = std::filesystem::temp_directory_path() / "transnap-tests" / name;
  std::filesystem::remove_all(directory);
  return directory;
}

}

TEST(PreferencesStore, MissingFileLoadsAsEmptyPreferences) {
  std::string error;
  auto loaded = preferences_store::Load(TemporaryDirectory("missing") / "preferences.json", error);
  ASSERT_TRUE(loaded.has_value());
  EXPECT_TRUE(loaded->empty());
}

TEST(PreferencesStore, SaveCreatesDirectoryAndLoadsBackTheSameValues) {
  auto file = TemporaryDirectory("round-trip") / "nested" / "preferences.json";
  EncodableMap preferences{
      {EncodableValue("primaryLanguage"), EncodableValue("zh-CN")},
      {EncodableValue("glassOpacity"), EncodableValue(0.8)},
  };
  std::string error;
  ASSERT_TRUE(preferences_store::Save(file, preferences, error)) << error;
  EXPECT_FALSE(std::filesystem::exists(file.string() + ".tmp"));
  auto loaded = preferences_store::Load(file, error);
  ASSERT_TRUE(loaded.has_value());
  EXPECT_EQ(*loaded, preferences);
}

TEST(PreferencesStore, MalformedOrNonObjectFileReportsInvalidFormat) {
  auto directory = TemporaryDirectory("malformed");
  std::filesystem::create_directories(directory);
  for (const char* content : {"{\"primaryLanguage\":", "[1,2]"}) {
    auto file = directory / "preferences.json";
    std::ofstream(file, std::ios::binary | std::ios::trunc) << content;
    std::string error;
    EXPECT_FALSE(preferences_store::Load(file, error).has_value()) << content;
    EXPECT_NE(error.find("设置文件格式无效"), std::string::npos);
  }
}
