import CryptoKit
import Darwin
import Foundation
import OSLog
import Security

/// App 侧 MCP 请求入口（#68「MCP 接口边界」）：在 0600 Unix socket 上接受 helper 连接，
/// 校验开关后交给工具执行方，并把结果写回同一连接。
/// helper 断开表示 agent 放弃，执行中的 Task 被取消，结果不再写回。
/// 不持有截图状态；截图与权限由注入的执行方完成。
@MainActor
final class MCPCaptureServer {
    /// 执行一次工具请求并生成结果。
    typealias Run = @MainActor (MCPToolRequest) async -> MCPToolReply

    private static let log = Logger(subsystem: "TranSnap", category: "MCP")
    private let isEnabled: () -> Bool
    private let isControlEnabled: () -> Bool
    private let run: Run
    /// 在接受连接的后台线程调用，判断对端是否允许使用 MCP。
    nonisolated private let isTrustedPeer: @Sendable (Int32) -> Bool
    private var listener: DispatchSourceRead?

    /// 参数 isEnabled：读取设置中「允许 agent 截图」开关；isControlEnabled：读取「允许操控电脑」开关（#140）；
    /// run：按工具执行并生成结果；isTrustedPeer：参数为已接受的 socket，返回对端是否可信，App 传入 MCPPeer.isTrustedHelper（#140）。
    init(
        isEnabled: @escaping () -> Bool, isControlEnabled: @escaping () -> Bool, run: @escaping Run,
        isTrustedPeer: @escaping @Sendable (Int32) -> Bool
    ) {
        self.isEnabled = isEnabled
        self.isControlEnabled = isControlEnabled
        self.run = run
        self.isTrustedPeer = isTrustedPeer
    }

