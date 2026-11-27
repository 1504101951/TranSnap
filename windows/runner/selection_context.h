#ifndef RUNNER_SELECTION_CONTEXT_H_
#define RUNNER_SELECTION_CONTEXT_H_

#include <string>
#include <vector>

namespace selection_context {

inline constexpr char kText[] = "text";
inline constexpr char kNonText[] = "nonText";
inline constexpr char kWeb[] = "web";
inline constexpr char kOther[] = "other";
inline constexpr int kMaximumAncestors = 64;

const char* Kind(long control_type, const std::wstring& framework_id);

bool ShouldReadSelectedText(const std::vector<std::string>& context);

}

#endif
