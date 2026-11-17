import Foundation

// translateapp-mcp：由 MCP 客户端以 stdio 启动的 helper（#96、#68「MCP 接口边界」）。
// stdin 每行一条 JSON-RPC 消息，stdout 每行一条响应；截图请求经 Unix socket 转给运行中的 TranslateApp。

/// 作用：读取外层 App 的版本号作为 serverInfo.version。
/// 返回：App 包 Info.plist 的 CFBundleShortVersionString；从构建目录单独运行、没有外层 App 时为 "unknown"。
func enclosingAppVersion() -> String {
    // helper 位于 <App>.app/Contents/MacOS/，向上三级是 App 包。
    let app = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
}

/// 作用：读取 App 偏好中的「允许操控电脑」开关（#140）。
/// 返回：开关是否开启；App 从未写入偏好时为 false。App 执行操控类工具时会再次校验。
/// 已知限制：开关切换后，客户端重新连接才会拿到新的 tools/list。
func controlEnabled() -> Bool {
    let preferences = UserDefaults(suiteName: AppConstants.appBundleIdentifier)?.dictionary(forKey: AppConstants.preferencesKey)
    return preferences?[AppConstants.mcpControlEnabledKey] as? Bool == true
}

let stdout = FileHandle.standardOutput
let session = MCPHelperSession(
    socketPath: MCPSocket.defaultURL.path, version: enclosingAppVersion(), controlEnabled: controlEnabled
) { message in
    stdout.write(message + Data([0x0A]))
}
// stdin 关闭表示客户端退出；进程结束会断开进行中的连接，App 据此关闭对应会话。
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    session.receive(Data(line.utf8))
}
