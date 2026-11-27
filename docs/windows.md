# Windows 构建说明

## 一、自动构建

推送到 origin 的 `claude/windows-**` 分支时，GitHub Actions 工作流 `.github/workflows/windows.yml` 在 windows-latest 上依次执行：

1. 以 Flutter 3.47.7 stable 安装依赖。
2. `flutter analyze` 静态分析。
3. `flutter test` 运行全部 Dart 测试。
4. `flutter build windows --release` 构建 Windows 应用。
5. 以 CMake 编译 `windows/test` 的 GoogleTest 原生单测并由 CTest 运行。
6. 上传 `build/windows/x64/runner/Release` 目录为构建产物 `TranSnap-windows-x64-<提交>`，解压后运行 `TranSnap.exe` 实测。

工作流也可在 GitHub Actions 页面手动运行。

## 二、本机构建

在装有 Visual Studio「使用 C++ 的桌面开发」工作负载的 Windows 上执行：

```bash
flutter build windows --release
```

产物位于 `build/windows/x64/runner/Release/`。

## 三、运行与实测

运行要求：Windows 10 1903 及以上 x64；Windows 11 22H2 及以上使用系统亚克力背景，更早版本使用不透明底色。

1. 启动后只在托盘显示图标，菜单为「设置…」「翻译历史…」「仅使用快捷键」「退出」；设置与翻译历史窗口打开时出现在任务栏。
2. 数据位置：偏好 `%APPDATA%\TranSnap\preferences.json`，翻译历史等应用数据在 `%APPDATA%\TranSnap\`，服务密钥在 Windows 凭据管理器（目标名 `TranSnap/credentials/<服务标识>`），登录时启动写入当前用户的 `Run` 注册表项。
3. 不需要系统权限授权；不提供 Apple 系统翻译、词典释义与生词本、截图、录制、实时翻译与 MCP 入口。
4. 划词：拖选、双击、三击、Ctrl+A、Shift 配合方向键与 Home、End、PageUp、PageDown 后出现触发按钮；选中文字经 UI Automation 读取，读不到时用 Ctrl+C 复制兜底并还原剪贴板；密码框不读取。
5. 快捷键：在设置中录制全局翻译与输入翻译快捷键（至少含 Ctrl、Alt 或 Win），Ctrl（可加 Shift）搭配 A、Z、Y、X、C、V 保留给文本编辑；被其他应用占用时设置保存失败并指明是哪个快捷键。
6. 排除应用按可执行文件路径识别；来源应用名取可执行文件的「文件说明」。
