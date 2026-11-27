#include "uia_selection.h"

#include <windows.h>
#include <uiautomation.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <deque>
#include <utility>

#include "selection_context.h"
#include "text_encoding.h"

namespace uia_selection {
namespace {

using Microsoft::WRL::ComPtr;

constexpr int kTimeoutMilliseconds = 1000;
constexpr DWORD kRetryDelays[] = {80, 180};

ComPtr<IUIAutomation> Automation() {
  ComPtr<IUIAutomation> automation;
  ::CoCreateInstance(__uuidof(CUIAutomation8), nullptr, CLSCTX_INPROC_SERVER,
                     IID_PPV_ARGS(&automation));
  ComPtr<IUIAutomation2> timed;
  if (automation && SUCCEEDED(automation.As(&timed))) {
    timed->put_ConnectionTimeout(kTimeoutMilliseconds);
    timed->put_TransactionTimeout(kTimeoutMilliseconds);
  }
  return automation;
}

ComPtr<IUIAutomationElement> FocusedElement(IUIAutomation* automation, unsigned long process) {
  ComPtr<IUIAutomationElement> focused;
  int owner = 0;
  if (FAILED(automation->GetFocusedElement(&focused)) || !focused ||
      FAILED(focused->get_CurrentProcessId(&owner)) || static_cast<unsigned long>(owner) != process) {
    return nullptr;
  }
  return focused;
}

bool IsPassword(IUIAutomationElement* element) {
  BOOL password = FALSE;
  return element && SUCCEEDED(element->get_CurrentIsPassword(&password)) && password;
}

ComPtr<IUIAutomationElement> Parent(IUIAutomation* automation, IUIAutomationElement* element) {
  ComPtr<IUIAutomationTreeWalker> walker;
  ComPtr<IUIAutomationElement> parent;
  if (SUCCEEDED(automation->get_RawViewWalker(&walker))) {
    walker->GetParentElement(element, &parent);
  }
  return parent;
}

std::vector<std::string> Context(IUIAutomation* automation, IUIAutomationElement* element) {
  std::vector<std::string> context;
  ComPtr<IUIAutomationElement> current = element;
  for (int step = 0; current && step < selection_context::kMaximumAncestors; ++step) {
    CONTROLTYPEID type = 0;
    BSTR framework = nullptr;
    current->get_CurrentControlType(&type);
    current->get_CurrentFrameworkId(&framework);
    context.push_back(selection_context::Kind(type, framework ? framework : L""));
    ::SysFreeString(framework);
    current = Parent(automation, current.Get());
  }
  return context;
}

std::vector<int> RuntimeId(IUIAutomationElement* element) {
  std::vector<int> id;
  SAFEARRAY* array = nullptr;
  if (!element || FAILED(element->GetRuntimeId(&array)) || !array) {
    return id;
  }
  LONG lower = 0;
  LONG upper = -1;
  ::SafeArrayGetLBound(array, 1, &lower);
  ::SafeArrayGetUBound(array, 1, &upper);
  for (LONG index = lower; index <= upper; ++index) {
    int value = 0;
    ::SafeArrayGetElement(array, &index, &value);
    id.push_back(value);
  }
  ::SafeArrayDestroy(array);
  return id;
}

std::optional<bubble_layout::Rect> ElementRect(IUIAutomationElement* element) {
  RECT bounds{};
  if (!element || FAILED(element->get_CurrentBoundingRectangle(&bounds)) ||
      bounds.right <= bounds.left || bounds.bottom <= bounds.top) {
    return std::nullopt;
  }
  return bubble_layout::Rect{static_cast<double>(bounds.left), static_cast<double>(bounds.top),
                             static_cast<double>(bounds.right - bounds.left),
                             static_cast<double>(bounds.bottom - bounds.top)};
}

void Include(std::optional<bubble_layout::Rect>& total, double left, double top, double width,
             double height) {
  if (width <= 0 && height <= 0) {
    return;
  }
  if (!total) {
    total = bubble_layout::Rect{left, top, width, height};
    return;
  }
  double right = std::max(total->left + total->width, left + width);
  double bottom = std::max(total->top + total->height, top + height);
  total->left = std::min(total->left, left);
  total->top = std::min(total->top, top);
  total->width = right - total->left;
  total->height = bottom - total->top;
}

bool ReadPattern(IUIAutomationElement* element, Read& read) {
  ComPtr<IUIAutomationTextPattern> pattern;
  ComPtr<IUIAutomationTextRangeArray> ranges;
  int count = 0;
  if (FAILED(element->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&pattern))) ||
      !pattern || FAILED(pattern->GetSelection(&ranges)) || !ranges ||
      FAILED(ranges->get_Length(&count))) {
    return false;
  }
  std::string text;
  for (int index = 0; index < count; ++index) {
    ComPtr<IUIAutomationTextRange> range;
    BSTR part = nullptr;
    if (FAILED(ranges->GetElement(index, &range)) || FAILED(range->GetText(-1, &part))) {
      continue;
    }
    text += (text.empty() ? "" : "\n") + Utf8FromUtf16(part ? part : L"");
    ::SysFreeString(part);
    SAFEARRAY* rectangles = nullptr;
    if (FAILED(range->GetBoundingRectangles(&rectangles)) || !rectangles) {
      continue;
    }
    double* values = nullptr;
    LONG upper = -1;
    ::SafeArrayGetUBound(rectangles, 1, &upper);
    if (SUCCEEDED(::SafeArrayAccessData(rectangles, reinterpret_cast<void**>(&values)))) {
      for (LONG offset = 0; offset + 3 <= upper; offset += 4) {
        Include(read.selection_rect, values[offset], values[offset + 1], values[offset + 2],
                values[offset + 3]);
      }
      ::SafeArrayUnaccessData(rectangles);
    }
    ::SafeArrayDestroy(rectangles);
  }
  read.text = text;
  read.owner_id = RuntimeId(element);
  read.owner_rect = ElementRect(element);
  return true;
}

