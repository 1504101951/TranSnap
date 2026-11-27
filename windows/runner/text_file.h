#ifndef RUNNER_TEXT_FILE_H_
#define RUNNER_TEXT_FILE_H_

#include <filesystem>
#include <optional>
#include <string>

namespace text_file {

std::optional<std::string> ReadUtf8(const std::filesystem::path& file,
                                    std::string& error);

bool WriteAtomically(const std::filesystem::path& file,
                     const std::string& contents);

}

#endif
