#!/bin/bash
# 无参数；先强制退出正在运行的 TranSnap，再清除 build 与 dist 里的旧副本。
# 随后同时构建 Release，并清除本机其余旧副本。成功后校验 ZIP，安装到访达「应用程序」。
# TRANSNAP_SIGN_IDENTITY 可指定固定签名证书，缺省 TranSnap Local Signing。
set -euo pipefail
cd "$(dirname "$0")/.."

built_app="build/macos/Build/Products/Release/TranSnap.app"
archive="dist/TranSnap.zip"
identity="${TRANSNAP_SIGN_IDENTITY:-TranSnap Local Signing}"
bundle_id="com.coolyang.transnap"
target="/Applications/TranSnap.app"
legacy="$HOME/Applications/TranSnap.app"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
# 打包暂存放在 dist 下，ZIP 才能在同一文件系统里原子替换。安装暂存放在临时目录，回滚时不碰已写好的 ZIP。
package_stage=""
install_stage=""
candidate_file=""
normalized_file=""
ordered_file=""
# 后台 flutter build 的进程号。空字符串表示没有待结束的构建。清理时先结束它，再删除正在写入的产物。
build_pid=""
# 身份缺失立即失败，避免产出每次更新都会失去TCC授权的临时签名包。先于删除执行，证书不可用时不碰已安装副本。
if [[ "$identity" == "-" ]]; then
  echo "禁止ad-hoc交付；请配置固定代码签名证书。" >&2
  exit 1
fi
identities="$(security find-identity -v -p codesigning)"
if ! /usr/bin/grep -Fq "\"$identity\"" <<< "$identities"; then
  echo "未找到有效代码签名身份：$identity。请在钥匙串中完成证书和私钥配置。" >&2
  exit 1
fi

# 作用：判断路径最后一级是不是本仓库的 App 包名。
# 参数：app 为任意路径。
# 返回：0 表示包名是 TranSnap.app，或废纸篓重名后追加的「空格 + 时间戳」；大小写不敏感。1 表示不是。
is_target_app_name() {
  local base
  base="$(basename "$1")"
  base="$(printf '%s' "$base" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  [[ "$base" == "transnap.app" ]] && return 0
  # 废纸篓遇到重名会把副本改成 “TranSnap 20-46-05-824.app”。
  [[ "$base" == transnap\ *.app ]]
}

# 作用：判断磁盘上的目录是否属于本应用，避免误删同名包。
# 参数：app 为已存在的 .app 目录。
# 返回：0 表示应删除；1 表示跳过。Bundle ID 匹配，或没有 Info.plist 但可执行文件是 TranSnap 时删除。
should_remove_app() {
  local app="$1"
  local id
  # is_target_app_name：只接受 TranSnap 包名。
  is_target_app_name "$app" || return 1
  [[ -d "$app" ]] || return 1
  id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$id" == "$bundle_id" ]]; then
    return 0
  fi
  # 测试中断会留下没有 Info.plist 的半成品，只认本仓库可执行文件。
  [[ -z "$id" && -f "$app/Contents/MacOS/TranSnap" ]]
}

