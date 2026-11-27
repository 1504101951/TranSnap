#include "selection_capture.h"

#include <windows.h>

#include <cstring>
#include <utility>

#include "clipboard.h"
#include "main_thread.h"
#include "protocol.h"
#include "synthetic_input.h"
#include "text_encoding.h"
#include "uia_selection.h"
#include "windows_system.h"

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

constexpr unsigned kSettleMilliseconds = 80;
constexpr unsigned kPasteRestoreMilliseconds = 500;

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

SelectionCapture::SelectionCapture(Delegate delegate)
    : delegate_(std::move(delegate)),
      bubble_([this]() { return delegate_.dark(); }),
      watcher_([this]() { Validate(); }) {
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
    StopObserving();
    Emit(gesture, process, source_name, "", nullptr, std::nullopt, {});
    return;
  }
  bool keyboard = gesture == protocol::kSelectAllGesture || gesture == protocol::kKeyboardGesture;
  std::weak_ptr<char> alive = alive_;
  auto read = [this, alive, gesture, generation, process, source_name, explicit_gesture, keyboard]() {
    if (alive.expired() || generation_ != generation) {
      return;
    }
    Pending pending{gesture, generation, process, source_name};
    if (gesture == protocol::kInputHotkeyGesture) {
      ReadInput(pending);
      return;
    }
    ReadText(process, explicit_gesture, keyboard, false,
             [this, pending](const Outcome& outcome) { Finish(pending, outcome); });
  };
  if (explicit_gesture) {
    read();
    return;
  }
  main_thread::After(kSettleMilliseconds, read);
}

void SelectionCapture::ReadForTranslation(const std::string& session_id,
                                          std::function<void(const Outcome&)> done) {
  if (session_ != session_id || !source_process_) {
    done(Outcome{});
    return;
  }
  unsigned generation = ++generation_;
  ReadText(source_process_, true, false, false,
           [this, session_id, generation, done](const Outcome& outcome) {
             done(generation_ == generation && session_ == session_id ? outcome : Outcome{});
           });
}

void SelectionCapture::ReadInput(const Pending& pending) {
  std::weak_ptr<char> alive = alive_;
  ReadText(pending.process, true, false, true, [this, alive, pending](const Outcome& outcome) {
    if (uia_selection::IsUsable(outcome.text) || generation_ != pending.generation) {
      Finish(pending, outcome);
      return;
    }
    main_thread::Background([this, alive, pending, outcome]() {
      bool text_input = uia_selection::FocusIsTextInput(pending.process);
      main_thread::Post([this, alive, pending, outcome, text_input]() {
        if (alive.expired() || generation_ != pending.generation) {
          return;
        }
        if (!text_input) {
          Finish(pending, outcome);
          return;
        }
        synthetic_input::SendControlShortcut('A');
        main_thread::After(kSettleMilliseconds, [this, alive, pending]() {
          if (alive.expired() || generation_ != pending.generation) {
            return;
          }
          ReadText(pending.process, true, false, true,
                   [this, pending](const Outcome& selected) { Finish(pending, selected); });
        });
      });
    });
  });
}

void SelectionCapture::ReadText(unsigned long process, bool allow_copy, bool keyboard, bool input,
                                std::function<void(const Outcome&)> done) {
  std::weak_ptr<char> alive = alive_;
  main_thread::Background([this, alive, process, allow_copy, keyboard, input, done]() {
    uia_selection::Read read = uia_selection::ReadSelection(process);
    bool candidate = keyboard && uia_selection::PermitsKeyboardTrigger(process);
    std::optional<bubble_layout::InputAnchor> anchor;
    if (input) {
      anchor = uia_selection::Anchor(process, read);
    }
    main_thread::Post([this, alive, process, allow_copy, done, read, candidate, anchor]() {
      if (alive.expired()) {
        return;
      }
      Outcome base{read.text, read.secure, candidate, read.owner_id, anchor};
      if (read.secure) {
        done(base);
        return;
      }
      EncodableList context;
      for (const auto& kind : read.context) {
        context.push_back(EncodableValue(kind));
      }
      EncodableMap request{
          {EncodableValue("context"), EncodableValue(context)},
          {EncodableValue("text"), OptionalText(read.text)},
          {EncodableValue("allowCopy"), EncodableValue(allow_copy)},
      };
      Decide(protocol::kShouldCopySelection, request,
             [this, alive, process, request, base, done](bool copy) {
               if (alive.expired()) {
                 return;
               }
               if (!copy) {
                 done(base);
                 return;
               }
               Copy(process, request, base, done);
             });
    });
  });
}

