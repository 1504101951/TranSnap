#ifndef RUNNER_JSON_CODEC_H_
#define RUNNER_JSON_CODEC_H_

#include <flutter/encodable_value.h>

#include <optional>
#include <string>

namespace json_codec {

std::optional<flutter::EncodableValue> Parse(const std::string& text);

std::string Stringify(const flutter::EncodableValue& value);

}

#endif
