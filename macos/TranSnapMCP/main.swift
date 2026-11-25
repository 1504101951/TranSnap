import Foundation

func enclosingAppVersion() -> String {
    let app = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
}

let stdout = FileHandle.standardOutput
let session = MCPHelperSession(
    socketPath: MCPSocket.defaultURL.path, version: enclosingAppVersion()
) { message in
    stdout.write(message + Data([0x0A]))
}
while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    session.receive(Data(line.utf8))
}