# 作用：列出磁盘和 LaunchServices 中的候选路径。
# 参数：scope 为 build 或 external。build 只查本仓库 build 与 dist。external 查安装位置、废纸篓、用户 DerivedData、临时目录，以及 Spotlight 和启动服务登记。
# 返回：标准输出每行一个路径。Spotlight 负责已索引副本。固定安装路径直接判断。find 只补索引经常漏掉的废纸篓、DerivedData 和临时目录。
list_app_candidates() {
  local scope="$1"
  local path root
  local -a roots
  if [[ "$scope" == "external" ]]; then
    mdfind "kMDItemCFBundleIdentifier == '${bundle_id}'" 2>/dev/null || true
    mdfind 'kMDItemFSName == "TranSnap.app"' 2>/dev/null || true
    # 这两个位置是安装目标。直接判断，避免遍历整个 /Applications。
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
    # 第二种名字是废纸篓为重名副本追加的时间戳，Spotlight 经常不索引这些路径。
    find "$root" \( -iname 'TranSnap.app' -o -iname 'TranSnap *.app' \) -prune -print 2>/dev/null || true
  done
  [[ "$scope" == "external" ]] || return 0
  # 目录删除后启动服务仍保留测试副本和 dist/package.* 暂存路径，屏幕录制列表会继续显示它们。
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

# 作用：注销并删除一个已核对的应用副本。
# 参数：app 为 .app 路径。目录不存在时只注销 LaunchServices。
# 返回：无。目录仍在时以非零状态退出。当前用户删不掉时请求管理员权限。成功注销后把外层 removed_registration 置为 1。
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

# 作用：清除旧副本和启动服务里的残留登记。
# 参数：scope 为 build 或 external。build 在构建开始前处理本仓库 build 与 dist。external 在构建进行时处理其余位置，并跳过 build 与本次打包暂存。
# 返回：无。读写外层 candidate_file、normalized_file、ordered_file、removed_registration。找不到副本时照常继续打包，且不压缩 LaunchServices 数据库。
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
  # list_app_candidates：按 scope 汇总候选路径。
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
  # 候选名单收齐后再取物理路径。构建此时可能已经写出 TranSnap.app，前缀要把这份产物排除。
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
    # 构建正在写入 build/macos。external 不删除该目录，也不删除本次 dist 暂存。
    [[ "$skipped" == 0 ]] || continue
    if [[ -d "$path" ]]; then
      # should_remove_app：只放行本应用包。remove_app_copy：注销并删除。
      if should_remove_app "$path"; then
        remove_app_copy "$path"
      else
        echo "跳过非本应用副本：$path" >&2
      fi
    elif is_target_app_name "$path"; then
      # is_target_app_name：缺失路径只注销这两种包名。remove_app_copy：目录不在时只注销。
      remove_app_copy "$path"
    fi
  done < "$ordered_file"
  # -u 读不到已删除的 bundle；只有这次注销过，才压缩数据库丢掉这些登记。
  if [[ "$removed_registration" == 1 ]]; then
    "$lsregister" -gc >/dev/null
  fi
  rm -f "$candidate_file" "$normalized_file" "$ordered_file"
  candidate_file=""
  normalized_file=""
  ordered_file=""
}

# 作用：把 bundle 安装到目标路径。
# 参数：src 为待安装 bundle，dest 为访达「应用程序」目标。
# 返回：0 表示已写入。当前用户写不进去时请求管理员权限；管理员权限失败则命令失败。
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

# 作用：强制结束该进程及其子进程。
# 参数：pid 为进程号。
# 返回：无。进程已不在、或 pid 不是大于 1 的数字时忽略。
# 适用条件：脚本已经放弃这次 flutter build，需要立刻放开 build 目录。构建进程树退出后才能删除其中的产物；若改为等待构建自己收尾，再去掉强制结束。
kill_process_tree() {
  local pid="$1"
  local child
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  [[ "$pid" -gt 1 ]] || return 0
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    # kill_process_tree：先结束子进程，再结束当前进程。
    kill_process_tree "$child"
  done < <(pgrep -P "$pid" || true)
  kill -9 "$pid" 2>/dev/null || true
}

