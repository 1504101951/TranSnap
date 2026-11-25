import Darwin
import Foundation

enum MCPSocketError: Error, Equatable {
    case notRunning
    case alreadyServing
    case pathTooLong
    case system(Int32)
}

enum MCPSocket {
    static var defaultURL: URL {
        AppConstants.applicationSupportURL
            .appendingPathComponent(AppConstants.mcpSocketFileName)
    }

    static func connect(path: String) throws -> Int32 {
        let fd = try makeSocket()
        var address = try address(path)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            let code = errno
            close(fd)
            if code == ENOENT || code == ECONNREFUSED { throw MCPSocketError.notRunning }
            throw MCPSocketError.system(code)
        }
        return fd
    }

    static func listen(path: String) throws -> Int32 {
        if let existing = try? connect(path: path) {
            close(existing)
            throw MCPSocketError.alreadyServing
        }
        unlink(path)
        let fd = try makeSocket()
        var address = try address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, SOMAXCONN) == 0 else {
            let code = errno
            close(fd)
            throw MCPSocketError.system(code)
        }
        return fd
    }

    static func writeLine(_ data: Data, to fd: Int32) throws {
        var bytes = data
        bytes.append(0x0A)
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw MCPSocketError.system(errno)
                }
                offset += written
            }
        }
    }

    static func readLine(from fd: Int32) throws -> Data? {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw MCPSocketError.system(errno)
            }
            if count == 0 { return nil }
            if let newline = chunk[0..<count].firstIndex(of: 0x0A) {
                line.append(contentsOf: chunk[0..<newline])
                return line
            }
            line.append(contentsOf: chunk[0..<count])
        }
    }

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPSocketError.system(errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw MCPSocketError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}
