#ifndef RUNNER_LANGUAGE_DETECTION_H_
#define RUNNER_LANGUAGE_DETECTION_H_

#include <flutter/encodable_value.h>

#include <optional>
#include <string>

namespace language_detection {

std::optional<flutter::EncodableMap> Candidates(const std::string& text,
                                                std::string& error);

}

#endif
