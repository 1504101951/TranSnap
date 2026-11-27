#include "selection_context.h"

#include <algorithm>
#include <iterator>

namespace selection_context {
namespace {

constexpr long kButton = 50000;
constexpr long kComboBox = 50003;
constexpr long kEdit = 50004;
constexpr long kImage = 50006;
constexpr long kMenu = 50009;
constexpr long kMenuBar = 50010;
constexpr long kMenuItem = 50011;
constexpr long kTab = 50018;
constexpr long kToolBar = 50021;
constexpr long kTree = 50023;
constexpr long kTreeItem = 50024;
constexpr long kDataGrid = 50028;
constexpr long kDataItem = 50029;
constexpr long kDocument = 50030;
constexpr long kHeaderItem = 50035;
constexpr long kTable = 50036;

constexpr long kTextTypes[] = {kEdit, kComboBox, kDocument};
constexpr long kNonTextTypes[] = {kTree,  kTreeItem, kTable,   kDataGrid, kDataItem, kHeaderItem,
                                  kImage, kButton,   kMenu,    kMenuBar,  kMenuItem, kToolBar,
                                  kTab};
const wchar_t* const kWebFrameworks[] = {L"Chrome", L"Gecko"};

template <typename T, typename V>
bool Contains(const T& values, const V& value) {
  return std::find(std::begin(values), std::end(values), value) != std::end(values);
}

}

const char* Kind(long control_type, const std::wstring& framework_id) {
  if (control_type == kDocument && Contains(kWebFrameworks, framework_id)) {
    return kWeb;
  }
  if (Contains(kTextTypes, control_type)) {
    return kText;
  }
  if (Contains(kNonTextTypes, control_type)) {
    return kNonText;
  }
  return kOther;
}

bool ShouldReadSelectedText(const std::vector<std::string>& context) {
  for (const auto& kind : context) {
    if (kind == kNonText) {
      return false;
    }
    if (kind == kText || kind == kWeb) {
      return true;
    }
  }
  return true;
}

}
