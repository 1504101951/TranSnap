import AppKit
import Carbon
import Darwin
import XCTest

@testable import TranSnap

final class MCPTests: XCTestCase {
    private final class Output {
        private let lock = NSLock()
        private var messages: [[String: Any]] = []
        private(set) var raw: [String] = []
        var expectation: XCTestExpectation?
        var expectedCount = 0

        func append(_ data: Data) {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                XCTFail("会话写出的行不是 JSON 对象：\(String(decoding: data, as: UTF8.self))")
                return
            }
            lock.lock()
            messages.append(object)
            raw.append(String(decoding: data, as: UTF8.self))
            let reached = messages.count == expectedCount
            lock.unlock()
            if reached { expectation?.fulfill() }
        }

        var all: [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return messages
        }
    }

    private var socketPath = ""
    private var server: MCPCaptureServer?

    override func setUp() {
        socketPath = NSTemporaryDirectory() + "mcp-\(UUID().uuidString.prefix(8)).sock"
    }

    @MainActor
    override func tearDown() {
        server?.stop()
        server = nil
        unlink(socketPath)
    }

    @MainActor
    private func startServer(enabled: Bool = true, control: Bool = true, run: @escaping MCPCaptureServer.Run) {
        let server = MCPCaptureServer(
            isEnabled: { enabled }, isControlEnabled: { control }, run: run, isTrustedPeer: { _ in true }
        )
        server.start(path: socketPath)
        self.server = server
    }

    private func exchange(_ lines: [String], count: Int) async -> [[String: Any]] {
        await exchangeOutput(lines, count: count).all
    }

    private func exchangeOutput(_ lines: [String], count: Int) async -> Output {
        let output = Output()
        let done = expectation(description: "收到 \(count) 条输出")
        output.expectation = done
        output.expectedCount = count
        let session = MCPHelperSession(socketPath: socketPath, version: "test") { output.append($0) }
        lines.forEach { session.receive(Data($0.utf8)) }
        await fulfillment(of: [done], timeout: 10)
        return output
    }

    private func toolResult(_ message: [String: Any]) -> (content: [[String: Any]], isError: Bool) {
        let result = message["result"] as! [String: Any]
        return (result["content"] as! [[String: Any]], result["isError"] as! Bool)
    }

    private func textImage(width: Int, height: Int, text: String, x: CGFloat, baseline: CGFloat) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(at: NSPoint(x: x, y: baseline), withAttributes: [
            .font: NSFont.systemFont(ofSize: 96), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        let image = try XCTUnwrap(context.makeImage())
        return try PNGEncoding.data(image, scale: 1)
    }

    func testEnvelopeErrorsAndNotificationsFollowJsonRpc() async {
        let messages = await exchange([
            "not json",
            #"{"jsonrpc":"2.0","id":1}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#,
        ], count: 3)
        XCTAssertTrue(messages[0]["id"] is NSNull)
        XCTAssertEqual((messages[0]["error"] as? [String: Any])?["code"] as? Int, MCPProtocol.parseError)
        XCTAssertEqual(messages[1]["id"] as? Int, 1)
        XCTAssertEqual((messages[1]["error"] as? [String: Any])?["code"] as? Int, MCPProtocol.invalidRequest)
        XCTAssertEqual(messages[2]["id"] as? Int, 2)
        XCTAssertEqual((messages[2]["error"] as? [String: Any])?["code"] as? Int, MCPProtocol.methodNotFound)
    }

    func testUnserializableResultBecomesInternalError() throws {
        for (id, value) in [(7 as Any, Double.nan), ("a" as Any, Double.infinity)] {
            let data = MCPProtocol.encode(MCPProtocol.response(id: id, result: ["value": value]))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((object["error"] as? [String: Any])?["code"] as? Int, MCPProtocol.internalError)
            XCTAssertEqual(object["id"] as? NSObject, id as? NSObject)
            XCTAssertNil(object["result"])
        }
        let missing = try XCTUnwrap(JSONSerialization.jsonObject(with: MCPProtocol.internalErrorData(id: nil)) as? [String: Any])
        XCTAssertTrue(missing["id"] is NSNull)
        let valid = MCPProtocol.response(id: 1, result: ["text": "a/b"])
        XCTAssertEqual(MCPProtocol.encode(valid), try JSONSerialization.data(withJSONObject: valid, options: [.withoutEscapingSlashes]))
    }

    func testInitializeNegotiatesVersionAndPingAnswersEmpty() async {
        let messages = await exchange([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#,
            #"{"jsonrpc":"2.0","id":"p","method":"ping"}"#,
        ], count: 3)
        let accepted = messages[0]["result"] as! [String: Any]
        XCTAssertEqual(accepted["protocolVersion"] as? String, "2025-06-18")
        XCTAssertNotNil((accepted["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual((accepted["serverInfo"] as? [String: Any])?["name"] as? String, AppConstants.mcpServerName)
        XCTAssertEqual((messages[1]["result"] as? [String: Any])?["protocolVersion"] as? String, MCPProtocol.supportedVersions[0])
        XCTAssertEqual(messages[2]["id"] as? String, "p")
        XCTAssertEqual((messages[2]["result"] as? [String: Any])?.count, 0)
    }


    func testToolsListDeclaresOrderedEnglishSchemas() async throws {
        let output = await exchangeOutput([#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#], count: 1)
        let tools = (output.all[0]["result"] as! [String: Any])["tools"] as! [[String: Any]]
        XCTAssertEqual(tools.map { $0["name"] as? String }, [
            "list_displays", "list_windows", "capture_screen", "capture_rect", "capture_window",
            "snapshot", "find", "click", "type_text", "press_key", "scroll", "drag",
        ])
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0["name"] as! String, $0) })
        XCTAssertTrue((byName["list_displays"]!["description"] as! String).contains("Use when you need screen information"))
        XCTAssertTrue((byName["list_windows"]!["description"] as! String).contains("Use when you need screen information"))

        let rect = byName["capture_rect"]!["inputSchema"] as! [String: Any]
        XCTAssertEqual(rect["required"] as? [String], ["display_index", "x", "y", "width", "height"])
        XCTAssertEqual(rect["additionalProperties"] as? Bool, false)
        let properties = rect["properties"] as! [String: [String: Any]]
        XCTAssertEqual(properties["output"]?["default"] as? String, "image")
        XCTAssertEqual(properties["output"]?["enum"] as? [String], ["image", "text", "both"])
        XCTAssertEqual(properties["detail"]?["enum"] as? [String], ["low", "standard"])
        XCTAssertEqual(properties["include_positions"]?["default"] as? Bool, false)
        XCTAssertEqual(properties["width"]?["minimum"] as? Int, 1)
        XCTAssertNil(properties["width"]?["description"])

        let raw = output.raw[0]
        let section = raw[raw.range(of: #""name":"capture_rect""#)!.lowerBound...]
        let order = ["display_index", "x", "y", "width", "height", "reference_detail", "output", "detail", "include_positions"]
        let positions = order.map { section.range(of: "\"\($0)\":{")!.lowerBound }
        XCTAssertEqual(positions, positions.sorted())
    }

    @MainActor
    func testControlSwitchBlocksWriteToolsOnly() async {
        let listed = await exchangeOutput([#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#], count: 1)
        let names = ((listed.all[0]["result"] as! [String: Any])["tools"] as! [[String: Any]]).map { $0["name"] as! String }
        XCTAssertEqual(names, [
            "list_displays", "list_windows", "capture_screen", "capture_rect", "capture_window",
            "snapshot", "find", "click", "type_text", "press_key", "scroll", "drag",
        ])

        var executed = false
        startServer(control: false) { _ in
            executed = true
            return .displays([])
        }
        let snapshot = await exchange([#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"snapshot"}}"#], count: 1)
        XCTAssertFalse(toolResult(snapshot[0]).isError)
        XCTAssertTrue(executed)

        executed = false
        let click = await exchange([#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"click","arguments":{"display_index":0,"x":1,"y":1}}}"#], count: 1)
        XCTAssertEqual(toolResult(click[0]).content.first?["text"] as? String, AppConstants.mcpControlDisabledMessage)
        XCTAssertTrue(toolResult(click[0]).isError)
        XCTAssertFalse(executed)
    }

    func testAccessibilityToolArguments() throws {
        XCTAssertEqual(
            try MCPProtocol.toolRequest(params: ["name": "snapshot"]),
            .snapshot(target: .frontmost, interactiveOnly: true, maxDepth: AppConstants.mcpSnapshotDefaultDepth)
        )
        XCTAssertEqual(
            try MCPProtocol.toolRequest(params: ["name": "snapshot", "arguments": ["root": "@s2:e5", "max_depth": 99, "interactive_only": false]]),
            .snapshot(target: .ref("@s2:e5"), interactiveOnly: false, maxDepth: AppConstants.mcpSnapshotMaxDepth)
        )
        XCTAssertEqual(
            try MCPProtocol.toolRequest(params: ["name": "find", "arguments": ["app": "Safari", "role": "button"]]),
            .find(target: .app("Safari"), role: "button", text: nil)
        )
        XCTAssertThrowsError(try MCPProtocol.toolRequest(params: ["name": "snapshot", "arguments": ["app": "Safari", "window_id": 3]])) {
            XCTAssertEqual($0 as? MCPRequestError, .invalidArgument(AppConstants.mcpTargetConflictMessage))
        }
        XCTAssertThrowsError(try MCPProtocol.toolRequest(params: ["name": "find", "arguments": ["app": "Safari"]])) {
            XCTAssertEqual($0 as? MCPRequestError, .invalidArgument(AppConstants.mcpFindFilterMessage))
        }
        XCTAssertThrowsError(try MCPProtocol.toolRequest(params: ["name": "find", "arguments": ["root": "@s1:e1", "text": "OK"]]))
    }

    func testControlToolArguments() throws {
        XCTAssertEqual(
            try MCPProtocol.toolRequest(params: ["name": "click", "arguments": ["ref": "@s1:e2"]]),
            .click(target: .ref("@s1:e2"), button: .left, count: 1, screenshot: false)
        )
        XCTAssertEqual(
            try MCPProtocol.toolRequest(params: ["name": "click", "arguments": [
                "display_index": 1, "x": 5, "y": 6, "reference_detail": "low", "button": "right", "count": 2, "return_screenshot": true,
            ]]),
            .click(target: .point(displayIndex: 1, x: 5, y: 6, reference: .low), button: .right, count: 2, screenshot: true)
        )
        XCTAssertEqual(
            try MCPProtocol.toolRequest(params: ["name": "type_text", "arguments": ["text": " hi "]]),
            .typeText(text: " hi ", target: nil, screenshot: false)
        )
        XCTAssertEqual(
            try MCPProtocol.toolRequest(params: ["name": "drag", "arguments": ["display_index": 0, "x": 1, "y": 2, "to_x": 3, "to_y": 4]]),
            .drag(from: .point(displayIndex: 0, x: 1, y: 2, reference: .standard), toX: 3, toY: 4, screenshot: false)
        )
        let invalid: [[String: Any]] = [
            ["name": "click", "arguments": ["ref": "@s1:e2", "x": 1]],
            ["name": "click", "arguments": ["display_index": 0, "x": 1]],
            ["name": "click"],
            ["name": "click", "arguments": ["ref": "@s1:e2", "count": 3]],
            ["name": "scroll", "arguments": ["ref": "@s1:e2"]],
            ["name": "type_text", "arguments": ["text": ""]],
        ]
        for params in invalid {
            XCTAssertThrowsError(try MCPProtocol.toolRequest(params: params), "\(params)")
        }
    }

    func testKeyComboParsingAndForbiddenShortcuts() throws {
        let save = try XCTUnwrap(MCPKeyCombo("Cmd+Shift+S"))
        XCTAssertEqual(save.keyCode, CGKeyCode(kVK_ANSI_S))
        XCTAssertEqual(save.flags, [.maskCommand, .maskShift])
        XCTAssertEqual(MCPKeyCombo("f5")?.keyCode, CGKeyCode(kVK_F5))
        XCTAssertEqual(MCPKeyCombo("return")?.flags, [])
        for forbidden in ["cmd+q", "cmd+shift+q", "ctrl+cmd+q", "cmd+opt+esc"] {
            XCTAssertTrue(try XCTUnwrap(MCPKeyCombo(forbidden)).isForbidden, forbidden)
        }
        for allowed in ["q", "esc", "opt+esc", "cmd+w"] {
            XCTAssertFalse(try XCTUnwrap(MCPKeyCombo(allowed)).isForbidden, allowed)
        }
        for invalid in ["cmd", "a+b", "cmd+hyper", ""] {
            XCTAssertNil(MCPKeyCombo(invalid), invalid)
        }
        XCTAssertTrue(save.events().allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == AppConstants.syntheticEventTag })
    }

    func testControlSessionLimits() {
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(MCPControlLimits.expired(startedAt: start, lastActionAt: start, now: start.addingTimeInterval(299)))
        XCTAssertTrue(MCPControlLimits.expired(startedAt: start, lastActionAt: start, now: start.addingTimeInterval(300)))
        let active = start.addingTimeInterval(1500)
        XCTAssertFalse(MCPControlLimits.expired(startedAt: start, lastActionAt: active, now: start.addingTimeInterval(1799)))
        XCTAssertTrue(MCPControlLimits.expired(startedAt: start, lastActionAt: active, now: start.addingTimeInterval(1800)))
    }

    @MainActor
    func testGlobalPointMapsImagePixelsToScreenPoints() {
        let left = MCPToolRunner.Display(
            info: MCPDisplayInfo(displayIndex: 1, standardWidth: 500, standardHeight: 500, lowWidth: 250, lowHeight: 250),
            bounds: CGRect(x: -1000, y: 0, width: 1000, height: 1000), pixelWidth: 1000, pixelHeight: 1000
        )
        XCTAssertEqual(MCPToolRunner.globalPoint(x: 0, y: 0, reference: .standard, display: left), CGPoint(x: -999, y: 1))
        XCTAssertEqual(MCPToolRunner.globalPoint(x: 249, y: 0, reference: .low, display: left), CGPoint(x: -2, y: 2))
        XCTAssertNil(MCPToolRunner.globalPoint(x: 500, y: 0, reference: .standard, display: left))
        XCTAssertNil(MCPToolRunner.globalPoint(x: 0, y: 250, reference: .low, display: left))
    }

    func testDoneReplyBecomesTextThenImage() {
        let plain = MCPProtocol.toolResult(.done(message: "Clicked.", png: nil))["content"] as! [[String: Any]]
        XCTAssertEqual(plain.count, 1)
        XCTAssertEqual(plain[0]["text"] as? String, "Clicked.")
        let shot = MCPProtocol.toolResult(.done(message: "Clicked.", png: Data([1, 2])))["content"] as! [[String: Any]]
        XCTAssertEqual(shot.map { $0["type"] as? String }, ["text", "image"])
    }

    func testElementsReplyBecomesTable() {
        let items = [
            MCPElementInfo(ref: "@s1:e1", depth: 0, role: "button", name: "Send\tNow", value: "", enabled: true,
                           displayIndex: 0, x: 10, y: 20, width: 30, height: 40),
            MCPElementInfo(ref: "@s1:e2", depth: 1, role: "textfield", name: "Search", value: "abc", enabled: false,
                           displayIndex: nil, x: 0, y: 0, width: 0, height: 0),
        ]
        let text = MCPProtocol.toolResult(.elements(snapshot: "@s1", complete: false, items: items))["content"] as! [[String: Any]]
        let lines = (text[0]["text"] as! String).components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("snapshot @s1 incomplete"))
        XCTAssertEqual(lines[2], "@s1:e1\t0\tbutton\tSend Now\t\ttrue\t0\t10\t20\t30\t40")
        XCTAssertEqual(lines[3], "@s1:e2\t1\ttextfield\tSearch\tabc\tfalse\t\t\t\t\t")
    }

    @MainActor
    func testStandardRectMapsGlobalPointsToDisplayImage() {
        let main = MCPToolRunner.Display(
            info: MCPDisplayInfo(displayIndex: 0, standardWidth: 1000, standardHeight: 500, lowWidth: 500, lowHeight: 250),
            bounds: CGRect(x: 0, y: 0, width: 2000, height: 1000), pixelWidth: 4000, pixelHeight: 2000
        )
        let left = MCPToolRunner.Display(
            info: MCPDisplayInfo(displayIndex: 1, standardWidth: 500, standardHeight: 500, lowWidth: 250, lowHeight: 250),
            bounds: CGRect(x: -1000, y: 0, width: 1000, height: 1000), pixelWidth: 1000, pixelHeight: 1000
        )
        let displays = [main, left]
        XCTAssertTrue(MCPToolRunner.standardRect(CGRect(x: 200, y: 100, width: 400, height: 200), displays: displays)!
            == (0, 100, 50, 200, 100))
        XCTAssertTrue(MCPToolRunner.standardRect(CGRect(x: -900, y: 900, width: 200, height: 400), displays: displays)!
            == (1, 50, 450, 100, 50))
        XCTAssertNil(MCPToolRunner.standardRect(CGRect(x: 5000, y: 0, width: 10, height: 10), displays: displays))
    }

    func testToolRequestConversionAndArgumentBounds() throws {
        let defaults = MCPCaptureOptions(output: .image, detail: .standard, includePositions: false)
        XCTAssertEqual(try MCPProtocol.toolRequest(params: ["name": "capture_screen"]), .captureScreen(displayIndex: 0, options: defaults))
        XCTAssertEqual(
            try MCPProtocol.toolRequest(params: ["name": "capture_rect", "arguments": [
                "display_index": 1, "x": 0, "y": 0, "width": 1, "height": 1,
                "reference_detail": "low", "output": "text", "detail": "low", "include_positions": true,
            ]]),
            .captureRect(
                displayIndex: 1, x: 0, y: 0, width: 1, height: 1, referenceDetail: .low,
                options: MCPCaptureOptions(output: .text, detail: .low, includePositions: true)
            )
        )
        XCTAssertEqual(
            try MCPProtocol.toolRequest(params: ["name": "capture_window", "arguments": ["window_id": Int(UInt32.max)]]),
            .captureWindow(windowID: UInt32.max, options: defaults)
        )
        let invalid: [([String: Any], String)] = [
            (["display_index": -1], "display_index must be an integer ≥ 0"),
            (["display_index": true], "display_index must be an integer ≥ 0"),
            (["display_index": 1.5], "display_index must be an integer ≥ 0"),
            (["output": "pdf"], "output must be one of image, text, both"),
            (["detail": "high"], "detail must be one of low, standard"),
            (["include_positions": 1], "include_positions must be a boolean"),
            (["display": 0], "Unknown argument: display"),
        ]
        for (arguments, message) in invalid {
            XCTAssertThrowsError(try MCPProtocol.toolRequest(params: ["name": "capture_screen", "arguments": arguments])) {
                XCTAssertEqual($0 as? MCPRequestError, .invalidArgument(message))
            }
        }
        let rectBase: [String: Any] = ["display_index": 0, "x": 0, "y": 0, "width": 10, "height": 10]
        for (key, value) in [("width", 0), ("height", 0), ("x", -1)] as [(String, Any)] {
            var arguments = rectBase
            arguments[key] = value
            XCTAssertThrowsError(try MCPProtocol.toolRequest(params: ["name": "capture_rect", "arguments": arguments]), key)
        }
        var missing = rectBase
        missing["height"] = nil
        XCTAssertThrowsError(try MCPProtocol.toolRequest(params: ["name": "capture_rect", "arguments": missing])) {
            XCTAssertEqual($0 as? MCPRequestError, .invalidArgument("Missing required argument: height"))
        }
        for id in [0, Int(UInt32.max) + 1] {
            XCTAssertThrowsError(try MCPProtocol.toolRequest(params: ["name": "capture_window", "arguments": ["window_id": id]]))
        }
    }

    func testInvalidToolCallsReturnErrorsWithoutApp() async {
        let messages = await exchange([
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"capture_region"}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"capture_screen","arguments":{"output":"pdf"}}}"#,
        ], count: 2)
        XCTAssertEqual((messages[0]["error"] as? [String: Any])?["code"] as? Int, MCPProtocol.invalidParams)
        XCTAssertTrue(toolResult(messages[1]).isError)
        XCTAssertEqual(toolResult(messages[1]).content.first?["text"] as? String, "output must be one of image, text, both")
    }

    func testAppNotRunningReturnsToolError() async throws {
        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_displays"}}"#
        let missing = await exchange([call], count: 1)
        XCTAssertEqual(toolResult(missing[0]).content.first?["text"] as? String, AppConstants.mcpNotRunningMessage)
        XCTAssertTrue(toolResult(missing[0]).isError)

        close(try MCPSocket.listen(path: socketPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        let stale = await exchange([call], count: 1)
        XCTAssertEqual(toolResult(stale[0]).content.first?["text"] as? String, AppConstants.mcpNotRunningMessage)
    }

    @MainActor
    func testUntrustedPeerIsRefusedBeforeExecution() async {
        var executed = false
        let server = MCPCaptureServer(isEnabled: { true }, isControlEnabled: { true }, run: { _ in
            executed = true
            return .displays([])
        }, isTrustedPeer: MCPPeer.isTrustedHelper)
        server.start(path: socketPath)
        self.server = server
        let messages = await exchange([#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_displays"}}"#], count: 1)
        XCTAssertTrue(toolResult(messages[0]).isError)
        XCTAssertEqual(toolResult(messages[0]).content.first?["text"] as? String, AppConstants.mcpUntrustedPeerMessage)
        XCTAssertFalse(executed)
    }

    func testSyntheticEventMarkIsReadableFromNSEvent() throws {
        let marked = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        SyntheticEvent.mark(marked)
        let plain = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        XCTAssertTrue(SyntheticEvent.isMarked(try XCTUnwrap(NSEvent(cgEvent: marked))))
        XCTAssertFalse(SyntheticEvent.isMarked(try XCTUnwrap(NSEvent(cgEvent: plain))))
    }

    @MainActor
    func testDisabledSwitchReturnsNotEnabled() async {
        var executed = false
        startServer(enabled: false) { _ in
            executed = true
            return .displays([])
        }
        let messages = await exchange([#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_displays"}}"#], count: 1)
        XCTAssertTrue(toolResult(messages[0]).isError)
        XCTAssertEqual(toolResult(messages[0]).content.first?["text"] as? String, AppConstants.mcpDisabledMessage)
        XCTAssertFalse(executed)
    }

    @MainActor
    func testRequestsReachAppAndRepliesBecomeContent() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        var received: [MCPToolRequest] = []
        startServer { request in
            received.append(request)
            switch request {
            case .listDisplays:
                return .displays([MCPDisplayInfo(displayIndex: 0, standardWidth: 1372, standardHeight: 891, lowWidth: 784, lowHeight: 509)])
            case .listWindows:
                return .windows([MCPWindowInfo(windowID: 42, displayIndex: 0, x: 0, y: 17, width: 686, height: 400, app: "Safari", title: "A\tB\nC")])
            default:
                return .image(png: png, markdown: "# Title")
            }
        }
        let displays = await exchange([#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_displays"}}"#], count: 1)
        let windows = await exchange([#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_windows"}}"#], count: 1)
        let capture = await exchange([
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"capture_rect","arguments":{"display_index":0,"x":10,"y":20,"width":30,"height":40,"output":"both"}}}"#,
        ], count: 1)

        XCTAssertEqual(received.last, .captureRect(
            displayIndex: 0, x: 10, y: 20, width: 30, height: 40, referenceDetail: .standard,
            options: MCPCaptureOptions(output: .both, detail: .standard, includePositions: false)
        ))
        XCTAssertEqual(
            toolResult(displays[0]).content.first?["text"] as? String,
            "display_index\tstandard_image_width\tstandard_image_height\tlow_image_width\tlow_image_height\n0\t1372\t891\t784\t509"
        )
        XCTAssertEqual(
            toolResult(windows[0]).content.first?["text"] as? String,
            "window_id\tdisplay_index\tx\ty\twidth\theight\tapp\ttitle\n42\t0\t0\t17\t686\t400\tSafari\tA B C"
        )
        let result = toolResult(capture[0])
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.content.count, 2)
        XCTAssertEqual(result.content[0]["type"] as? String, "image")
        XCTAssertEqual(result.content[0]["mimeType"] as? String, "image/png")
        XCTAssertEqual(result.content[0]["data"] as? String, png.base64EncodedString())
        XCTAssertEqual(result.content[1]["text"] as? String, "# Title")
    }

    @MainActor
    func testCancelNotificationCancelsAppTaskWithoutResponse() async {
        let started = expectation(description: "App 开始执行")
        let cancelled = expectation(description: "App 任务被取消")
        startServer { _ in
            started.fulfill()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    Task { while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }; continuation.resume() }
                }
            } onCancel: {
                cancelled.fulfill()
            }
            return .displays([])
        }
        let output = Output()
        let session = MCPHelperSession(socketPath: socketPath, version: "test") { output.append($0) }
        session.receive(Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_windows"}}"#.utf8))
        await fulfillment(of: [started], timeout: 5)
        session.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#.utf8))
        await fulfillment(of: [cancelled], timeout: 5)

        let silent = expectation(description: "取消后不响应")
        silent.isInverted = true
        output.expectation = silent
        output.expectedCount = 1
        await fulfillment(of: [silent], timeout: 0.5)
        XCTAssertTrue(output.all.isEmpty)
    }

    func testListenUsesOwnerOnlyPermissionAndRefusesSecondServer() throws {
        let fd = try MCPSocket.listen(path: socketPath)
        defer { close(fd) }
        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try MCPSocket.listen(path: socketPath)) {
            XCTAssertEqual($0 as? MCPSocketError, .alreadyServing)
        }
    }

    private func tokens(_ size: (width: Int, height: Int)) -> Int {
        Int((Double(size.width) / 28).rounded(.up)) * Int((Double(size.height) / 28).rounded(.up))
    }

    func testFittedSizeRespectsTokenBudgetAndLongEdge() {
        for detail in MCPDetail.allCases {
            for (width, height) in [(3024, 1964), (5120, 2880), (1000, 3136), (1568, 10)] {
                let size = MCPImageOutput.fitted(width: width, height: height, detail: detail)
                XCTAssertLessThanOrEqual(tokens(size), detail.tokenBudget, "\(width)×\(height) \(detail)")
                XCTAssertLessThanOrEqual(max(size.width, size.height), AppConstants.mcpImageMaxEdge)
                XCTAssertEqual(Double(size.width) / Double(size.height), Double(width) / Double(height), accuracy: 0.02 * Double(width) / Double(height))
            }
        }
        let retina = MCPImageOutput.fitted(width: 3024, height: 1964, detail: .standard)
        XCTAssertGreaterThan(tokens(retina), Int(Double(MCPDetail.standard.tokenBudget) * 0.95))
        let small = MCPImageOutput.fitted(width: 800, height: 600, detail: .standard)
        XCTAssertEqual(small.width, 800)
        XCTAssertEqual(small.height, 600)
    }

    func testSourceRectMapsReferenceCoordinatesToSourcePixels() {
        for detail in MCPDetail.allCases {
            let reference = MCPImageOutput.fitted(width: 3024, height: 1964, detail: detail)
            XCTAssertEqual(
                MCPImageOutput.sourceRect(
                    x: 0, y: 0, width: reference.width, height: reference.height, detail: detail,
                    sourceWidth: 3024, sourceHeight: 1964
                ),
                CGRect(x: 0, y: 0, width: 3024, height: 1964)
            )
            XCTAssertNil(MCPImageOutput.sourceRect(
                x: 1, y: 0, width: reference.width, height: 1, detail: detail, sourceWidth: 3024, sourceHeight: 1964
            ))
        }
        let standard = MCPImageOutput.fitted(width: 3024, height: 1964, detail: .standard)
        let rect = MCPImageOutput.sourceRect(x: 100, y: 100, width: 10, height: 10, detail: .standard, sourceWidth: 3024, sourceHeight: 1964)!
        XCTAssertEqual(rect.minX, (100 * 3024 / Double(standard.width)).rounded(.down))
        XCTAssertEqual(rect.maxX, (110 * 3024 / Double(standard.width)).rounded(.up))
        XCTAssertNil(MCPImageOutput.sourceRect(x: 0, y: 0, width: 0, height: 5, detail: .standard, sourceWidth: 3024, sourceHeight: 1964))
        XCTAssertEqual(
            MCPImageOutput.sourceRect(x: 5, y: 6, width: 7, height: 8, detail: .standard, sourceWidth: 800, sourceHeight: 600),
            CGRect(x: 5, y: 6, width: 7, height: 8)
        )
    }

    func testMarkdownBlocksOrganizeDocumentStructure() {
        var layout = ScreenCaptureService.OCRLayout()
        layout.title = ("Report", CGRect(x: 10, y: 0, width: 200, height: 30))
        layout.paragraphs = [
            ("Report", CGRect(x: 10, y: 0, width: 200, height: 30)),
            ("Intro   text\n  second line ", CGRect(x: 10, y: 40, width: 300, height: 40)),
            ("   ", CGRect(x: 10, y: 90, width: 10, height: 10)),
            ("Name", CGRect(x: 20, y: 210, width: 40, height: 20)),
            ("first item", CGRect(x: 20, y: 110, width: 80, height: 20)),
        ]
        layout.lists = [(["first item", " second\nitem "], CGRect(x: 10, y: 100, width: 300, height: 60))]
        layout.tables = [([
            .init(row: 0, column: 0, text: "Name"),
            .init(row: 0, column: 1, text: "Value"),
            .init(row: 1, column: 0, text: "a|b"),
            .init(row: 1, column: 1, text: "line\nbreak"),
            .init(row: 2, column: 0, text: "merged"),
            .init(row: 2, column: 0, text: "merged"),
        ], CGRect(x: 10, y: 200, width: 300, height: 90))]

        let blocks = ScreenCaptureService.markdownBlocks(layout)
        XCTAssertEqual(blocks.map(\.markdown), [
            "# Report",
            "Intro text\nsecond line",
            "- first item\n- second item",
            "| Name | Value |\n| --- | --- |\n| a\\|b | line break |\n| merged |  |",
        ])
    }

    func testMarkdownTextWithPositionsAndEmptyResult() {
        let blocks = [
            ScreenCaptureService.OCRBlock(markdown: "# T", rect: CGRect(x: 100, y: 40, width: 200, height: 20)),
            ScreenCaptureService.OCRBlock(markdown: "Body", rect: CGRect(x: 100, y: 80, width: 400, height: 60)),
        ]
        let size = (width: 1000, height: 500)
        XCTAssertEqual(MCPImageOutput.text(blocks, scaleX: 0.5, scaleY: 0.5, size: size, includePositions: false), "# T\n\nBody")
        XCTAssertEqual(
            MCPImageOutput.text(blocks, scaleX: 0.5, scaleY: 0.5, size: size, includePositions: true),
            "[image 1000×500]\n\n[50,20,100,10]\n# T\n\n[50,40,200,30]\nBody"
        )
        XCTAssertEqual(MCPImageOutput.text([], scaleX: 1, scaleY: 1, size: size, includePositions: true), AppConstants.mcpNoTextMessage)
    }

    func testImageReplyScalesPngAndReturnsMarkdown() async throws {
        let png = try textImage(width: 3136, height: 400, text: "TranSnap", x: 400, baseline: 140)
        let source = try MCPImageOutput.image(png)

        let both = MCPCaptureOptions(output: .both, detail: .standard, includePositions: false)
        guard case .image(let image, let markdown) = try await MCPImageOutput.reply(source, options: both) else {
            return XCTFail("应返回截图结果")
        }
        let returned = try MCPImageOutput.image(try XCTUnwrap(image))
        let expected = MCPImageOutput.fitted(width: 3136, height: 400, detail: .standard)
        XCTAssertEqual(returned.width, expected.width)
        XCTAssertEqual(returned.height, expected.height)
        XCTAssertTrue(try XCTUnwrap(markdown).contains("TranSnap"), markdown ?? "")

        guard case .image(let imageOnly, let noText) = try await MCPImageOutput.reply(
            source, options: MCPCaptureOptions(output: .image, detail: .low, includePositions: false)
        ) else { return XCTFail("应返回截图结果") }
        XCTAssertLessThanOrEqual(tokens(try MCPImageOutput.image(try XCTUnwrap(imageOnly)).size), MCPDetail.low.tokenBudget)
        XCTAssertNil(noText)
        guard case .image(let noImage, let textOnly) = try await MCPImageOutput.reply(
            source, options: MCPCaptureOptions(output: .text, detail: .standard, includePositions: true)
        ) else { return XCTFail("应返回截图结果") }
        XCTAssertNil(noImage)
        XCTAssertTrue(try XCTUnwrap(textOnly).hasPrefix("[image \(expected.width)×\(expected.height)]"))
    }
}

private extension CGImage {
    var size: (width: Int, height: Int) { (width, height) }
}
