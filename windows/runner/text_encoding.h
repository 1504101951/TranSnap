#ifndef RUNNER_TEXT_ENCODING_H_
#define RUNNER_TEXT_ENCODING_H_

#include <string>

std::string Utf8FromUtf16(const wchar_t* utf16_string);

std::wstring Utf16FromUtf8(const std::string& utf8_string);

#endif