bool IsTextInput(IUIAutomationElement* element) {
  CONTROLTYPEID type = 0;
  BSTR framework = nullptr;
  element->get_CurrentControlType(&type);
  element->get_CurrentFrameworkId(&framework);
  bool text = std::string(selection_context::Kind(type, framework ? framework : L"")) ==
              selection_context::kText;
  ::SysFreeString(framework);
  return text;
}

bool IsWritableInput(IUIAutomationElement* element) {
  ComPtr<IUIAutomationValuePattern> value;
  BOOL read_only = TRUE;
  return IsTextInput(element) && !IsPassword(element) &&
         SUCCEEDED(element->GetCurrentPatternAs(UIA_ValuePatternId, IID_PPV_ARGS(&value))) && value &&
         SUCCEEDED(value->get_CurrentIsReadOnly(&read_only)) && !read_only;
}

Read ReadOnce(IUIAutomation* automation, unsigned long process) {
  ComPtr<IUIAutomationElement> focused = FocusedElement(automation, process);
  if (!focused) {
    return {};
  }
  if (IsPassword(focused.Get())) {
    Read secure;
    secure.secure = true;
    return secure;
  }
  std::vector<std::string> focused_context = Context(automation, focused.Get());
  if (!selection_context::ShouldReadSelectedText(focused_context)) {
    Read unreadable;
    unreadable.context = focused_context;
    return unreadable;
  }
  ComPtr<IUIAutomationElement> current = focused;
  for (int step = 0; current && step < selection_context::kMaximumAncestors; ++step) {
    Read read;
    if (ReadPattern(current.Get(), read)) {
      read.context = Context(automation, current.Get());
      return read;
    }
    current = Parent(automation, current.Get());
  }
  Read read;
  read.context = focused_context;
  return read;
}

}

unsigned long ForegroundProcess() {
  DWORD process = 0;
  ::GetWindowThreadProcessId(::GetForegroundWindow(), &process);
  return process;
}

bool IsUsable(const std::optional<std::string>& text) {
  return text && text->find_first_not_of(" \t\r\n") != std::string::npos;
}

Read ReadSelection(unsigned long process) {
  ComPtr<IUIAutomation> automation = Automation();
  if (!automation || ForegroundProcess() != process) {
    return {};
  }
  Read result = ReadOnce(automation.Get(), process);
  for (DWORD delay : kRetryDelays) {
    if (IsUsable(result.text) || result.secure) {
      break;
    }
    ::Sleep(delay);
    if (ForegroundProcess() != process) {
      return {};
    }
    result = ReadOnce(automation.Get(), process);
  }
  if (ForegroundProcess() != process) {
    return {};
  }
  return result;
}

bool FocusIsSecure(unsigned long process) {
  ComPtr<IUIAutomation> automation = Automation();
  return automation && IsPassword(FocusedElement(automation.Get(), process).Get());
}

