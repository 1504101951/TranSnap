#include "selection_watcher.h"

#include <windows.h>
#include <uiautomation.h>
#include <wrl/client.h>
#include <wrl/implements.h>

#include <atomic>
#include <mutex>
#include <utility>

#include "main_thread.h"

namespace {

using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;

class Handler : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IUIAutomationFocusChangedEventHandler,
                                    IUIAutomationEventHandler> {
 public:
  explicit Handler(std::function<void()> fire) : fire_(std::move(fire)) {}

  IFACEMETHODIMP HandleFocusChangedEvent(IUIAutomationElement*) override {
    fire_();
    return S_OK;
  }

  IFACEMETHODIMP HandleAutomationEvent(IUIAutomationElement*, EVENTID) override {
    fire_();
    return S_OK;
  }

 private:
  std::function<void()> fire_;
};

}

struct SelectionWatcher::State {
  std::mutex mutex;
  std::atomic<unsigned> generation{0};
  ComPtr<IUIAutomation> automation;
  ComPtr<Handler> handler;
};

SelectionWatcher::SelectionWatcher(std::function<void()> changed)
    : state_(std::make_shared<State>()), changed_(std::move(changed)) {}

SelectionWatcher::~SelectionWatcher() {
  Stop();
}

void SelectionWatcher::Watch(unsigned long process) {
  unsigned generation = 0;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    generation = ++state_->generation;
  }
  std::weak_ptr<char> alive = alive_;
  std::function<void()> changed = changed_;
  std::shared_ptr<State> state = state_;
  main_thread::Background([state, process, generation, alive, changed]() {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->generation != generation) {
      return;
    }
    if (!state->automation) {
      ::CoCreateInstance(__uuidof(CUIAutomation8), nullptr, CLSCTX_INPROC_SERVER,
                         IID_PPV_ARGS(&state->automation));
    }
    if (!state->automation) {
      return;
    }
    state->automation->RemoveAllEventHandlers();
    std::weak_ptr<State> weak_state = state;
    state->handler = Microsoft::WRL::Make<Handler>([weak_state, generation, alive, changed]() {
      auto current = weak_state.lock();
      if (!current || current->generation != generation) {
        return;
      }
      main_thread::Post([alive, changed]() {
        if (!alive.expired()) {
          changed();
        }
      });
    });
    ComPtr<IUIAutomationElement> focused;
    int owner = 0;
    state->automation->AddFocusChangedEventHandler(nullptr, state->handler.Get());
    if (SUCCEEDED(state->automation->GetFocusedElement(&focused)) && focused &&
        SUCCEEDED(focused->get_CurrentProcessId(&owner)) &&
        static_cast<unsigned long>(owner) == process) {
      state->automation->AddAutomationEventHandler(UIA_Text_TextSelectionChangedEventId,
                                                   focused.Get(), TreeScope_Element, nullptr,
                                                   state->handler.Get());
    }
  });
}

void SelectionWatcher::Stop() {
  std::shared_ptr<State> state = state_;
  unsigned generation = 0;
  {
    std::lock_guard<std::mutex> lock(state->mutex);
    generation = ++state->generation;
  }
  main_thread::Background([state, generation]() {
    std::lock_guard<std::mutex> lock(state->mutex);
    if (state->generation != generation || !state->automation) {
      return;
    }
    state->automation->RemoveAllEventHandlers();
    state->handler = nullptr;
  });
}
