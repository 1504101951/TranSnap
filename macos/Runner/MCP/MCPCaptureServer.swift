import CryptoKit
import Darwin
import Foundation
import OSLog
import Security

@MainActor
final class MCPCaptureServer {
    typealias Run = @MainActor (MCPToolRequest) async -> MCPToolReply

    private static let log = Logger(subsystem: "TranSnap", category: "MCP")
    private let isEnabled: () -> Bool
    private let isControlEnabled: () -> Bool
    private let run: Run
    nonisolated private let isTrustedPeer: @Sendable (Int32) -> Bool
    private var listener: DispatchSourceRead?

    init(
        isEnabled: @escaping () -> Bool, isControlEnabled: @escaping () -> Bool, run: @escaping Run,
        isTrustedPeer: @escaping @Sendable (Int32) -> Bool
    ) {
        self.isEnabled = isEnabled
        self.isControlEnabled = isControlEnabled
        self.run = run
        self.isTrustedPeer = isTrustedPeer
    }

    func start(path: String) {
        do {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fd = try MCPSocket.listen(path: path)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
            source.setEventHandler { [self] in
                let connection = accept(fd, nil, nil)
                guard connection >= 0 else { return }
                var on: Int32 = 1
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
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

    func stop() {
        listener?.cancel()
        listener = nil
    }

    func handle(_ request: MCPToolRequest) async -> MCPToolReply {
        guard isEnabled() else { return .failed(message: AppConstants.mcpDisabledMessage) }
        guard !request.isControl || isControlEnabled() else { return .failed(message: AppConstants.mcpControlDisabledMessage) }
        return await run(request)
    }

    nonisolated private static func serve(_ connection: Int32, server: MCPCaptureServer) {
        guard let line = try? MCPSocket.readLine(from: connection) else {
            close(connection)
            return
        }
        guard let request = try? JSONDecoder().decode(MCPToolRequest.self, from: line) else {
            let reply = MCPToolReply.failed(message: AppConstants.mcpVersionMismatchMessage)
            try? MCPSocket.writeLine(JSONEncoder().encode(reply), to: connection)
            close(connection)
            return
        }

        let task = Task { await server.handle(request) }
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
            DispatchQueue.global(qos: .userInitiated).async {
                monitor.cancel()
                monitorCancelled.wait()
                try? MCPSocket.writeLine(JSONEncoder().encode(reply), to: connection)
                close(connection)
            }
        }
    }
}

enum MCPPeer {
    private static let helperURL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS", isDirectory: true)
        .appendingPathComponent(AppConstants.mcpHelperName)
        .standardizedFileURL

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
        let digest = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
        let text = "identifier \"\(AppConstants.mcpHelperIdentifier)\" and certificate leaf = "
            + "H\"\(digest.map { String(format: "%02X", $0) }.joined())\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
            return (false, nil)
        }
        return (true, requirement)
    }()

    static func isTrustedHelper(_ connection: Int32) -> Bool {
        guard rule.readable else { return false }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(connection, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
        var code: SecCode?
        let audit = withUnsafeBytes(of: &token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: audit] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        guard SecCodeCheckValidity(code, [], rule.requirement) == errSecSuccess else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var path: CFURL?
        guard SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let path else { return false }
        return (path as URL).standardizedFileURL == helperURL
    }
}
