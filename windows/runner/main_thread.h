#ifndef RUNNER_MAIN_THREAD_H_
#define RUNNER_MAIN_THREAD_H_

#include <functional>

struct HWND__;

namespace main_thread {

void Start();

void Stop();

HWND__* Window();

void Post(std::function<void()> task);

void Background(std::function<void()> task);

void After(unsigned milliseconds, std::function<void()> task);

}

#endif
