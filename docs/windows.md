# Windows 构建说明

## 一、自动构建

推送到 origin 的 `claude/windows-**` 分支时，GitHub Actions 工作流 `.github/workflows/windows.yml` 在 windows-latest 上依次执行：

1. 以 Flutter 3.47.7 stable 安装依赖。
2. `flutter analyze` 静态分析。
3. `flutter test` 运行全部 Dart 测试。
4. `flutter build windows --release` 构建 Windows 应用。
5. 上传 `build/windows/x64/runner/Release` 目录为构建产物 `TranSnap-windows-x64-<提交>`，解压后运行 `TranSnap.exe` 实测。

工作流也可在 GitHub Actions 页面手动运行。

## 二、本机构建

在装有 Visual Studio「使用 C++ 的桌面开发」工作负载的 Windows 上执行：

```bash
flutter build windows --release
```

产物位于 `build/windows/x64/runner/Release/`。
