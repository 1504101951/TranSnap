#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

built_app="build/macos/Build/Products/Release/TranSnap.app"
archive="dist/TranSnap.zip"
identity="${TRANSNAP_SIGN_IDENTITY:-TranSnap Local Signing}"
bundle_id="com.coolyang.transnap"
target="/Applications/TranSnap.app"
legacy="$HOME/Applications/TranSnap.app"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
package_stage=""
install_stage=""
candidate_file=""
normalized_file=""
ordered_file=""
build_pid=""
if [[ "$identity" == "-" ]]; then
  echo "禁止ad-hoc交付；请配置固定代码签名证书。" >&2
  exit 1
fi
identities="$(security find-identity -v -p codesigning)"
if ! /usr/bin/grep -Fq "\"$identity\"" <<< "$identities"; then
  echo "未找到有效代码签名身份：$identity。请在钥匙串中完成证书和私钥配置。" >&2
  exit 1
fi

is_target_app_name() {
  local base
  base="$(basename "$1")"
  base="$(printf '%s' "$base" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  [[ "$base" == "transnap.app" ]] && return 0
  [[ "$base" == transnap\ *.app ]]
}

should_remove_app() {
  local app="$1"
  local id
  is_target_app_name "$app" || return 1
  [[ -d "$app" ]] || return 1
  id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$id" == "$bundle_id" ]]; then
    return 0
  fi
  [[ -z "$id" && -f "$app/Contents/MacOS/TranSnap" ]]
}

list_app_candidates() {
  local scope="$1"
  local path root
  local -a roots
  if [[ "$scope" == "external" ]]; then
    mdfind "kMDItemCFBundleIdentifier == '${bundle_id}'" 2>/dev/null || true
    mdfind 'kMDItemFSName == "TranSnap.app"' 2>/dev/null || true
    for path in /Applications/TranSnap.app "$HOME/Applications/TranSnap.app"; do
      if [[ -e "$path" ]]; then
        printf '%s\n' "$path"
      fi
    done
    roots=(
      "$HOME/.Trash"
      "$HOME/Library/Developer/Xcode/DerivedData"
      /private/tmp
      /tmp
      /var/folders
    )
  else
    roots=("$PWD/build" "$PWD/dist")
  fi
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    find "$root" \( -iname 'TranSnap.app' -o -iname 'TranSnap *.app' \) -prune -print 2>/dev/null || true
  done
  [[ "$scope" == "external" ]] || return 0
  "$lsregister" -dump 2>/dev/null | /usr/bin/awk -v bundle="$bundle_id" '
    function emit() {
      if (matched && path != "") print path
    }
    /^--------------------------------------------------------------------------------$/ { emit(); path=""; matched=0; next }
    /^path:[[:space:]]/ {
      line = $0
      sub(/^path:[[:space:]]+/, "", line)
      sub(/[[:space:]]+\(0x[0-9A-Fa-f]+\)$/, "", line)
      path = line
      next
    }
    /^identifier:[[:space:]]/ {
      if ($2 == bundle) matched = 1
      next
    }
    END { emit() }
  '
}

remove_app_copy() {
  local app="$1"
  local escaped
  if [[ -d "$app" ]]; then
    echo "删除旧副本：$app"
    "$lsregister" -u "$app" >/dev/null 2>&1 || true
    removed_registration=1
    if ! rm -rf "$app" 2>/dev/null; then
      escaped="$(printf '%q' "$app")"
      osascript -e "do shell script \"/bin/rm -rf -- $escaped\" with administrator privileges"
    fi
    if [[ -e "$app" ]]; then
      echo "无法删除：$app" >&2
      exit 1
    fi
    return 0
  fi
  echo "注销已不在磁盘上的登记：$app"
  "$lsregister" -u "$app" >/dev/null 2>&1 || true
  removed_registration=1
}

