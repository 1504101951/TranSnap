#include "text_file.h"

#include <gtest/gtest.h>

#include <fstream>

namespace {

std::filesystem::path TemporaryFile(const char* name) {
  auto directory = std::filesystem::temp_directory_path() / "transnap-tests" / "text-file";
  std::filesystem::create_directories(directory);
  auto file = directory / name;
  std::filesystem::remove(file);
  return file;
}

void WriteBytes(const std::filesystem::path& file, const std::string& bytes) {
  std::ofstream(file, std::ios::binary) << bytes;
}

}

TEST(TextFile, WritesAndReadsUtf8WithoutLeavingTemporaryFile) {
  auto file = TemporaryFile("glossary.csv");
  std::string contents = "term,translation,language\n苹果,apple,en\n";
  ASSERT_TRUE(text_file::WriteAtomically(file, contents));
  std::string error;
  auto read = text_file::ReadUtf8(file, error);
  ASSERT_TRUE(read.has_value()) << error;
  EXPECT_EQ(*read, contents);
  auto temporary = file;
  temporary += ".tmp";
  EXPECT_FALSE(std::filesystem::exists(temporary));
}

TEST(TextFile, EmptyFileReadsAsEmptyText) {
  auto file = TemporaryFile("empty.json");
  WriteBytes(file, "");
  std::string error;
  auto read = text_file::ReadUtf8(file, error);
  ASSERT_TRUE(read.has_value()) << error;
  EXPECT_TRUE(read->empty());
}

TEST(TextFile, RejectsTextThatIsNotUtf8) {
  auto file = TemporaryFile("gbk.csv");
  WriteBytes(file, "term\n\xC6\xBB\xB9\xFB\n");
  std::string error;
  EXPECT_FALSE(text_file::ReadUtf8(file, error).has_value());
  EXPECT_EQ(error, "术语文件须为 UTF-8 编码，请另存为 UTF-8 后再导入。");
}

TEST(TextFile, MissingFileReportsReadFailure) {
  std::string error;
  EXPECT_FALSE(text_file::ReadUtf8(TemporaryFile("missing.csv"), error).has_value());
  EXPECT_FALSE(error.empty());
}