void SelectionCapture::Copy(unsigned long process, EncodableMap request, Outcome base,
                            std::function<void(const Outcome&)> done) {
  std::weak_ptr<char> alive = alive_;
  clipboard::ReadCopiedText(
      []() { synthetic_input::SendControlShortcut('C'); },
      [this, alive, process, request, base, done](std::optional<std::string> copied) mutable {
        if (alive.expired()) {
          return;
        }
        if (!copied || uia_selection::ForegroundProcess() != process) {
          done(base);
          return;
        }
        request[EncodableValue("copied")] = EncodableValue(*copied);
        Decide(protocol::kAcceptsCopiedSelection, request,
               [alive, base, done, copied](bool accepts) {
                 if (alive.expired()) {
                   return;
                 }
                 Outcome outcome = base;
                 if (accepts) {
                   outcome.text = copied;
                 }
                 done(outcome);
               });
      });
}

void SelectionCapture::Finish(const Pending& pending, const Outcome& outcome) {
  const std::optional<std::string>& text = outcome.text;
  bool explicit_gesture = IsExplicit(pending.gesture);
  if (generation_ != pending.generation ||
      uia_selection::ForegroundProcess() != pending.process ||
      (!explicit_gesture && retains_result_)) {
    return;
  }
  bool usable = uia_selection::IsUsable(text);
  const char* read_failure =
      explicit_gesture && !usable && outcome.secure ? protocol::kSecureFieldFailure : nullptr;
  if (!explicit_gesture && !usable && !outcome.keyboard_candidate) {
    Invalidate(protocol::kSelectionInvalidatedEvent);
    return;
  }
  Emit(pending.gesture, pending.process, pending.source_name, text.value_or(""), read_failure,
       outcome.anchor, outcome.owner_id);
  Observe(pending.process);
}

void SelectionCapture::Emit(const std::string& gesture, unsigned long process,
                            const std::string& source_name, const std::string& text,
                            const char* read_failure,
                            const std::optional<bubble_layout::InputAnchor>& anchor,
                            const std::vector<int>& input_selection) {
  if (retains_result_ && !IsExplicit(gesture)) {
    return;
  }
  retains_result_ = false;
  Invalidate(protocol::kSelectionInvalidatedEvent);
  session_ = NewSessionId();
  source_process_ = process;
  input_anchor_ = anchor;
  input_selection_ = input_selection;
  if (anchor) {
    bubble_.ShowProgress(*anchor);
  }
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
  StopObserving();
  Invalidate(event_type);
}

