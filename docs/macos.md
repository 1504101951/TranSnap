# macOS 构建、权限与本地签名说明

## 一、一键打包与安装

项目提供固定签名的一键构建脚本：

```bash
./scripts/package-and-install-macos.sh
```

执行前请注意：
1. **自动终止旧进程**：脚本会强制结束正在运行的 **TranSnap**（5 秒内未能退出则会中止流程），因此请提前保存未完成的录屏或长截图。
2. **清理与安装路径**：构建前会先清理本仓库 `build/`、`dist/` 及本机其他目录中残留的 `com.coolyang.transnap`（与历史测试产物）副本，完成 Release 构建、逐层严格签名、ZIP 打包并校验解包后再覆盖安装至 **`/Applications/TranSnap.app`**，交付压缩包输出到 `dist/TranSnap.zip`。
3. **环境变量覆写签名身份**（可选）：

```bash
TRANSNAP_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' ./scripts/package-and-install-macos.sh
```

未设置该变量时，脚本默认使用登录钥匙串中的 **`TranSnap Local Signing`**。脚本严禁回退到临时（ad-hoc）签名，证书缺失或私钥无权访问时会直接报错退出。

---

## 二、为什么必须使用固定代码签名？

macOS 通过 **TCC（Transparency, Consent, and Control）** 校验应用权限，系统不仅绑定 Bundle ID（`com.coolyang.transnap`），还会核对签名证书的 Designated Requirement（固定锚点）。

- 使用固定的自签名证书 `TranSnap Local Signing` 后，日常迭代重新打包覆盖 `/Applications/TranSnap.app`，**辅助功能**与**屏幕录制**权限通常会保持继承，无需每次重装都去系统设置里重新勾除再添加。
- 验证当前安装产物的签名要求：

```bash
codesign -d -r- --verbose=4 /Applications/TranSnap.app
```

---

## 三、创建本地签名证书并免除每次打包弹窗

如果本机尚未建立 `TranSnap Local Signing` 证书，或每次运行打包脚本时每个 `.dylib` / `.framework` 都被系统弹出「codesign 想要访问钥匙串中的密钥」确认框，按以下两步即可彻底解决：

### 第 1 步：创建并信任 `TranSnap Local Signing` 证书
1. 打开 **钥匙串访问**（可在聚焦搜索 `⌘Space` 输入「钥匙串访问」）。
2. 在顶部菜单栏选择 **钥匙串访问 → 证书助理 → 创建证书…**。
3. 填写配置：
   - **名称**：`TranSnap Local Signing`（必须严格一致）
   - **身份类型**：`自签名根证书`
   - **证书类型**：`代码签名`
   - 勾选 **让我覆盖这些默认值** → 下一步，可将有效期调整为较长天数（例如 `3650` 天），证书存储位置选择 **`登录`**，其余默认直到创建完成。
4. 在钥匙串访问左侧选择 **登录 → 我的证书**，找到 `TranSnap Local Signing` 并双击打开，展开 **信任** 分栏，将 **代码签名** 设为 **`始终信任`**，关闭后输入登录密码保存。

### 第 2 步：让 `codesign` 持久免弹窗访问私钥
打包脚本需要对内嵌框架、动态库、`transnap-mcp` 与主 App 逐一签名，若私钥访问控制列表（ACL）未放行，系统就会在每次调用 `/usr/bin/codesign` 时弹窗确认。

#### 方法 A：命令行一次性放行工具分区（推荐）
在终端执行以下单行命令（将 `<登录密码>` 替换为你的 macOS 用户登录密码）：

```bash
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "<登录密码>" ~/Library/Keychains/login.keychain-db
```

#### 方法 B：在钥匙串访问图形界面设置
1. 在 **登录 → 我的证书** 点开 `TranSnap Local Signing` 左侧展开箭头，找到底下的**私钥**并双击打开。
2. 切换到 **访问控制** 标签页。
3. 可选择 **允许所有应用程序访问此项目**；若需保持最小授权，点击左下角 `+` 号，按下 `⌘⇧G` 跳转到 `/usr/bin/codesign` 并添加。
4. 点击 **存储更改** 并确认一次密码，此后运行打包脚本不会再重复弹窗。

### 验证证书就绪

```bash
security find-identity -v -p codesigning
```

输出中出现 `"TranSnap Local Signing"` 即表示签名身份配置完成。

---

## 四、本地 MCP 配置与排查

- **helper 固定位置**：`/Applications/TranSnap.app/Contents/MacOS/transnap-mcp`（签名标识符为 `com.coolyang.transnap.mcp`）。
- **客户端集成**：在「设置 → MCP」开启 **允许 agent 截图**（按需开启 **允许操控电脑**）后，可一键安装到 Claude Code、Claude 桌面、Codex 或 Grok。
- **使用前提与常见排查**：
  1. 外部客户端调用 MCP 工具时，**TranSnap 主应用必须处于运行状态**；未运行时将收到显式启动提示。
  2. 如果你曾手动挪动 App 安装位置，请回到「设置 → MCP」重新点击一次安装以更新 helper 路径。
  3. 脚本清理并覆盖 `/Applications/TranSnap.app` 时若之前未关闭应用导致权限列表卡滞，可在终端用 `tccutil` 或在系统设置重新勾选一次权限。
