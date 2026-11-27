#include "text_file.h"

#include <fstream>
#include <sstream>
#include <system_error>

#include "utils.h"

namespace text_file {

std::optional<std::string> ReadUtf8(const std::filesystem::path& file,
                                    std::string& error) {
  std::ifstream stream(file, std::ios::binary);
  std::ostringstream buffer;
  buffer << stream.rdbuf();
  if (!stream) {
    error = "无法读取文件：" + file.u8string();
    return std::nullopt;
  }
  std::string bytes = buffer.str();
  if (!bytes.empty() && Utf16FromUtf8(bytes).empty()) {
    error = "术语文件须为 UTF-8 编码，请另存为 UTF-8 后再导入。";
    return std::nullopt;
  }
  return bytes;
}

bool WriteAtomically(const std::filesystem::path& file,
                     const std::string& contents) {
  auto temporary = file;
  temporary += ".tmp";
  {
    std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
    stream << contents;
    stream.flush();
    if (!stream) {
      return false;
    }
  }
  std::error_code code;
  std::filesystem::rename(temporary, file, code);
  if (code) {
    std::filesystem::remove(temporary, code);
    return false;
  }
  return true;
}

}
