#include "language_detection.h"

#include <gtest/gtest.h>

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

EncodableMap Detect(const std::string& text) {
  std::string error;
  auto result = language_detection::Candidates(text, error);
  EXPECT_TRUE(result.has_value()) << error;
  return result.value_or(EncodableMap{});
}

std::string FirstCode(const EncodableMap& result) {
  const auto& candidates = std::get<EncodableList>(result.at(EncodableValue("candidates")));
  if (candidates.empty()) {
    return std::string();
  }
  const auto& first = std::get<EncodableMap>(candidates.front());
  EXPECT_TRUE(first.at(EncodableValue("confidence")).IsNull());
  return std::get<std::string>(first.at(EncodableValue("code")));
}

EncodableList Scripts(const EncodableMap& result) {
  return std::get<EncodableList>(result.at(EncodableValue("unchangedScripts")));
}

}

TEST(LanguageDetection, ReturnsCandidatesWithoutConfidence) {
  auto french = Detect(
      "Bonjour, cette application permet de traduire le texte sélectionné dans "
      "une autre langue sans interrompre votre travail.");
  EXPECT_EQ(FirstCode(french), "fr");
  EXPECT_TRUE(Scripts(french).empty());
}

TEST(LanguageDetection, ReportsChineseScriptsThatConversionLeavesUnchanged) {
  EXPECT_EQ(Scripts(Detect("这是一段简体中文，用来测试语言识别。")),
            EncodableList{EncodableValue("Hans")});
  EXPECT_EQ(Scripts(Detect("這是一段繁體中文，用來測試語言識別。")),
            EncodableList{EncodableValue("Hant")});
}
