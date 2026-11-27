#include "json_codec.h"

#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <type_traits>
#include <variant>
#include <vector>

namespace json_codec {
namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

class Parser {
 public:
  explicit Parser(const std::string& text) : text_(text) {}

  std::optional<EncodableValue> Document() {
    auto value = Value();
    SkipWhitespace();
    if (!value || position_ != text_.size()) {
      return std::nullopt;
    }
    return value;
  }

 private:
  std::optional<EncodableValue> Value() {
    SkipWhitespace();
    if (position_ >= text_.size()) {
      return std::nullopt;
    }
    switch (text_[position_]) {
      case '{':
        return Object();
      case '[':
        return Array();
      case '"': {
        auto string = String();
        if (!string) {
          return std::nullopt;
        }
        return EncodableValue(*string);
      }
      case 't':
        return Literal("true", EncodableValue(true));
      case 'f':
        return Literal("false", EncodableValue(false));
      case 'n':
        return Literal("null", EncodableValue());
      default:
        return Number();
    }
  }

  std::optional<EncodableValue> Object() {
    ++position_;
    EncodableMap map;
    SkipWhitespace();
    if (Consume('}')) {
      return EncodableValue(map);
    }
    while (true) {
      SkipWhitespace();
      if (position_ >= text_.size() || text_[position_] != '"') {
        return std::nullopt;
      }
      auto key = String();
      SkipWhitespace();
      if (!key || !Consume(':')) {
        return std::nullopt;
      }
      auto value = Value();
      if (!value) {
        return std::nullopt;
      }
      map[EncodableValue(*key)] = *value;
      SkipWhitespace();
      if (Consume('}')) {
        return EncodableValue(map);
      }
      if (!Consume(',')) {
        return std::nullopt;
      }
    }
  }

  std::optional<EncodableValue> Array() {
    ++position_;
    EncodableList list;
    SkipWhitespace();
    if (Consume(']')) {
      return EncodableValue(list);
    }
    while (true) {
      auto value = Value();
      if (!value) {
        return std::nullopt;
      }
      list.push_back(*value);
      SkipWhitespace();
      if (Consume(']')) {
        return EncodableValue(list);
      }
      if (!Consume(',')) {
        return std::nullopt;
      }
    }
  }

  std::optional<std::string> String() {
    ++position_;
    std::string result;
    while (position_ < text_.size()) {
      char character = text_[position_++];
      if (character == '"') {
        return result;
      }
      if (static_cast<unsigned char>(character) < 0x20) {
        return std::nullopt;
      }
      if (character != '\\') {
        result.push_back(character);
        continue;
      }
      if (position_ >= text_.size()) {
        return std::nullopt;
      }
      char escape = text_[position_++];
      switch (escape) {
        case '"':
        case '\\':
        case '/':
          result.push_back(escape);
          break;
        case 'b':
          result.push_back('\b');
          break;
        case 'f':
          result.push_back('\f');
          break;
        case 'n':
          result.push_back('\n');
          break;
        case 'r':
          result.push_back('\r');
          break;
        case 't':
          result.push_back('\t');
          break;
        case 'u': {
          auto code = CodePoint();
          if (!code) {
            return std::nullopt;
          }
          AppendUtf8(result, *code);
          break;
        }
        default:
          return std::nullopt;
      }
    }
    return std::nullopt;
  }

  std::optional<uint32_t> CodePoint() {
    auto high = Hex4();
    if (!high) {
      return std::nullopt;
    }
    if (*high < 0xD800 || *high > 0xDFFF) {
      return high;
    }
    if (*high > 0xDBFF || !Consume('\\') || !Consume('u')) {
      return std::nullopt;
    }
    auto low = Hex4();
    if (!low || *low < 0xDC00 || *low > 0xDFFF) {
      return std::nullopt;
    }
    return 0x10000 + ((*high - 0xD800) << 10) + (*low - 0xDC00);
  }

  std::optional<uint32_t> Hex4() {
    if (position_ + 4 > text_.size()) {
      return std::nullopt;
    }
    uint32_t value = 0;
    for (int index = 0; index < 4; ++index) {
      char character = text_[position_++];
      value <<= 4;
      if (character >= '0' && character <= '9') {
        value |= static_cast<uint32_t>(character - '0');
      } else if (character >= 'a' && character <= 'f') {
        value |= static_cast<uint32_t>(character - 'a' + 10);
      } else if (character >= 'A' && character <= 'F') {
        value |= static_cast<uint32_t>(character - 'A' + 10);
      } else {
        return std::nullopt;
      }
    }
    return value;
  }

  static void AppendUtf8(std::string& output, uint32_t code) {
    if (code < 0x80) {
      output.push_back(static_cast<char>(code));
    } else if (code < 0x800) {
      output.push_back(static_cast<char>(0xC0 | (code >> 6)));
      output.push_back(static_cast<char>(0x80 | (code & 0x3F)));
    } else if (code < 0x10000) {
      output.push_back(static_cast<char>(0xE0 | (code >> 12)));
      output.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
      output.push_back(static_cast<char>(0x80 | (code & 0x3F)));
    } else {
      output.push_back(static_cast<char>(0xF0 | (code >> 18)));
      output.push_back(static_cast<char>(0x80 | ((code >> 12) & 0x3F)));
      output.push_back(static_cast<char>(0x80 | ((code >> 6) & 0x3F)));
      output.push_back(static_cast<char>(0x80 | (code & 0x3F)));
    }
  }

