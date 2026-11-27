#include "uia_selection.h"

#include <windows.h>
#include <uiautomation.h>
#include <wrl/client.h>

#include "selection_context.h"
#include "utils.h"

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

std::optional<std::string> SelectedText(IUIAutomationElement* element) {
  ComPtr<IUIAutomationTextPattern> pattern;
  ComPtr<IUIAutomationTextRangeArray> ranges;
  int count = 0;
  if (FAILED(element->GetCurrentPatternAs(UIA_TextPatternId, IID_PPV_ARGS(&pattern))) ||
      !pattern || FAILED(pattern->GetSelection(&ranges)) || !ranges ||
      FAILED(ranges->get_Length(&count))) {
    return std::nullopt;
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
  }
  return text;
}

Read ReadOnce(IUIAutomation* automation, unsigned long process) {
  ComPtr<IUIAutomationElement> focused = FocusedElement(automation, process);
  if (!focused) {
    return {};
  }
  if (IsPassword(focused.Get())) {
    return {std::nullopt, {}, true};
  }
  std::vector<std::string> focused_context = Context(automation, focused.Get());
  if (!selection_context::ShouldReadSelectedText(focused_context)) {
    return {std::nullopt, focused_context, false};
  }
  ComPtr<IUIAutomationElement> current = focused;
  for (int step = 0; current && step < selection_context::kMaximumAncestors; ++step) {
    auto text = SelectedText(current.Get());
    if (text) {
      return {text, Context(automation, current.Get()), false};
    }
    current = Parent(automation, current.Get());
  }
  return {std::nullopt, focused_context, false};
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

}
