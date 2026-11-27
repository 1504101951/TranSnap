#include "clipboard.h"

#include <windows.h>

#include <chrono>
#include <cstring>
#include <cwchar>
#include <memory>

#include "main_thread.h"
#include "text_encoding.h"

namespace clipboard {
namespace {

constexpr unsigned kPollMilliseconds = 20;
constexpr auto kCopyTimeout = std::chrono::milliseconds(250);

class OpenedClipboard {
 public:
  OpenedClipboard() : opened_(::OpenClipboard(main_thread::Window()) != FALSE) {}
  ~OpenedClipboard() {
    if (opened_) {
      ::CloseClipboard();
    }
  }
  explicit operator bool() const { return opened_; }

 private:
  bool opened_;
};

std::optional<std::vector<uint8_t>> Bytes(UINT format) {
  HANDLE data = ::GetClipboardData(format);
  SIZE_T size = data ? ::GlobalSize(data) : 0;
  const void* locked = size ? ::GlobalLock(data) : nullptr;
  if (!locked) {
    return std::nullopt;
  }
  std::vector<uint8_t> bytes(size);
  std::memcpy(bytes.data(), locked, size);
  ::GlobalUnlock(data);
  return bytes;
}

void Poll(unsigned long sequence, std::chrono::steady_clock::time_point deadline,
          std::shared_ptr<Snapshot> snapshot,
          std::function<void(std::optional<std::string>)> done) {
  if (Sequence() == sequence) {
    if (std::chrono::steady_clock::now() >= deadline) {
      done(std::nullopt);
      return;
    }
    main_thread::After(kPollMilliseconds, [sequence, deadline, snapshot, done]() {
      Poll(sequence, deadline, snapshot, done);
    });
    return;
  }
  unsigned long copied = Sequence();
  auto text = Text();
  if (Sequence() != copied) {
    done(std::nullopt);
    return;
  }
  Restore(*snapshot);
  done(text);
}

}

Snapshot Capture() {
  Snapshot snapshot;
  OpenedClipboard opened;
  if (!opened) {
    return snapshot;
  }
  for (UINT format = ::EnumClipboardFormats(0); format; format = ::EnumClipboardFormats(format)) {
    auto bytes = Bytes(format);
    if (bytes) {
      snapshot.emplace_back(format, std::move(*bytes));
    }
  }
  return snapshot;
}

void Restore(const Snapshot& snapshot) {
  OpenedClipboard opened;
  if (!opened) {
    return;
  }
  ::EmptyClipboard();
  for (const auto& [format, bytes] : snapshot) {
    HGLOBAL memory = ::GlobalAlloc(GMEM_MOVEABLE, bytes.size());
    void* locked = memory ? ::GlobalLock(memory) : nullptr;
    if (!locked) {
      continue;
    }
    std::memcpy(locked, bytes.data(), bytes.size());
    ::GlobalUnlock(memory);
    if (!::SetClipboardData(format, memory)) {
      ::GlobalFree(memory);
    }
  }
}

unsigned long Sequence() {
  return ::GetClipboardSequenceNumber();
}

std::optional<std::string> Text() {
  OpenedClipboard opened;
  auto bytes = opened ? Bytes(CF_UNICODETEXT) : std::nullopt;
  if (!bytes) {
    return std::nullopt;
  }
  std::wstring text(reinterpret_cast<const wchar_t*>(bytes->data()), bytes->size() / sizeof(wchar_t));
  text.resize(std::wcslen(text.c_str()));
  return Utf8FromUtf16(text.c_str());
}

bool SetText(const std::string& text) {
  std::wstring wide = Utf16FromUtf8(text);
  OpenedClipboard opened;
  if (!opened || !::EmptyClipboard()) {
    return false;
  }
  size_t bytes = (wide.size() + 1) * sizeof(wchar_t);
  HGLOBAL memory = ::GlobalAlloc(GMEM_MOVEABLE, bytes);
  void* locked = memory ? ::GlobalLock(memory) : nullptr;
  if (!locked) {
    if (memory) {
      ::GlobalFree(memory);
    }
    return false;
  }
  std::memcpy(locked, wide.c_str(), bytes);
  ::GlobalUnlock(memory);
  if (!::SetClipboardData(CF_UNICODETEXT, memory)) {
    ::GlobalFree(memory);
    return false;
  }
  return true;
}

void ReadCopiedText(std::function<void()> copy,
                    std::function<void(std::optional<std::string> text)> done) {
  auto snapshot = std::make_shared<Snapshot>(Capture());
  unsigned long sequence = Sequence();
  copy();
  Poll(sequence, std::chrono::steady_clock::now() + kCopyTimeout, snapshot, std::move(done));
}

}
