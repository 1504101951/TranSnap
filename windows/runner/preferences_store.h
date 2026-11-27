#ifndef RUNNER_PREFERENCES_STORE_H_
#define RUNNER_PREFERENCES_STORE_H_

#include <flutter/encodable_value.h>

#include <filesystem>
#include <optional>
#include <string>

namespace preferences_store {

std::optional<flutter::EncodableMap> Load(const std::filesystem::path& file,
                                          std::string& error);

bool Save(const std::filesystem::path& file,
          const flutter::EncodableMap& preferences,
          std::string& error);

}

#endif
