#ifndef RUNNER_FILE_DIALOGS_H_
#define RUNNER_FILE_DIALOGS_H_

#include <filesystem>
#include <optional>
#include <string>

namespace file_dialogs {

std::optional<std::filesystem::path> ChooseGlossaryFile(std::string& error);

std::optional<std::filesystem::path> ChooseSaveLocation(
    const std::string& suggested_name,
    std::string& error);

}

#endif
