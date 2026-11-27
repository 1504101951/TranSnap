#include "selection_capture.h"

#include <windows.h>

#include <cstring>
#include <utility>

#include "clipboard.h"
#include "main_thread.h"
#include "protocol.h"
#include "synthetic_input.h"
#include "uia_selection.h"
#include "utils.h"
#include "windows_system.h"

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

constexpr unsigned kSettleMilliseconds = 80;

SelectionCapture* g_capture = nullptr;

void CALLBACK ForegroundProc(HWINEVENTHOOK, DWORD, HWND window, LONG, LONG, DWORD, DWORD) {
  DWORD process = 0;
  ::GetWindowThreadProcessId(window, &process);
  if (g_capture) {
    g_capture->ForegroundChanged(process);
  }
}

bool IsExplicit(const std::string& gesture) {
  return gesture == protocol::kHotkeyGesture || gesture == protocol::kInputHotkeyGesture;
}

std::string NewSessionId() {
  GUID guid{};
  wchar_t text[40] = {};
  ::CoCreateGuid(&guid);
  ::StringFromGUID2(guid, text, 40);
  std::string id = Utf8FromUtf16(text);
  return id.size() > 2 ? id.substr(1, id.size() - 2) : id;
}

EncodableValue OptionalText(const std::optional<std::string>& text) {
  return text ? EncodableValue(*text) : EncodableValue();
}

}

SelectionCapture::SelectionCapture(Delegate delegate) : delegate_(std::move(delegate)) {
  g_capture = this;
  monitor_ = std::make_unique<SelectionMonitor>(SelectionMonitor::Delegate{
      delegate_.request,
      delegate_.automatic,
      [this](const std::string& gesture) { Capture(gesture); },
      [this](const char* event_type) { Cancel(event_type); },
      [this]() { Validate(); },
      delegate_.overlay_contains,
  });
  foreground_hook_ = ::SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr,
                                       ForegroundProc, 0, 0, WINEVENT_OUTOFCONTEXT);
}

SelectionCapture::~SelectionCapture() {
  if (foreground_hook_) {
    ::UnhookWinEvent(foreground_hook_);
  }
  g_capture = nullptr;
}

void SelectionCapture::Capture(const std::string& gesture) {
  bool explicit_gesture = IsExplicit(gesture);
  if (!explicit_gesture && retains_result_) {
    return;
  }
  unsigned generation = ++generation_;
  unsigned long process = uia_selection::ForegroundProcess();
  if (!process || process == ::GetCurrentProcessId()) {
    return;
  }
  std::wstring executable = windows_system::ProcessImagePath(process);
  if (delegate_.excluded(executable)) {
    return;
  }
  std::string source_name = windows_system::ApplicationDisplayName(executable);
  if (gesture == protocol::kHotkeyGesture) {
    observed_process_ = 0;
    Emit(gesture, process, source_name, "", nullptr);
    return;
  }
  std::weak_ptr<char> alive = alive_;
  auto read = [this, alive, gesture, generation, process, source_name, explicit_gesture]() {
    if (alive.expired() || generation_ != generation) {
      return;
    }
    bool keyboard = gesture == protocol::kSelectAllGesture || gesture == protocol::kKeyboardGesture;
    main_thread::Background([this, alive, gesture, generation, process, source_name,
                             explicit_gesture, keyboard]() {
      uia_selection::Read read = uia_selection::ReadSelection(process);
      bool candidate = keyboard && uia_selection::PermitsKeyboardTrigger(process);
      main_thread::Post([this, alive, gesture, generation, process, source_name, explicit_gesture,
                         read, candidate]() {
        if (alive.expired() || generation_ != generation) {
          return;
        }
        Pending pending{gesture, generation, process, source_name, read.secure, candidate};
        EncodableList context;
        for (const auto& kind : read.context) {
          context.push_back(EncodableValue(kind));
        }
        EncodableMap request{
            {EncodableValue("context"), EncodableValue(context)},
            {EncodableValue("text"), OptionalText(read.text)},
            {EncodableValue("allowCopy"), EncodableValue(explicit_gesture)},
        };
        if (read.secure) {
          Finish(pending, std::nullopt);
          return;
        }
        Decide(protocol::kShouldCopySelection, request,
               [this, alive, pending, request, text = read.text](bool copy) {
                 if (alive.expired()) {
                   return;
                 }
                 if (!copy) {
                   Finish(pending, text);
                   return;
                 }
                 Copy(pending, request, text);
               });
      });
    });
  };
  if (explicit_gesture) {
    read();
    return;
  }
  main_thread::After(kSettleMilliseconds, read);
}

void SelectionCapture::Copy(Pending pending, EncodableMap request, std::optional<std::string> text) {
  if (generation_ != pending.generation) {
    return;
  }
  std::weak_ptr<char> alive = alive_;
  clipboard::ReadCopiedText(
      []() { synthetic_input::SendControlShortcut('C'); },
      [this, alive, pending, request, text](std::optional<std::string> copied) mutable {
        if (alive.expired()) {
          return;
        }
        if (!copied || uia_selection::ForegroundProcess() != pending.process) {
          Finish(pending, text);
          return;
        }
        request[EncodableValue("copied")] = EncodableValue(*copied);
        Decide(protocol::kAcceptsCopiedSelection, request,
               [this, alive, pending, text, copied](bool accepts) {
                 if (!alive.expired()) {
                   Finish(pending, accepts ? copied : text);
                 }
               });
      });
}