  std::optional<EncodableValue> Number() {
    size_t start = position_;
    bool fractional = false;
    Consume('-');
    if (!Digits()) {
      return std::nullopt;
    }
    if (Consume('.')) {
      fractional = true;
      if (!Digits()) {
        return std::nullopt;
      }
    }
    if (Consume('e') || Consume('E')) {
      fractional = true;
      if (!Consume('+')) {
        Consume('-');
      }
      if (!Digits()) {
        return std::nullopt;
      }
    }
    std::string number = text_.substr(start, position_ - start);
    if (fractional) {
      return EncodableValue(std::strtod(number.c_str(), nullptr));
    }
    errno = 0;
    long long integer = std::strtoll(number.c_str(), nullptr, 10);
    if (errno == ERANGE) {
      return std::nullopt;
    }
    if (integer >= std::numeric_limits<int32_t>::min() &&
        integer <= std::numeric_limits<int32_t>::max()) {
      return EncodableValue(static_cast<int32_t>(integer));
    }
    return EncodableValue(static_cast<int64_t>(integer));
  }

  bool Digits() {
    size_t start = position_;
    while (position_ < text_.size() && text_[position_] >= '0' &&
           text_[position_] <= '9') {
      ++position_;
    }
    return position_ > start;
  }

  std::optional<EncodableValue> Literal(const char* word,
                                        EncodableValue value) {
    std::string expected(word);
    if (text_.compare(position_, expected.size(), expected) != 0) {
      return std::nullopt;
    }
    position_ += expected.size();
    return value;
  }

  bool Consume(char character) {
    if (position_ < text_.size() && text_[position_] == character) {
      ++position_;
      return true;
    }
    return false;
  }

  void SkipWhitespace() {
    while (position_ < text_.size() &&
           (text_[position_] == ' ' || text_[position_] == '\n' ||
            text_[position_] == '\r' || text_[position_] == '\t')) {
      ++position_;
    }
  }

  const std::string& text_;
  size_t position_ = 0;
};

void AppendString(std::string& output, const std::string& value) {
  output.push_back('"');
  for (char character : value) {
    switch (character) {
      case '"':
        output += "\\\"";
        break;
      case '\\':
        output += "\\\\";
        break;
      case '\n':
        output += "\\n";
        break;
      case '\r':
        output += "\\r";
        break;
      case '\t':
        output += "\\t";
        break;
      default:
        if (static_cast<unsigned char>(character) < 0x20) {
          char escaped[7];
          std::snprintf(escaped, sizeof(escaped), "\\u%04x",
                        static_cast<unsigned char>(character));
          output += escaped;
        } else {
          output.push_back(character);
        }
    }
  }
  output.push_back('"');
}

void AppendDouble(std::string& output, double value) {
  if (!std::isfinite(value)) {
    output += "null";
    return;
  }
  char buffer[32];
  std::snprintf(buffer, sizeof(buffer), "%.17g", value);
  std::string number(buffer);
  if (number.find_first_of(".eE") == std::string::npos) {
    number += ".0";
  }
  output += number;
}

template <typename T>
void AppendNumbers(std::string& output, const std::vector<T>& values) {
  output.push_back('[');
  for (size_t index = 0; index < values.size(); ++index) {
    if (index > 0) {
      output.push_back(',');
    }
    if constexpr (std::is_floating_point_v<T>) {
      AppendDouble(output, static_cast<double>(values[index]));
    } else {
      output += std::to_string(values[index]);
    }
  }
  output.push_back(']');
}

void Append(std::string& output, const EncodableValue& value) {
  if (std::holds_alternative<std::monostate>(value)) {
    output += "null";
  } else if (const auto* boolean = std::get_if<bool>(&value)) {
    output += *boolean ? "true" : "false";
  } else if (const auto* small = std::get_if<int32_t>(&value)) {
    output += std::to_string(*small);
  } else if (const auto* large = std::get_if<int64_t>(&value)) {
    output += std::to_string(*large);
  } else if (const auto* number = std::get_if<double>(&value)) {
    AppendDouble(output, *number);
  } else if (const auto* string = std::get_if<std::string>(&value)) {
    AppendString(output, *string);
  } else if (const auto* bytes = std::get_if<std::vector<uint8_t>>(&value)) {
    AppendNumbers(output, *bytes);
  } else if (const auto* ints = std::get_if<std::vector<int32_t>>(&value)) {
    AppendNumbers(output, *ints);
  } else if (const auto* longs = std::get_if<std::vector<int64_t>>(&value)) {
    AppendNumbers(output, *longs);
  } else if (const auto* floats = std::get_if<std::vector<float>>(&value)) {
    AppendNumbers(output, *floats);
  } else if (const auto* doubles = std::get_if<std::vector<double>>(&value)) {
    AppendNumbers(output, *doubles);
  } else if (const auto* list = std::get_if<EncodableList>(&value)) {
    output.push_back('[');
    for (size_t index = 0; index < list->size(); ++index) {
      if (index > 0) {
        output.push_back(',');
      }
      Append(output, (*list)[index]);
    }
    output.push_back(']');
  } else if (const auto* map = std::get_if<EncodableMap>(&value)) {
    output.push_back('{');
    bool first = true;
    for (const auto& [key, item] : *map) {
      const auto* name = std::get_if<std::string>(&key);
      if (!name) {
        continue;
      }
      if (!first) {
        output.push_back(',');
      }
      first = false;
      AppendString(output, *name);
      output.push_back(':');
      Append(output, item);
    }
    output.push_back('}');
  } else {
    output += "null";
  }
}

}

std::optional<EncodableValue> Parse(const std::string& text) {
  return Parser(text).Document();
}

std::string Stringify(const EncodableValue& value) {
  std::string output;
  Append(output, value);
  return output;
}

}