bool PermitsKeyboardTrigger(unsigned long process) {
  ComPtr<IUIAutomation> automation = Automation();
  if (!automation || ForegroundProcess() != process) {
    return false;
  }
  ComPtr<IUIAutomationElement> focused = FocusedElement(automation.Get(), process);
  if (!focused) {
    return true;
  }
  return !IsPassword(focused.Get()) &&
         selection_context::ShouldReadSelectedText(Context(automation.Get(), focused.Get()));
}

struct Candidate {
  ComPtr<IUIAutomationElement> element;
};

bool FocusIsTextInput(unsigned long process) {
  ComPtr<IUIAutomation> automation = Automation();
  ComPtr<IUIAutomationElement> focused = automation ? FocusedElement(automation.Get(), process) : nullptr;
  return focused && !IsPassword(focused.Get()) && IsTextInput(focused.Get());
}

bubble_layout::InputAnchor Anchor(unsigned long process, const Read& read) {
  bubble_layout::InputAnchor anchor{};
  RECT window{};
  if (::GetWindowRect(::GetForegroundWindow(), &window) && window.right > window.left) {
    anchor.window = bubble_layout::Rect{static_cast<double>(window.left),
                                        static_cast<double>(window.top),
                                        static_cast<double>(window.right - window.left),
                                        static_cast<double>(window.bottom - window.top)};
  }
  std::optional<bubble_layout::Rect> selection = read.selection_rect ? read.selection_rect : read.owner_rect;
  if (!selection) {
    ComPtr<IUIAutomation> automation = Automation();
    ComPtr<IUIAutomationElement> focused =
        automation ? FocusedElement(automation.Get(), process) : nullptr;
    selection = ElementRect(focused.Get());
  }
  POINT cursor{};
  ::GetCursorPos(&cursor);
  anchor.selection = selection.value_or(bubble_layout::Rect{static_cast<double>(cursor.x),
                                                            static_cast<double>(cursor.y), 1, 1});
  return anchor;
}

PasteFacts Facts(unsigned long process, const std::vector<int>& selection_id) {
  PasteFacts facts;
  ComPtr<IUIAutomation> automation = Automation();
  ComPtr<IUIAutomationElement> focused = automation ? FocusedElement(automation.Get(), process) : nullptr;
  if (!focused) {
    return facts;
  }
  facts.has_focus = true;
  facts.focus_is_selection = !selection_id.empty() && RuntimeId(focused.Get()) == selection_id;
  facts.focus_is_text_input = IsTextInput(focused.Get());
  facts.focus_is_secure = IsPassword(focused.Get());
  return facts;
}

CandidateSearch FindWritableInputs(unsigned long process) {
  constexpr size_t kMaximumNodes = 2000;
  constexpr int kMaximumDepth = 40;
  constexpr auto kTimeout = std::chrono::seconds(1);
  CandidateSearch search;
  ComPtr<IUIAutomation> automation = Automation();
  ComPtr<IUIAutomationElement> root;
  ComPtr<IUIAutomationTreeWalker> walker;
  int owner = 0;
  if (!automation || FAILED(automation->ElementFromHandle(::GetForegroundWindow(), &root)) || !root ||
      FAILED(root->get_CurrentProcessId(&owner)) || static_cast<unsigned long>(owner) != process ||
      FAILED(automation->get_ControlViewWalker(&walker))) {
    return search;
  }
  auto deadline = std::chrono::steady_clock::now() + kTimeout;
  std::deque<std::pair<ComPtr<IUIAutomationElement>, int>> queue{{root, 0}};
  size_t visited = 0;
  while (!queue.empty() && visited < kMaximumNodes && search.count < 2) {
    if (std::chrono::steady_clock::now() >= deadline) {
      return CandidateSearch{};
    }
    auto [element, depth] = queue.front();
    queue.pop_front();
    ++visited;
    if (IsWritableInput(element.Get())) {
      ++search.count;
      if (!search.first) {
        search.first = std::make_shared<Candidate>(Candidate{element});
      }
      continue;
    }
    if (depth >= kMaximumDepth) {
      continue;
    }
    ComPtr<IUIAutomationElement> child;
    walker->GetFirstChildElement(element.Get(), &child);
    while (child) {
      queue.emplace_back(child, depth + 1);
      ComPtr<IUIAutomationElement> next;
      walker->GetNextSiblingElement(child.Get(), &next);
      child = next;
    }
  }
  return search;
}

bool Focus(const std::shared_ptr<Candidate>& candidate) {
  return candidate && candidate->element && SUCCEEDED(candidate->element->SetFocus());
}

}