# 作用：退出时先结束尚未完成的构建，再回滚安装，并清掉打包暂存和构建产物。
# 参数：无。使用外层 build_pid、install_stage、package_stage、built_app 和临时列表文件。
# 返回：以进入 trap 时的状态码退出。回滚或删除暂存成功不能把失败变成成功退出。
cleanup_on_exit() {
  local status=$?
  if [[ -n "$build_pid" ]]; then
    # kill_process_tree：结束尚未退出的构建进程树，避免随后删掉正在写入的产物。
    kill_process_tree "$build_pid"
    wait "$build_pid" 2>/dev/null || true
    build_pid=""
  fi
  # install_bundle：安装失败时把替换前的 App 装回去。更早删掉的副本不在 previous 里。
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

# 作用：强制结束所有正在运行的 TranSnap，并等到进程消失。
# 参数：无。
# 返回：0 表示已经没有 TranSnap 进程。发出 SIGKILL 后 5 秒内进程仍在，则以状态码 1 退出。
quit_running_apps() {
  local pid waited
  if ! pgrep -x TranSnap >/dev/null; then
    return 0
  fi
  echo "正在强制退出 TranSnap…"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    # SIGKILL 不进入 applicationShouldTerminate，因此不会弹出「退出并丢弃当前采集？」。
    # 适用条件：打包前允许丢掉未保存采集。媒体流和临时目录的 shutdown 不会执行；若打包必须先做完这些清理，再改为正常退出。
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

# quit_running_apps：强制结束正在运行的 TranSnap。运行中的包删不干净，签名也会继续指向旧进程。
# 此时尚未注册 EXIT 清理；退出失败不会删掉已有构建产物。
quit_running_apps
# 只注册一次 EXIT。后注册的 trap 会替换先注册的，分开清理会留下另一个暂存目录。
# INT 与 TERM 转入 EXIT，以便结束仍在后台运行的构建。
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# remove_existing_copies：先清掉 build 与 dist 里的旧包。构建会写入 build/macos，不能等构建开始后再删这里。
remove_existing_copies build

# 每次从空目录打包，避免已移除的资源残留并破坏签名。
mkdir -p dist
package_stage="$(mktemp -d dist/package.XXXXXX)"
# 构建写入 build/macos。其余旧副本的查找和删除不进入该目录，因此与构建同时进行。
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
  # 对外分发身份使用安全时间戳；本地自签名证书不向时间戳服务请求公证能力。
  sign_flags+=(--options runtime --timestamp)
else
  sign_flags+=(--timestamp=none)
fi
# 从最内层签名实际动态库，再签框架与外层App，所有代码沿用同一身份。
while IFS= read -r -d '' library; do
  codesign "${sign_flags[@]}" "$library"
done < <(find "$package_stage/TranSnap.app/Contents" -type f -name '*.dylib' -print0)
for framework in "$package_stage/TranSnap.app/Contents/Frameworks/"*.framework; do
  codesign "${sign_flags[@]}" "$framework"
done
# MCP helper 是 Contents/MacOS 中的独立可执行文件，须在外层 App 之前以固定标识签名（#96）。
codesign "${sign_flags[@]}" --identifier "$bundle_id.mcp" "$package_stage/TranSnap.app/Contents/MacOS/transnap-mcp"
# Flutter 可独立更新 App.framework；重新签封外层 App，使嵌套资源摘要与实际内容一致。
codesign "${sign_flags[@]}" --entitlements macos/Runner/Release.entitlements "$package_stage/TranSnap.app"
codesign --verify --deep --strict "$package_stage/TranSnap.app"
requirement="$(codesign -d -r- "$package_stage/TranSnap.app" 2>&1)"
printf '%s\n' "$requirement"
# 权限身份必须由证书链与Bundle ID定义，不能再绑定某次构建的内容哈希。
if /usr/bin/grep -q 'designated.*cdhash' <<< "$requirement"; then
  echo "签名身份仍绑定cdhash，拒绝发布。" >&2
  exit 1
fi
ditto -c -k --sequesterRsrc --keepParent "$package_stage/TranSnap.app" "$package_stage/TranSnap.zip"
# 暂存文件位于同一文件系统，重命名原子替换已验证的归档。
mv -f "$package_stage/TranSnap.zip" "$archive"
echo "Archive: $PWD/$archive"

# quit_running_apps：构建耗时较久，安装前再强制结束期间重新打开的 TranSnap。
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
# install_bundle：把验签后的包写入访达「应用程序」。
install_bundle "$install_stage/TranSnap.app" "$target"
# 用户目录那份不会出现在访达「应用程序」里，留下会让录屏列表对不上正在运行的副本。
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
