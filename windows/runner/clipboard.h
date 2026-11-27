#ifndef RUNNER_CLIPBOARD_H_
#define RUNNER_CLIPBOARD_H_

#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace clipboard {

using Snapshot = std::vector<std::pair<unsigned, std::vector<uint8_t>>>;

Snapshot Capture();

void Restore(const Snapshot& snapshot);

unsigned long Sequence();

std::optional<std::string> Text();

bool SetText(const std::string& text);

void ReadCopiedText(std::function<void()> copy,
                    std::function<void(std::optional<std::string> text)> done);

}

#endif
