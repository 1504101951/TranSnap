#include "file_dialogs.h"

#include <shlobj.h>
#include <shobjidl.h>
#include <windows.h>
#include <wrl/client.h>

#include "text_encoding.h"


namespace file_dialogs {
namespace {

using Microsoft::WRL::ComPtr;

std::optional<std::filesystem::path> Show(IFileDialog* dialog, std::string& error) {
  HRESULT shown = dialog->Show(GetActiveWindow());
  if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    return std::nullopt;
  }
  ComPtr<IShellItem> item;
  PWSTR path = nullptr;
  if (FAILED(shown) || FAILED(dialog->GetResult(&item)) ||
      FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
    error = "无法打开文件对话框。";
    return std::nullopt;
  }
  std::filesystem::path result(path);
  CoTaskMemFree(path);
  return result;
}

}

std::optional<std::filesystem::path> ChooseGlossaryFile(std::string& error) {
  ComPtr<IFileOpenDialog> dialog;
  if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&dialog)))) {
    error = "无法打开文件对话框。";
    return std::nullopt;
  }
  const COMDLG_FILTERSPEC filters[] = {{L"术语表 (CSV、JSON)", L"*.csv;*.json"}};
  dialog->SetFileTypes(1, filters);
  dialog->SetOkButtonLabel(L"导入术语");
  return Show(dialog.Get(), error);
}

std::optional<std::filesystem::path> ChooseApplication(std::string& error) {
  ComPtr<IFileOpenDialog> dialog;
  if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&dialog)))) {
    error = "无法打开文件对话框。";
    return std::nullopt;
  }
  const COMDLG_FILTERSPEC filters[] = {{L"应用程序 (*.exe)", L"*.exe"}};
  dialog->SetFileTypes(1, filters);
  dialog->SetOkButtonLabel(L"排除此应用");
  ComPtr<IShellItem> folder;
  if (SUCCEEDED(SHGetKnownFolderItem(FOLDERID_ProgramFiles, KF_FLAG_DEFAULT, nullptr,
                                     IID_PPV_ARGS(&folder)))) {
    dialog->SetFolder(folder.Get());
  }
  return Show(dialog.Get(), error);
}

std::optional<std::filesystem::path> ChooseSaveLocation(
    const std::string& suggested_name,
    std::string& error) {
  ComPtr<IFileSaveDialog> dialog;
  if (FAILED(CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&dialog)))) {
    error = "无法打开文件对话框。";
    return std::nullopt;
  }
  std::wstring name = Utf16FromUtf8(suggested_name);
  bool json = std::filesystem::path(name).extension() == L".json";
  const COMDLG_FILTERSPEC filters[] = {
      json ? COMDLG_FILTERSPEC{L"JSON", L"*.json"} : COMDLG_FILTERSPEC{L"CSV", L"*.csv"}};
  dialog->SetFileTypes(1, filters);
  dialog->SetDefaultExtension(json ? L"json" : L"csv");
  dialog->SetFileName(name.c_str());
  return Show(dialog.Get(), error);
}

}
