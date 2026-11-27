#ifndef RUNNER_CREDENTIALS_H_
#define RUNNER_CREDENTIALS_H_

#include <flutter/encodable_value.h>

#include <optional>
#include <string>

namespace credentials {

enum class Lookup { kFound, kMissing, kFailed };

Lookup Read(const std::string& id, flutter::EncodableMap& value,
            std::string& error);

bool Store(const std::string& id, const std::optional<flutter::EncodableMap>& value,
           std::string& error);

}

#endif