    /// 作用：在 path 上开始监听；失败只记录日志，App 其他功能照常可用，helper 会得到「未运行」。
    /// 参数 path：socket 文件路径，父目录不存在时创建。
    func start(path: String) {
        do {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fd = try MCPSocket.listen(path: path)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
            // 可读即有待接受的连接；每个连接在后台读请求，结果回到主线程执行。
            source.setEventHandler { [self] in
                let connection = accept(fd, nil, nil)
                guard connection >= 0 else { return }
                var on: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                // 核对对端为本 App 签名的 helper；同一用户下的其他进程不能借本 App 的权限截图或操控（#140）。
                guard isTrustedPeer(connection) else {
                    Self.log.error("MCP 拒绝非本 App helper 的连接")
                    try? MCPSocket.writeLine(
                        JSONEncoder().encode(MCPToolReply.failed(message: AppConstants.mcpUntrustedPeerMessage)),
                        to: connection
                    )
                    close(connection)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async { Self.serve(connection, server: self) }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            listener = source
        } catch {
            Self.log.error("MCP socket 监听失败：\(String(describing: error), privacy: .public)")
        }
    }

    /// 作用：停止接受新连接并关闭监听 socket；进行中的请求不受影响。
    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// 作用：按开关受理一次请求。
    /// 参数 request：helper 转来的工具请求。
    /// 返回：MCP 开关关闭为「MCP 未开启」；写入类请求在「允许操控电脑」关闭时为拒绝文案；否则为执行结果。
    func handle(_ request: MCPToolRequest) async -> MCPToolReply {
        guard isEnabled() else { return .failed(message: AppConstants.mcpDisabledMessage) }
        // 写入类请求在执行前校验「允许操控电脑」（#140）。
        guard !request.isControl || isControlEnabled() else { return .failed(message: AppConstants.mcpControlDisabledMessage) }
        return await run(request)
    }

    /// 作用：处理一条连接，在后台线程调用：读请求、执行、写结果后关闭。
    /// 参数 connection：已接受的连接；server：受理请求的服务。
    nonisolated private static func serve(_ connection: Int32, server: MCPCaptureServer) {
        guard let line = try? MCPSocket.readLine(from: connection) else {
            close(connection)
            return
        }
        guard let request = try? JSONDecoder().decode(MCPToolRequest.self, from: line) else {
            // helper 与 App 版本不一致时请求结构可能不同，明确报错而不是静默断开。
            let reply = MCPToolReply.failed(message: AppConstants.mcpVersionMismatchMessage)
            try? MCPSocket.writeLine(JSONEncoder().encode(reply), to: connection)
            close(connection)
            return
        }

        let task = Task { await server.handle(request) }
        // 等待期间监视对端：读到 EOF 表示 helper 已取消或退出，取消执行任务。
        let monitor = DispatchSource.makeReadSource(fileDescriptor: connection, queue: .global(qos: .userInitiated))
        let monitorCancelled = DispatchSemaphore(value: 0)
        monitor.setEventHandler {
            var byte: UInt8 = 0
            guard recv(connection, &byte, 1, MSG_PEEK) <= 0 else { return }
            task.cancel()
            monitor.cancel()
        }
        monitor.setCancelHandler { monitorCancelled.signal() }
        monitor.resume()

        Task.detached {
            let reply = await task.value
            // 阻塞等待放到 GCD 线程，不占用 Swift 并发线程池。
            DispatchQueue.global(qos: .userInitiated).async {
                monitor.cancel()
                // 监视源的取消处理执行后才能关闭 fd，避免源仍在观察一个已被复用的描述符。
                monitorCancelled.wait()
                try? MCPSocket.writeLine(JSONEncoder().encode(reply), to: connection)
                close(connection)
            }
        }
    }
}

/// socket 对端校验（#140）：只接受本 App 包内、签名有效的 helper 可执行文件；本 App 有签名证书时，
/// 另要求 helper 标识符为 com.coolyang.transnap.mcp 且叶证书与本 App 相同。
/// 适用条件：Release 包由安装脚本以同一证书签名 App 与 helper。Debug 构建为临时签名、没有证书，
/// helper 标识符由 Xcode 生成，此时只校验签名有效与路径；若改为分发给他人或更换签名方式，需重新评估该校验强度。
enum MCPPeer {
    /// helper 在本 App 包内的路径；对端可执行文件必须正好是它。
    private static let helperURL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS", isDirectory: true)
        .appendingPathComponent(AppConstants.mcpHelperName)
        .standardizedFileURL

    /// 本 App 自身签名推导出的校验规则：readable 为能否读取本 App 签名（不能时拒绝全部连接）；
    /// requirement 为有证书时的 helper 签名要求，临时签名时为 nil。
    private static let rule: (readable: Bool, requirement: SecRequirement?) = {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return (false, nil) }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess else { return (false, nil) }
        let certificates = (information as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate]
        guard let leaf = certificates?.first else { return (true, nil) }
        // 叶证书 DER 的 SHA-1 是代码签名要求语言 certificate leaf = H"…" 的格式，不用于安全散列。
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
        let text = "identifier \"\(AppConstants.mcpHelperIdentifier)\" and certificate leaf = "
            + "H\"\(digest.map { String(format: "%02X", $0) }.joined())\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
            return (false, nil)
        }
        return (true, requirement)
    }()

    /// connection 为已接受的 socket；返回对端是否为本 App 签名的 helper。
    static func isTrustedHelper(_ connection: Int32) -> Bool {
        guard rule.readable else { return false }
        // 用审计令牌而非进程号定位对端，避免进程号复用时校验到另一个进程。
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(connection, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        var code: SecCode?
        let audit = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: audit] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        // 校验运行中代码的签名有效（有证书时同时满足签名要求），再核对可执行文件就是本 App 包内的 helper。
        guard SecCodeCheckValidity(code, [], rule.requirement) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var path: CFURL?
        guard SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let path else { return false }
        return (path as URL).standardizedFileURL == helperURL
    }
}
