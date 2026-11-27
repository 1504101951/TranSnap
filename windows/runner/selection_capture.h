#ifndef RUNNER_SELECTION_CAPTURE_H_
#define RUNNER_SELECTION_CAPTURE_H_

#include <flutter/encodable_value.h>

#include <functional>
#include <memory>
#include <optional>
#include <string>

#include "bubble_layout.h"
#include "input_bubble.h"
#include "selection_monitor.h"
#include "selection_watcher.h"

struct HWINEVENTHOOK__;

class SelectionCapture {
 public:
  struct Delegate {
    std::function<void(const char* method, flutter::EncodableValue arguments,
                       SelectionMonitor::Reply reply)>
        request;
    std::function<void(const flutter::EncodableMap& event)> emit;
    std::function<bool()> automatic;
    std::function<bool(const std::wstring& executable)> excluded;
    std::function<void(const std::string& session_id)> hide_overlay;
    std::function<bool(long x, long y)> overlay_contains;
    std::function<bool()> dark;
  };

  explicit SelectionCapture(Delegate delegate);
  ~SelectionCapture();

  SelectionCapture(const SelectionCapture&) = delete;
  SelectionCapture& operator=(const SelectionCapture&) = delete;

  void Capture(const std::string& gesture);
  void Invalidate(const char* event_type);
  void Cancel(const char* event_type);
  void Retain(const std::string& session_id);
  bool Hide(const std::string& session_id);
  bool IsCurrent(const std::string& session_id) const;

  struct Outcome {
    std::optional<std::string> text;
    bool secure = false;
    bool keyboard_candidate = false;
    std::vector<int> owner_id;
    std::optional<bubble_layout::InputAnchor> anchor;
  };

  void ReadForTranslation(const std::string& session_id, std::function<void(const Outcome&)> done);
  void Replace(const std::string& session_id, const std::string& text,
               std::function<void(std::optional<std::string> failure)> done);
  void ShowInputFailure(const std::string& session_id, const std::string& message);
  void Record(SelectionMonitor::Recorder recorder);
  void ForegroundChanged(unsigned long process);

 private:
  void Validate();
  void Observe(unsigned long process);
  void StopObserving();
  void Decide(const char* method, flutter::EncodableMap request,
              std::function<void(bool)> done);
  struct Pending {
    std::string gesture;
    unsigned generation;
    unsigned long process;
    std::string source_name;
  };

  void ReadText(unsigned long process, bool allow_copy, bool keyboard, bool input,
                std::function<void(const Outcome&)> done);
  void ReadInput(const Pending& pending);
  void Paste(const std::string& text, std::function<void(std::optional<std::string>)> done);
  void PasteIntoCandidate(unsigned long process, const flutter::EncodableMap& facts,
                          const std::string& text,
                          std::function<void(std::optional<std::string>)> done);
  void Copy(unsigned long process, flutter::EncodableMap request, Outcome base,
            std::function<void(const Outcome&)> done);
  void Finish(const Pending& pending, const Outcome& outcome);
  void Emit(const std::string& gesture, unsigned long process, const std::string& source_name,
            const std::string& text, const char* read_failure,
            const std::optional<bubble_layout::InputAnchor>& anchor,
            const std::vector<int>& input_selection);

  Delegate delegate_;
  std::unique_ptr<SelectionMonitor> monitor_;
  InputBubble bubble_;
  SelectionWatcher watcher_;
  std::optional<bubble_layout::InputAnchor> input_anchor_;
  std::vector<int> input_selection_;
  HWINEVENTHOOK__* foreground_hook_ = nullptr;
  std::shared_ptr<char> alive_ = std::make_shared<char>();
  std::optional<std::string> session_;
  unsigned long source_process_ = 0;
  unsigned long observed_process_ = 0;
  unsigned long foreground_process_ = 0;
  bool retains_result_ = false;
  unsigned generation_ = 0;
  unsigned validation_ = 0;
};

#endif
