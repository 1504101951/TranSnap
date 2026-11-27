#ifndef RUNNER_WINDOWS_SYSTEM_H_
#define RUNNER_WINDOWS_SYSTEM_H_

#include <cstdint>
#include <filesystem>
#include <string>
#include <utility>

struct HWND__;

namespace windows_system {

std::filesystem::path DataDirectory();

std::string SystemLanguage();

bool LaunchAtLogin();

bool SetLaunchAtLogin(bool enabled, std::string& error);

int64_t SystemAccent();

bool SupportsAcrylic();

void ApplyAcrylic(HWND__* window);

std::pair<double, double> LogicalPoint(long x, long y);

void ShowWarning(const std::string& title, const std::string& message);

void ShowStartFailure(const std::string& message);

}

#endif
