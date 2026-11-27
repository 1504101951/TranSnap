#include "preferences_store.h"

#include <fstream>
#include <sstream>
#include <system_error>

#include "json_codec.h"

namespace preferences_store {

std::optional<flutter::EncodableMap> Load(const std::filesystem::path& file,
                                          std::string& error) {
  std::error_code code;
  if (!std::filesystem::exists(file, code)) {
    if (code) {
      error = "无法读取设置文件：" + code.message();
      return std::nullopt;
    }
    return flutter::EncodableMap{};
  }
  std::ifstream stream(file, std::ios::binary);
  std::ostringstream buffer;
  buffer << stream.rdbuf();
  if (!stream) {
    error = "无法读取设置文件。";
    return std::nullopt;
  }
  auto value = json_codec::Parse(buffer.str());
  const auto* map = value ? std::get_if<flutter::EncodableMap>(&*value) : nullptr;
  if (!map) {
    error = "设置文件格式无效：" + file.u8string();
    return std::nullopt;
  }
  return *map;
}

bool Save(const std::filesystem::path& file,
          const flutter::EncodableMap& preferences,
          std::string& error) {
  std::error_code code;
  std::filesystem::create_directories(file.parent_path(), code);
  if (code) {
    error = "无法创建设置目录：" + code.message();
    return false;
  }
  auto temporary = file;
  temporary += ".tmp";
  {
    std::ofstream stream(temporary, std::ios::binary | std::ios::trunc);
    stream << json_codec::Stringify(flutter::EncodableValue(preferences));
    stream.flush();
    if (!stream) {
      error = "无法写入设置文件。";
      return false;
    }
  }
  std::filesystem::rename(temporary, file, code);
  if (code) {
    std::filesystem::remove(temporary, code);
    error = "无法保存设置文件。";
    return false;
  }
  return true;
}

}
