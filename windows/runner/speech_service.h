#ifndef RUNNER_SPEECH_SERVICE_H_
#define RUNNER_SPEECH_SERVICE_H_

#include <memory>
#include <string>

class SpeechService {
 public:
  SpeechService();
  ~SpeechService();

  bool Toggle(const std::string& text, const std::string& language);

  void Stop();

 private:
  struct State;
  std::shared_ptr<State> state_;
};

#endif
