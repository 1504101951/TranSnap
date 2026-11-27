#ifndef RUNNER_WINDOWS_SYSTEM_H_
#define RUNNER_WINDOWS_SYSTEM_H_

#include <cstdint>
#include <filesystem>
#include <string>

namespace windows_system {

std::filesystem::path DataDirectory();

std::string SystemLanguage();

bool LaunchAtLogin();

bool SetLaunchAtLogin(bool enabled, std::string& error);

int64_t SystemAccent();

bool SupportsAcrylic();

void ShowWarning(const std::string& title, const std::string& message);

void ShowStartFailure(const std::string& message);

}

#endif
