#include "speech_service.h"

#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Core.h>
#include <winrt/Windows.Media.Playback.h>
#include <winrt/Windows.Media.SpeechSynthesis.h>
#include <winrt/Windows.Storage.Streams.h>

#include <algorithm>
#include <atomic>
#include <cwctype>

#include "utils.h"

namespace {

using winrt::Windows::Media::Core::MediaSource;
using winrt::Windows::Media::Playback::MediaPlayer;
using winrt::Windows::Media::SpeechSynthesis::SpeechSynthesizer;
using winrt::Windows::Media::SpeechSynthesis::VoiceInformation;

std::wstring Lower(std::wstring text) {
  std::transform(text.begin(), text.end(), text.begin(),
                 [](wchar_t character) { return static_cast<wchar_t>(std::towlower(character)); });
  return text;
}

std::wstring PreferredTag(const std::string& language) {
  std::wstring tag = Lower(Utf16FromUtf8(language));
  std::replace(tag.begin(), tag.end(), L'_', L'-');
  if (tag == L"zh-hant" || tag == L"zh-tw" || tag == L"zh-hk") {
    return L"zh-tw";
  }
  if (tag == L"zh" || tag == L"zh-hans" || tag == L"zh-cn") {
    return L"zh-cn";
  }
  return tag;
}

VoiceInformation VoiceFor(const std::string& language) {
  std::wstring preferred = PreferredTag(language);
  std::wstring base = preferred.substr(0, preferred.find(L'-'));
  VoiceInformation fallback{nullptr};
  for (const auto& voice : SpeechSynthesizer::AllVoices()) {
    std::wstring tag = Lower(std::wstring(voice.Language()));
    if (tag == preferred || tag.rfind(preferred + L"-", 0) == 0) {
      return voice;
    }
    if (!fallback && tag.substr(0, tag.find(L'-')) == base) {
      fallback = voice;
    }
  }
  return fallback;
}

}

struct SpeechService::State {
  SpeechSynthesizer synthesizer;
  MediaPlayer player;
  std::wstring spoken_text;
  std::atomic<bool> speaking{false};
  std::atomic<unsigned long long> generation{0};
};

SpeechService::SpeechService() : state_(std::make_shared<State>()) {
  std::weak_ptr<State> weak = state_;
  state_->player.MediaEnded([weak](const MediaPlayer&, const auto&) {
    if (auto state = weak.lock()) {
      state->speaking = false;
    }
  });
}

SpeechService::~SpeechService() {
  Stop();
}

bool SpeechService::Toggle(const std::string& text, const std::string& language) {
  std::wstring wide = Utf16FromUtf8(text);
  bool repeating = state_->speaking && state_->spoken_text == wide;
  Stop();
  if (repeating) {
    return false;
  }
  VoiceInformation voice = VoiceFor(language);
  if (voice) {
    state_->synthesizer.Voice(voice);
  }
  state_->spoken_text = wide;
  state_->speaking = true;
  unsigned long long generation = ++state_->generation;
  std::weak_ptr<State> weak = state_;
  state_->synthesizer.SynthesizeTextToStreamAsync(winrt::hstring(wide))
      .Completed([weak, generation](const auto& operation, auto status) {
        auto state = weak.lock();
        if (!state || state->generation != generation) {
          return;
        }
        if (status != winrt::Windows::Foundation::AsyncStatus::Completed) {
          state->speaking = false;
          return;
        }
        auto stream = operation.GetResults();
        state->player.Source(MediaSource::CreateFromStream(stream, stream.ContentType()));
        state->player.Play();
      });
  return true;
}

void SpeechService::Stop() {
  ++state_->generation;
  state_->speaking = false;
  state_->spoken_text.clear();
  state_->player.Pause();
  state_->player.Source(nullptr);
}
