#include "credentials.h"

#include <windows.h>
#include <wincred.h>

#include "json_codec.h"
#include "protocol.h"
#include "utils.h"

namespace credentials {
namespace {

std::wstring Target(const std::string& id) {
  return std::wstring(protocol::kCredentialTargetPrefix) + Utf16FromUtf8(id);
}

std::string SystemError(DWORD code) {
  wchar_t* message = nullptr;
  ::FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                       FORMAT_MESSAGE_IGNORE_INSERTS,
                   nullptr, code, 0, reinterpret_cast<wchar_t*>(&message), 0,
                   nullptr);
  std::string text = message ? Utf8FromUtf16(message) : std::to_string(code);
  ::LocalFree(message);
  return text;
}

}

Lookup Read(const std::string& id, flutter::EncodableMap& value,
            std::string& error) {
  PCREDENTIALW credential = nullptr;
  std::wstring target = Target(id);
  if (!::CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
    DWORD code = ::GetLastError();
    if (code == ERROR_NOT_FOUND) {
      return Lookup::kMissing;
    }
    error = "无法读取凭据：" + SystemError(code);
    return Lookup::kFailed;
  }
  std::string blob(reinterpret_cast<const char*>(credential->CredentialBlob),
                   credential->CredentialBlobSize);
  ::CredFree(credential);
  auto parsed = json_codec::Parse(blob);
  const auto* map = parsed ? std::get_if<flutter::EncodableMap>(&*parsed) : nullptr;
  if (!map) {
    error = "凭据内容无效。";
    return Lookup::kFailed;
  }
  value = *map;
  return Lookup::kFound;
}

bool Store(const std::string& id, const std::optional<flutter::EncodableMap>& value,
           std::string& error) {
  std::wstring target = Target(id);
  if (!value) {
    if (::CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0) ||
        ::GetLastError() == ERROR_NOT_FOUND) {
      return true;
    }
    error = "无法删除凭据：" + SystemError(::GetLastError());
    return false;
  }
  std::string blob = json_codec::Stringify(flutter::EncodableValue(*value));
  if (blob.size() > CRED_MAX_CREDENTIAL_BLOB_SIZE) {
    error = "凭据内容超过 Windows 凭据管理器的长度上限。";
    return false;
  }
  CREDENTIALW credential = {};
  credential.Type = CRED_TYPE_GENERIC;
  credential.TargetName = target.data();
  credential.CredentialBlobSize = static_cast<DWORD>(blob.size());
  credential.CredentialBlob = reinterpret_cast<LPBYTE>(blob.data());
  credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
  if (!::CredWriteW(&credential, 0)) {
    error = "无法保存凭据：" + SystemError(::GetLastError());
    return false;
  }
  return true;
}

}
