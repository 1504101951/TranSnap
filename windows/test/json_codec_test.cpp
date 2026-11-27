#include "json_codec.h"

#include <gtest/gtest.h>

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

TEST(JsonCodec, RoundTripsPreferenceValuesKeepingIntegerAndDoubleTypes) {
  EncodableMap preferences{
      {EncodableValue("revision"), EncodableValue(3)},
      {EncodableValue("large"), EncodableValue(static_cast<int64_t>(5000000000))},
      {EncodableValue("glassOpacity"), EncodableValue(1.0)},
      {EncodableValue("ratio"), EncodableValue(0.85)},
      {EncodableValue("automatic"), EncodableValue(true)},
      {EncodableValue("secondaryLanguage"), EncodableValue()},
      {EncodableValue("label"), EncodableValue("翻译 \"T\"\n\\ \x01")},
      {EncodableValue("modifiers"),
       EncodableValue(EncodableList{EncodableValue("control"), EncodableValue("alt")})},
  };
  std::string text = json_codec::Stringify(EncodableValue(preferences));
  auto parsed = json_codec::Parse(text);
  ASSERT_TRUE(parsed.has_value());
  const auto& map = std::get<EncodableMap>(*parsed);
  EXPECT_EQ(std::get<int32_t>(map.at(EncodableValue("revision"))), 3);
  EXPECT_EQ(std::get<int64_t>(map.at(EncodableValue("large"))), 5000000000);
  EXPECT_EQ(std::get<double>(map.at(EncodableValue("glassOpacity"))), 1.0);
  EXPECT_EQ(std::get<double>(map.at(EncodableValue("ratio"))), 0.85);
  EXPECT_TRUE(std::get<bool>(map.at(EncodableValue("automatic"))));
  EXPECT_TRUE(map.at(EncodableValue("secondaryLanguage")).IsNull());
  EXPECT_EQ(std::get<std::string>(map.at(EncodableValue("label"))), "翻译 \"T\"\n\\ \x01");
  EXPECT_EQ(map.at(EncodableValue("modifiers")),
            EncodableValue(EncodableList{EncodableValue("control"), EncodableValue("alt")}));
}

TEST(JsonCodec, DecodesUnicodeEscapesIncludingSurrogatePairs) {
  auto parsed = json_codec::Parse(R"(["\u4e2d\u6587", "\ud83d\ude00", "\/"])");
  ASSERT_TRUE(parsed.has_value());
  EXPECT_EQ(*parsed, EncodableValue(EncodableList{
                         EncodableValue("中文"), EncodableValue("😀"), EncodableValue("/")}));
}

TEST(JsonCodec, RejectsMalformedDocuments) {
  for (const char* text : {"", "{", "{\"a\":}", "[1,]", "{\"a\":1}x", "\"\\ud83d\"",
                           "\"\\x\"", "01a", "99999999999999999999"}) {
    EXPECT_FALSE(json_codec::Parse(text).has_value()) << text;
  }
}
