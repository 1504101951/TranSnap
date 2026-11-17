# macos/Runner/MCP目录索引

MCP 截图与操控接口的 JSON-RPC 协议、本地 socket 传输及 App 侧请求处理。

1. [MCPAccessibility.swift](MCPAccessibility.swift)：解析无障碍读取对象、遍历无障碍树、在内存中保存元素 ref 并生成 snapshot/find 结果。
2. [MCPControl.swift](MCPControl.swift)：执行点击、输入、按键、滚动与拖动，管理操控会话、授权面板、边框提示与本地操作日志。
3. [MCPCaptureServer.swift](MCPCaptureServer.swift)：App 侧 socket 服务，校验对端签名与 MCP、操控开关，执行工具并在 helper 断开时取消请求。
4. [MCPImageOutput.swift](MCPImageOutput.swift)：按视觉 token 上限缩放截图、换算 capture_rect 坐标并生成可带位置的 OCR Markdown。
5. [MCPProtocol.swift](MCPProtocol.swift)：helper 与 App 共用的工具请求结果类型、MCP JSON-RPC 最小子集转换及 helper 的 stdio 会话。
6. [MCPSocket.swift](MCPSocket.swift)：helper 与 App 共用的 0600 Unix domain socket 单行 JSON 收发。
7. [MCPToolRunner.swift](MCPToolRunner.swift)：在 App 进程列出显示器与窗口，并按显示器、矩形或窗口截图。
8. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