void SelectionCapture::Invalidate(const char* event_type) {
  if (retains_result_ && std::strcmp(event_type, protocol::kEscapePressedEvent) != 0) {
    return;
  }
  bubble_.CloseProgress();
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
  bubble_.CloseProgress();
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
  StopObserving();
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
        StopObserving();
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

void SelectionCapture::Replace(const std::string& session_id, const std::string& text,
                               std::function<void(std::optional<std::string> failure)> done) {
  if (session_ != session_id || !source_process_) {
    done("输入已结束，未替换原文。");
    return;
  }
  unsigned long process = source_process_;
  if (uia_selection::ForegroundProcess() != process) {
    done("来源应用已切换，未替换原文。");
    return;
  }
  std::weak_ptr<char> alive = alive_;
  std::vector<int> selection = input_selection_;
  main_thread::Background([this, alive, process, selection, text, done]() {
    uia_selection::PasteFacts facts = uia_selection::Facts(process, selection);
    main_thread::Post([this, alive, process, facts, text, done]() {
      if (alive.expired()) {
        return;
      }
      if (facts.focus_is_secure) {
        done("安全输入已开启，未替换原文。");
        return;
      }
      bubble_.CloseProgress();
      EncodableMap request{
          {EncodableValue("hasFocus"), EncodableValue(facts.has_focus)},
          {EncodableValue("focusIsSelection"), EncodableValue(facts.focus_is_selection)},
          {EncodableValue("focusIsTextInput"), EncodableValue(facts.focus_is_text_input)},
          {EncodableValue("focusIsSecure"), EncodableValue(facts.focus_is_secure)},
      };
      delegate_.request(
          protocol::kPasteTarget, EncodableValue(request),
          [this, alive, process, request, text, done](const EncodableValue* reply) {
            const auto* action = reply ? std::get_if<std::string>(reply) : nullptr;
            if (alive.expired()) {
              return;
            }
            if (action && *action == protocol::kPasteTargetPaste) {
              Paste(text, done);
              return;
            }
            if (action && *action == protocol::kPasteTargetSearch) {
              PasteIntoCandidate(process, request, text, done);
              return;
            }
            done(protocol::kNoWritableInputMessage);
          });
    });
  });
}

void SelectionCapture::PasteIntoCandidate(unsigned long process, const EncodableMap& facts,
                                          const std::string& text,
                                          std::function<void(std::optional<std::string>)> done) {
  std::weak_ptr<char> alive = alive_;
  main_thread::Background([this, alive, process, facts, text, done]() {
    uia_selection::CandidateSearch search = uia_selection::FindWritableInputs(process);
    main_thread::Post([this, alive, facts, text, done, search]() mutable {
      if (alive.expired()) {
        return;
      }
      facts[EncodableValue("candidates")] = EncodableValue(search.count);
      delegate_.request(
          protocol::kPasteTarget, EncodableValue(facts),
          [this, alive, text, done, search](const EncodableValue* reply) {
            const auto* action = reply ? std::get_if<std::string>(reply) : nullptr;
            if (alive.expired()) {
              return;
            }
            if (!action || *action != protocol::kPasteTargetFocusCandidate || !search.first) {
              done(protocol::kNoWritableInputMessage);
              return;
            }
            main_thread::Background([this, alive, text, done, search]() {
              bool focused = uia_selection::Focus(search.first);
              main_thread::Post([this, alive, text, done, focused]() {
                if (alive.expired()) {
                  return;
                }
                if (!focused) {
                  done(protocol::kNoWritableInputMessage);
                  return;
                }
                main_thread::After(kSettleMilliseconds, [this, alive, text, done]() {
                  if (!alive.expired()) {
                    Paste(text, done);
                  }
                });
              });
            });
          });
    });
  });
}

void SelectionCapture::Paste(const std::string& text,
                             std::function<void(std::optional<std::string>)> done) {
  auto snapshot = std::make_shared<clipboard::Snapshot>(clipboard::Capture());
  if (!clipboard::SetText(text)) {
    clipboard::Restore(*snapshot);
    done("无法写入剪贴板，未替换原文。");
    return;
  }
  unsigned long written = clipboard::Sequence();
  synthetic_input::SendControlShortcut('V');
  main_thread::After(kPasteRestoreMilliseconds, [snapshot, written, done]() {
    if (clipboard::Sequence() == written) {
      clipboard::Restore(*snapshot);
    }
    done(std::nullopt);
  });
}

void SelectionCapture::ShowInputFailure(const std::string& session_id, const std::string& message) {
  if (session_ == session_id && input_anchor_) {
    bubble_.ShowFailure(message, *input_anchor_);
  }
}

void SelectionCapture::Record(SelectionMonitor::Recorder recorder) {
  monitor_->Record(std::move(recorder));
}

void SelectionCapture::Observe(unsigned long process) {
  observed_process_ = process;
  watcher_.Watch(process);
}

void SelectionCapture::StopObserving() {
  observed_process_ = 0;
  watcher_.Stop();
}