remove_existing_copies() {
  local scope="$1"
  local path line physical prefix skipped build_physical stage_physical
  local -a skip_prefixes
  if [[ "$scope" != "build" && "$scope" != "external" ]]; then
    echo "未知副本清理范围：$scope" >&2
    exit 1
  fi
  removed_registration=0
  if [[ "$scope" == "build" ]]; then
    echo "正在清除构建目录中的旧副本…"
  else
    echo "正在查找本机其余 TranSnap 副本…"
  fi
  candidate_file="$(mktemp)"
  normalized_file="$(mktemp)"
  ordered_file="$(mktemp)"
  list_app_candidates "$scope" > "$candidate_file"
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" ]] || continue
    if [[ -d "$path" ]]; then
      physical="$(cd "$path" && pwd -P)" || physical="$path"
    else
      physical="$path"
    fi
    printf '%s\n' "$physical"
  done < "$candidate_file" | sort -u > "$normalized_file"
  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -n "$path" ]] || continue
    printf '%07d %s\n' "${#path}" "$path"
  done < "$normalized_file" | sort -nr > "$ordered_file"
  skip_prefixes=()
  if [[ "$scope" == "external" ]]; then
    skip_prefixes+=("$PWD/build")
    if [[ -d "$PWD/build" ]]; then
      build_physical="$(cd "$PWD/build" && pwd -P)"
      [[ "$build_physical" == "$PWD/build" ]] || skip_prefixes+=("$build_physical")
    fi
    if [[ -n "$package_stage" && -d "$package_stage" ]]; then
      skip_prefixes+=("$package_stage")
      stage_physical="$(cd "$package_stage" && pwd -P)"
      [[ "$stage_physical" == "$package_stage" ]] || skip_prefixes+=("$stage_physical")
    fi
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    path="${line:8}"
    [[ -n "$path" ]] || continue
    case "$path" in
      /Volumes/.timemachine/*|*/Backups.backupdb/*|*/.MobileBackups/*)
        echo "跳过备份卷：$path" >&2
        continue
        ;;
    esac
    skipped=0
    if [[ "${#skip_prefixes[@]}" -gt 0 ]]; then
      for prefix in "${skip_prefixes[@]}"; do
        case "$path" in
          "$prefix"|"$prefix"/*) skipped=1 ;;
        esac
      done
    fi
    [[ "$skipped" == 0 ]] || continue
    if [[ -d "$path" ]]; then
      if should_remove_app "$path"; then
        remove_app_copy "$path"
      else
        echo "跳过非本应用副本：$path" >&2
      fi
    elif is_target_app_name "$path"; then
      remove_app_copy "$path"
    fi
  done < "$ordered_file"
  if [[ "$removed_registration" == 1 ]]; then
    "$lsregister" -gc >/dev/null
  fi
  rm -f "$candidate_file" "$normalized_file" "$ordered_file"
  candidate_file=""
  normalized_file=""
  ordered_file=""
}

install_bundle() {
  local src="$1"
  local dest="$2"
  if [[ -e "$dest" ]]; then
    rm -rf "$dest" 2>/dev/null || true
  fi
  if ditto "$src" "$dest" 2>/dev/null; then
    return 0
  fi
  osascript -e "do shell script \"/bin/rm -rf '$dest' && /usr/bin/ditto '$src' '$dest'\" with administrator privileges"
}

kill_process_tree() {
  local pid="$1"
  local child
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  [[ "$pid" -gt 1 ]] || return 0
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    kill_process_tree "$child"
  done < <(pgrep -P "$pid" || true)
  kill -9 "$pid" 2>/dev/null || true
}

cleanup_on_exit() {
  local status=$?
  if [[ -n "$build_pid" ]]; then
    kill_process_tree "$build_pid"
    wait "$build_pid" 2>/dev/null || true
    build_pid=""
  fi
  if [[ "$status" != 0 && -n "$install_stage" && -d "$install_stage/previous" ]]; then
    install_bundle "$install_stage/previous" "$target" || true
  fi
  if [[ -n "$install_stage" ]]; then
    rm -rf "$install_stage"
  fi
  if [[ -n "$package_stage" && -d "$package_stage/TranSnap.app" ]]; then
    "$lsregister" -u "$package_stage/TranSnap.app" >/dev/null 2>&1 || true
  fi
  if [[ -d "$built_app" ]]; then
    "$lsregister" -u "$PWD/$built_app" >/dev/null 2>&1 || true
  fi
  if [[ -n "$package_stage" ]]; then
    rm -rf "$package_stage"
  fi
  rm -rf "$built_app"
  [[ -n "$candidate_file" ]] && rm -f "$candidate_file"
  [[ -n "$normalized_file" ]] && rm -f "$normalized_file"
  [[ -n "$ordered_file" ]] && rm -f "$ordered_file"
  exit "$status"
}

quit_running_apps() {
  local pid waited
  if ! pgrep -x TranSnap >/dev/null; then
    return 0
  fi
  echo "正在强制退出 TranSnap…"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    kill -9 "$pid" 2>/dev/null || true
  done < <(pgrep -x TranSnap || true)
  waited=0
  while pgrep -x TranSnap >/dev/null; do
    if [[ "$waited" -ge 5 ]]; then
      echo "无法强制退出 TranSnap。" >&2
      exit 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

quit_running_apps
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

remove_existing_copies build

mkdir -p dist
package_stage="$(mktemp -d dist/package.XXXXXX)"
flutter build macos --release &
build_pid=$!
remove_existing_copies external
build_status=0
wait "$build_pid" || build_status=$?
build_pid=""
[[ "$build_status" == 0 ]] || exit "$build_status"
ditto "$built_app" "$package_stage/TranSnap.app"
sign_flags=(--force --sign "$identity")
if [[ "$identity" == "Developer ID Application:"* ]]; then
  sign_flags+=(--options runtime --timestamp)
else
  sign_flags+=(--timestamp=none)
fi
while IFS= read -r -d '' library; do
  codesign "${sign_flags[@]}" "$library"
done < <(find "$package_stage/TranSnap.app/Contents" -type f -name '*.dylib' -print0)
for framework in "$package_stage/TranSnap.app/Contents/Frameworks/"*.framework; do
  codesign "${sign_flags[@]}" "$framework"
done
codesign "${sign_flags[@]}" --identifier "$bundle_id.mcp" "$package_stage/TranSnap.app/Contents/MacOS/transnap-mcp"
codesign "${sign_flags[@]}" --entitlements macos/Runner/Release.entitlements "$package_stage/TranSnap.app"
codesign --verify --deep --strict "$package_stage/TranSnap.app"
requirement="$(codesign -d -r- "$package_stage/TranSnap.app" 2>&1)"
printf '%s\n' "$requirement"
if /usr/bin/grep -q 'designated.*cdhash' <<< "$requirement"; then
  echo "签名身份仍绑定cdhash，拒绝发布。" >&2
  exit 1
fi
ditto -c -k --sequesterRsrc --keepParent "$package_stage/TranSnap.app" "$package_stage/TranSnap.zip"
mv -f "$package_stage/TranSnap.zip" "$archive"
echo "Archive: $PWD/$archive"

quit_running_apps
install_stage="$(mktemp -d "${TMPDIR:-/tmp}/transnap-install.XXXXXX")"
ditto -x -k "$archive" "$install_stage"
codesign --verify --deep --strict "$install_stage/TranSnap.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$install_stage/TranSnap.app/Contents/Info.plist")" == "$bundle_id" ]] || {
  echo "归档包含其他应用，停止安装。" >&2
  exit 1
}

if [[ -e "$target" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$target/Contents/Info.plist")" == "$bundle_id" ]] || {
    echo "目标位置存在其他应用，停止安装。" >&2
    exit 1
  }
  mv "$target" "$install_stage/previous" 2>/dev/null || {
    ditto "$target" "$install_stage/previous"
    rm -rf "$target" 2>/dev/null || osascript -e "do shell script \"/bin/rm -rf '$target'\" with administrator privileges"
  }
fi
install_bundle "$install_stage/TranSnap.app" "$target"
if [[ -d "$legacy" ]]; then
  legacy_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$legacy/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$legacy_id" == "$bundle_id" ]]; then
    "$lsregister" -u "$legacy" >/dev/null || true
    rm -rf "$legacy"
  fi
fi
"$lsregister" -f "$target"
echo "已安装：$target"
open -R "$target"
