#include "language_detection.h"

#include <windows.h>
#include <elscore.h>
#include <elssrvc.h>

#include <vector>

#include "utils.h"

namespace language_detection {
namespace {

constexpr size_t kMaximumCandidates = 3;

bool Unchanged(const std::wstring& text, DWORD transform) {
  int length = static_cast<int>(text.size());
  int size = ::LCMapStringEx(L"zh-CN", transform, text.c_str(), length, nullptr,
                             0, nullptr, nullptr, 0);
  if (size <= 0) {
    return false;
  }
  std::wstring converted(static_cast<size_t>(size), L'\0');
  if (::LCMapStringEx(L"zh-CN", transform, text.c_str(), length, converted.data(),
                      size, nullptr, nullptr, 0) <= 0) {
    return false;
  }
  return converted == text;
}

}

std::optional<flutter::EncodableMap> Candidates(const std::string& text,
                                                std::string& error) {
  std::wstring wide = Utf16FromUtf8(text);
  MAPPING_ENUM_OPTIONS options = {};
  options.Size = sizeof(options);
  options.pGuid = const_cast<GUID*>(&ELS_GUID_LANGUAGE_DETECTION);
  PMAPPING_SERVICE_INFO services = nullptr;
  DWORD service_count = 0;
  if (FAILED(::MappingGetServices(&options, &services, &service_count)) ||
      service_count == 0) {
    error = "系统语言检测服务不可用。";
    return std::nullopt;
  }
  MAPPING_PROPERTY_BAG bag = {};
  bag.Size = sizeof(bag);
  HRESULT recognized = ::MappingRecognizeText(
      services, wide.c_str(), static_cast<DWORD>(wide.size()), 0, nullptr, &bag);
  if (FAILED(recognized)) {
    ::MappingFreeServices(services);
    error = "系统语言检测失败。";
    return std::nullopt;
  }
  flutter::EncodableList candidates;
  bool chinese = false;
  if (bag.dwRangesCount > 0 && bag.prgResultRanges[0].pData) {
    const auto* tag = static_cast<const wchar_t*>(bag.prgResultRanges[0].pData);
    while (*tag && candidates.size() < kMaximumCandidates) {
      std::string code = Utf8FromUtf16(tag);
      chinese = chinese || code.rfind("zh", 0) == 0;
      candidates.push_back(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("code"), flutter::EncodableValue(code)},
          {flutter::EncodableValue("confidence"), flutter::EncodableValue()},
      }));
      tag += wcslen(tag) + 1;
    }
  }
  ::MappingFreePropertyBag(&bag);
  ::MappingFreeServices(services);
  flutter::EncodableList scripts;
  if (chinese && Unchanged(wide, LCMAP_SIMPLIFIED_CHINESE)) {
    scripts.push_back(flutter::EncodableValue("Hans"));
  }
  if (chinese && Unchanged(wide, LCMAP_TRADITIONAL_CHINESE)) {
    scripts.push_back(flutter::EncodableValue("Hant"));
  }
  return flutter::EncodableMap{
      {flutter::EncodableValue("candidates"), flutter::EncodableValue(candidates)},
      {flutter::EncodableValue("unchangedScripts"), flutter::EncodableValue(scripts)},
  };
}

}
