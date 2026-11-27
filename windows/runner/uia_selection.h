#ifndef RUNNER_UIA_SELECTION_H_
#define RUNNER_UIA_SELECTION_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "bubble_layout.h"

namespace uia_selection {

struct Read {
  std::optional<std::string> text;
  std::vector<std::string> context;
  bool secure = false;
  std::vector<int> owner_id;
  std::optional<bubble_layout::Rect> selection_rect;
  std::optional<bubble_layout::Rect> owner_rect;
};

struct PasteFacts {
  bool has_focus = false;
  bool focus_is_selection = false;
  bool focus_is_text_input = false;
  bool focus_is_secure = false;
};

struct Candidate;

struct CandidateSearch {
  int count = 0;
  std::shared_ptr<Candidate> first;
};

unsigned long ForegroundProcess();

Read ReadSelection(unsigned long process);

bool FocusIsSecure(unsigned long process);

bool PermitsKeyboardTrigger(unsigned long process);

bool IsUsable(const std::optional<std::string>& text);

bool FocusIsTextInput(unsigned long process);

bubble_layout::InputAnchor Anchor(unsigned long process, const Read& read);

PasteFacts Facts(unsigned long process, const std::vector<int>& selection_id);

CandidateSearch FindWritableInputs(unsigned long process);

bool Focus(const std::shared_ptr<Candidate>& candidate);

}

#endif