void SelectionCapture::Finish(const Pending& pending, const std::optional<std::string>& text) {
  bool explicit_gesture = IsExplicit(pending.gesture);
  if (generation_ != pending.generation ||
      uia_selection::ForegroundProcess() != pending.process ||
      (!explicit_gesture && retains_result_)) {
    return;
  }
  bool usable = uia_selection::IsUsable(text);
  const char* read_failure =
      explicit_gesture && !usable && pending.secure ? protocol::kSecureFieldFailure : nullptr;
  if (!explicit_gesture && !usable && !pending.keyboard_candidate) {
    Invalidate(protocol::kSelectionInvalidatedEvent);
    return;
  }
  Emit(pending.gesture, pending.process, pending.source_name, text.value_or(""), read_failure);
  observed_process_ = pending.process;
}

void SelectionCapture::Emit(const std::string& gesture, unsigned long process,
                            const std::string& source_name, const std::string& text,
                            const char* read_failure) {
  if (retains_result_ && !IsExplicit(gesture)) {
    return;
  }
  retains_result_ = false;
  Invalidate(protocol::kSelectionInvalidatedEvent);
  session_ = NewSessionId();
  source_process_ = process;
  POINT cursor{};
  ::GetCursorPos(&cursor);
  auto [x, y] = windows_system::LogicalPoint(cursor.x, cursor.y);
  delegate_.emit(EncodableMap{
      {EncodableValue("type"), EncodableValue(protocol::kSelectionCapturedEvent)},
      {EncodableValue("sessionId"), EncodableValue(*session_)},
      {EncodableValue("text"), EncodableValue(text)},
      {EncodableValue("gesture"), EncodableValue(gesture)},
      {EncodableValue("readFailure"),
       read_failure ? EncodableValue(read_failure) : EncodableValue()},
      {EncodableValue("sourceAppName"),
       source_name.empty() ? EncodableValue() : EncodableValue(source_name)},
      {EncodableValue("x"), EncodableValue(x)},
      {EncodableValue("y"), EncodableValue(y)},
  });
}

void SelectionCapture::Cancel(const char* event_type) {
  ++generation_;
  observed_process_ = 0;
  Invalidate(event_type);
}

void SelectionCapture::Invalidate(const char* event_type) {
  if (retains_result_ && std::strcmp(event_type, protocol::kEscapePressedEvent) != 0) {
    return;
  }
  if (!session_) {
    return;
  }
  std::string session = *session_;
  session_.reset();
  source_process_ = 0;
  retains_result_ = false;
  delegate_.hide_overlay(session);
  delegate_.emit(EncodableMap{
      {EncodableValue("type"), EncodableValue(event_type)},
      {EncodableValue("sessionId"), EncodableValue(session)},
  });
}

void SelectionCapture::Retain(const std::string& session_id) {
  if (session_ == session_id) {
    retains_result_ = true;
  }
}

bool SelectionCapture::Hide(const std::string& session_id) {
  if (session_ != session_id) {
    return false;
  }
  ++generation_;
  session_.reset();
  source_process_ = 0;
  retains_result_ = false;
  delegate_.hide_overlay(session_id);
  return true;
}

bool SelectionCapture::IsCurrent(const std::string& session_id) const {
  return session_ == session_id;
}

void SelectionCapture::ForegroundChanged(unsigned long process) {
  if (process == foreground_process_) {
    return;
  }
  foreground_process_ = process;
  ++generation_;
  observed_process_ = 0;
  if (source_process_ != process) {
    Invalidate(protocol::kSelectionInvalidatedEvent);
  }
}

void SelectionCapture::Validate() {
  if (!observed_process_ || !session_) {
    return;
  }
  unsigned validation = ++validation_;
  unsigned long process = observed_process_;
  std::weak_ptr<char> alive = alive_;
  main_thread::After(kSettleMilliseconds, [this, alive, validation, process]() {
    if (alive.expired() || validation_ != validation || observed_process_ != process) {
      return;
    }
    main_thread::Background([this, alive, validation, process]() {
      uia_selection::Read read = uia_selection::ReadSelection(process);
      main_thread::Post([this, alive, validation, process, read]() {
        if (alive.expired() || validation_ != validation || observed_process_ != process ||
            !read.text || uia_selection::IsUsable(read.text)) {
          return;
        }
        Invalidate(protocol::kSelectionInvalidatedEvent);
        observed_process_ = 0;
      });
    });
  });
}

void SelectionCapture::Decide(const char* method, EncodableMap request,
                              std::function<void(bool)> done) {
  delegate_.request(method, EncodableValue(std::move(request)),
                    [done](const EncodableValue* value) {
                      const auto* decided = value ? std::get_if<bool>(value) : nullptr;
                      done(decided && *decided);
                    });
}
