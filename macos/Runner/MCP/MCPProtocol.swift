import Darwin
import Foundation

struct MCPCaptureOptions: Codable, Equatable {
    let output: MCPOutput
    let detail: MCPDetail
    let includePositions: Bool
}

enum MCPToolRequest: Codable, Equatable {
    case listDisplays
    case listWindows
    case captureScreen(displayIndex: Int, options: MCPCaptureOptions)
    case captureRect(
        displayIndex: Int, x: Int, y: Int, width: Int, height: Int,
        referenceDetail: MCPDetail, options: MCPCaptureOptions
    )
    case captureWindow(windowID: UInt32, options: MCPCaptureOptions)
    case snapshot(target: MCPAppTarget, interactiveOnly: Bool, maxDepth: Int)
    case find(target: MCPAppTarget, role: String?, text: String?)
    case click(target: MCPPointTarget, button: MCPMouseButton, count: Int, screenshot: Bool)
    case typeText(text: String, target: MCPPointTarget?, screenshot: Bool)
    case pressKey(keys: String, app: String?, screenshot: Bool)
    case scroll(target: MCPPointTarget, direction: MCPScrollDirection, amount: Int, screenshot: Bool)
    case drag(from: MCPPointTarget, toX: Int, toY: Int, screenshot: Bool)

    var isControl: Bool {
        switch self {
        case .listDisplays, .listWindows, .captureScreen, .captureRect, .captureWindow, .snapshot, .find:
            false
        case .click, .typeText, .pressKey, .scroll, .drag:
            true
        }
    }
}

enum MCPPointTarget: Codable, Equatable {
    case ref(String)
    case point(displayIndex: Int, x: Int, y: Int, reference: MCPDetail)
}

enum MCPAppTarget: Codable, Equatable {
    case frontmost
    case app(String)
    case window(UInt32)
    case ref(String)
}

struct MCPElementInfo: Codable, Equatable {
    let ref: String
    let depth: Int
    let role: String
    let name: String
    let value: String
    let enabled: Bool
    let displayIndex: Int?
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct MCPDisplayInfo: Codable, Equatable {
    let displayIndex: Int
    let standardWidth: Int
    let standardHeight: Int
    let lowWidth: Int
    let lowHeight: Int
}

struct MCPWindowInfo: Codable, Equatable {
    let windowID: UInt32
    let displayIndex: Int
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let app: String
    let title: String
}

enum MCPToolReply: Codable, Equatable {
    case displays([MCPDisplayInfo])
    case windows([MCPWindowInfo])
    case image(png: Data?, markdown: String?)
    case elements(snapshot: String, complete: Bool, items: [MCPElementInfo])
    case done(message: String, png: Data?)
    case failed(message: String)
}

enum MCPRequestError: Error, Equatable {
    case unknownTool(String)
    case invalidArgument(String)
}

indirect enum MCPOrderedJSON: Equatable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case array([MCPOrderedJSON])
    case object([(String, MCPOrderedJSON)])

    var data: Data {
        switch self {
        case .string(let value):
            return MCPProtocol.fragment(value)!
        case .integer(let value):
            return Data(String(value).utf8)
        case .boolean(let value):
            return Data((value ? "true" : "false").utf8)
        case .array(let values):
            return Data("[".utf8) + Data(values.map(\.data).joined(separator: Data(",".utf8))) + Data("]".utf8)
        case .object(let members):
            let pairs = members.map { MCPOrderedJSON.string($0.0).data + Data(":".utf8) + $0.1.data }
            return Data("{".utf8) + Data(pairs.joined(separator: Data(",".utf8))) + Data("}".utf8)
        }
    }

    static func == (lhs: MCPOrderedJSON, rhs: MCPOrderedJSON) -> Bool { lhs.data == rhs.data }
}

struct MCPParameter {
    let name: String
    let type: String
    var minimum: Int?
    var values: [String]?
    var defaultValue: MCPOrderedJSON?
    var description: String?

    var schema: MCPOrderedJSON {
        var members: [(String, MCPOrderedJSON)] = [("type", .string(type))]
        if let minimum { members.append(("minimum", .integer(minimum))) }
        if let values { members.append(("enum", .array(values.map(MCPOrderedJSON.string)))) }
        if let defaultValue { members.append(("default", defaultValue)) }
        if let description { members.append(("description", .string(description))) }
        return .object(members)
    }
}

struct MCPToolDefinition {
    let name: String
    let description: String
    let parameters: [MCPParameter]
    let required: [String]

    var json: MCPOrderedJSON {
        var schema: [(String, MCPOrderedJSON)] = [
            ("type", .string("object")),
            ("properties", .object(parameters.map { ($0.name, $0.schema) })),
        ]
        if !required.isEmpty { schema.append(("required", .array(required.map(MCPOrderedJSON.string)))) }
        schema.append(("additionalProperties", .boolean(false)))
        return .object([("name", .string(name)), ("description", .string(description)), ("inputSchema", .object(schema))])
    }
}

enum MCPProtocol {
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603

    static func initializeResult(params: [String: Any], version: String) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let negotiated = requested.flatMap { supportedVersions.contains($0) ? $0 : nil } ?? supportedVersions[0]
        return [
            "protocolVersion": negotiated,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": AppConstants.mcpServerName, "version": version],
        ]
    }

    static func toolDefinitions() -> [MCPToolDefinition] {
        let displayIndex = { (defaultValue: MCPOrderedJSON?) in
            MCPParameter(
                name: "display_index", type: "integer", minimum: 0,
                defaultValue: defaultValue, description: "From list_displays"
            )
        }
        let capture = [
            MCPParameter(
                name: "output", type: "string", values: MCPOutput.allCases.map(\.rawValue),
                defaultValue: .string(MCPOutput.image.rawValue), description: "text: OCR as Markdown, no image"
            ),
            MCPParameter(
                name: "detail", type: "string", values: MCPDetail.allCases.map(\.rawValue),
                defaultValue: .string(MCPDetail.standard.rawValue),
                description: "Image tokens: low ≤ \(MCPDetail.low.tokenBudget), standard ≤ \(MCPDetail.standard.tokenBudget)"
            ),
            MCPParameter(
                name: "include_positions", type: "boolean", defaultValue: .boolean(false),
                description: "Applies when output includes text. Adds an [x,y,w,h] line before each block, in returned image pixels"
            ),
        ]
        let referenceDetail = MCPParameter(
            name: "reference_detail", type: "string", values: MCPDetail.allCases.map(\.rawValue),
            defaultValue: .string(MCPDetail.standard.rawValue),
            description: "Detail of the capture_screen image the coordinates come from"
        )
        let pointTarget = [
            MCPParameter(name: "ref", type: "string", description: "From snapshot or find; instead of a point"),
            displayIndex(nil),
            MCPParameter(name: "x", type: "integer", minimum: 0, description: "x < image width of reference_detail in list_displays"),
            MCPParameter(name: "y", type: "integer", minimum: 0, description: "y < image height of reference_detail in list_displays"),
            referenceDetail,
        ]
        let returnScreenshot = MCPParameter(
            name: "return_screenshot", type: "boolean", defaultValue: .boolean(false),
            description: "Attach a standard capture of the display after the action"
        )
        let appTarget = [
            MCPParameter(name: "app", type: "string", description: "App name or bundle id; default the frontmost app"),
            MCPParameter(name: "window_id", type: "integer", minimum: 1, description: "From list_windows; instead of app"),
        ]
        return MCPTool.allCases.map { tool in
            switch tool {
            case .listDisplays:
                return MCPToolDefinition(
                    name: tool.rawValue,
                    description: "List connected displays. Use when you need screen information, or first to get display_index and the image sizes capture_screen returns.",
                    parameters: [], required: []
                )
            case .listWindows:
                return MCPToolDefinition(
                    name: tool.rawValue,
                    description: "List visible app windows. Use when you need screen information, to find a window_id for capture_window, or a window's rectangle for capture_rect.",
                    parameters: [], required: []
                )
            case .captureScreen:
                return MCPToolDefinition(
                    name: tool.rawValue,
                    description: "Capture a whole display. Use for an overview of what is on screen; zoom into details with capture_rect.",
                    parameters: [displayIndex(.integer(0))] + capture, required: []
                )
            case .captureRect:
                return MCPToolDefinition(
                    name: tool.rawValue,
                    description: "Capture part of a display at native resolution. Use to read small text or inspect details seen in capture_screen, or to OCR one area only.",
                    parameters: [
                        displayIndex(nil),
                        MCPParameter(name: "x", type: "integer", minimum: 0, description: "x + width ≤ image width of reference_detail in list_displays"),
                        MCPParameter(name: "y", type: "integer", minimum: 0, description: "y + height ≤ image height of reference_detail in list_displays"),
                        MCPParameter(name: "width", type: "integer", minimum: 1),
                        MCPParameter(name: "height", type: "integer", minimum: 1),
                        MCPParameter(
                            name: "reference_detail", type: "string", values: MCPDetail.allCases.map(\.rawValue),
                            defaultValue: .string(MCPDetail.standard.rawValue),
                            description: "Detail of the capture_screen image the coordinates come from"
                        ),
                    ] + capture,
                    required: ["display_index", "x", "y", "width", "height"]
                )
            case .captureWindow:
                return MCPToolDefinition(
                    name: tool.rawValue,
                    description: "Capture one app window, even when covered by other windows. Use when the target is a specific window.",
                    parameters: [MCPParameter(name: "window_id", type: "integer", minimum: 1, description: "From list_windows")] + capture,
                    required: ["window_id"]
                )
            case .snapshot:
                return MCPToolDefinition(
                    name: tool.rawValue,
                    description: "List an app's UI elements from the accessibility tree. Each row has a ref for actions and its rectangle in the standard capture_screen image of display_index. Use first to operate an app; if it returns few or no elements, use capture_screen and pixel coordinates instead.",
                    parameters: appTarget + [
                        MCPParameter(name: "root", type: "string", description: "A ref from an earlier snapshot; expands only that element"),
                        MCPParameter(name: "interactive_only", type: "boolean", defaultValue: .boolean(true)),
                        MCPParameter(
                            name: "max_depth", type: "integer", minimum: 1,
                            defaultValue: .integer(AppConstants.mcpSnapshotDefaultDepth),
                            description: "≤ \(AppConstants.mcpSnapshotMaxDepth)"
                        ),
                    ],
                    required: []
                )
            case .click:
                return MCPToolDefinition(
                    name: tool.rawValue,
                    description: "Click an element by ref (from snapshot or find), or a point in a capture_screen image. Refs act in the background when possible; points briefly bring the app to the front, then restore the previous app and pointer.",
                    parameters: pointTarget + [
                        MCPParameter(name: "button", type: "string", values: MCPMouseButton.allCases.map(\.rawValue), defaultValue: .string(MCPMouseButton.left.rawValue)),
                        MCPParameter(name: "count", type: "integer", minimum: 1, defaultValue: .integer(1), description: "1 or 2"),
                        returnScreenshot,
                    ],
                    required: []
                )
            case .typeText:
                return MCPToolDefinition(
                    name: tool.rawValue,
                    description: "Type text into the element given by ref or point, or into the focused element of the frontmost app when neither is given. Password fields are refused.",
                    parameters: [MCPParameter(name: "text", type: "string")] + pointTarget + [returnScreenshot],
                    required: ["text"]
                )
            case .pressKey:
                return MCPToolDefinition(
                    name: tool.rawValue,
                    description: "Press a key combination such as cmd+s, return, shift+tab or f5, sent to app or to the frontmost app. Quit, log-out and force-quit shortcuts are refused.",
                    parameters: [
                        MCPParameter(name: "keys", type: "string", description: "Modifiers cmd, shift, opt, ctrl joined with +"),
                        MCPParameter(name: "app", type: "string", description: "App name or bundle id; default the frontmost app"),
                        returnScreenshot,
                    ],
                    required: ["keys"]
                )
            case .scroll:
                return MCPToolDefinition(
                    name: tool.rawValue,
                    description: "Scroll at an element by ref or at a point in a capture_screen image.",
                    parameters: pointTarget + [
                        MCPParameter(name: "direction", type: "string", values: MCPScrollDirection.allCases.map(\.rawValue)),
                        MCPParameter(name: "amount", type: "integer", minimum: 1, defaultValue: .integer(3), description: "Lines"),
                        returnScreenshot,
                    ],
                    required: ["direction"]
                )
            case .drag:
                return MCPToolDefinition(
                    name: tool.rawValue,
                    description: "Drag with the left button from (x, y) to (to_x, to_y) in one capture_screen image; briefly takes over the pointer.",
                    parameters: [
                        displayIndex(nil),
                        MCPParameter(name: "x", type: "integer", minimum: 0),
                        MCPParameter(name: "y", type: "integer", minimum: 0),
                        MCPParameter(name: "to_x", type: "integer", minimum: 0),
                        MCPParameter(name: "to_y", type: "integer", minimum: 0),
                        referenceDetail,
                        returnScreenshot,
                    ],
                    required: ["display_index", "x", "y", "to_x", "to_y"]
                )
            case .find:
                return MCPToolDefinition(
                    name: tool.rawValue,
                    description: "Find UI elements by role and/or text in the accessibility tree, returning refs and rectangles like snapshot. Use when you know what the element says or is.",
                    parameters: appTarget + [
                        MCPParameter(name: "role", type: "string", description: "e.g. button, textfield, link, menuitem"),
                        MCPParameter(name: "text", type: "string", description: "Case-insensitive substring of the name or value"),
                    ],
                    required: []
                )
            }
        }
    }

    static func toolsListResult() -> Data {
        MCPOrderedJSON.object([("tools", .array(toolDefinitions().map(\.json)))]).data
    }

    static func toolRequest(params: [String: Any]) throws(MCPRequestError) -> MCPToolRequest {
        let name = params["name"] as? String ?? ""
        guard let tool = MCPTool(rawValue: name) else { throw .unknownTool(name) }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let declared = Set(toolDefinitions().first { $0.name == name }!.parameters.map(\.name))
        if let unknown = arguments.keys.sorted().first(where: { !declared.contains($0) }) {
            throw .invalidArgument(AppConstants.mcpUnknownArgumentMessage(unknown))
        }

        switch tool {
        case .listDisplays:
            return .listDisplays
        case .listWindows:
            return .listWindows
        case .captureScreen:
            return .captureScreen(
                displayIndex: try integer(arguments, "display_index", minimum: 0) ?? 0,
                options: try options(arguments)
            )
        case .captureRect:
            return .captureRect(
                displayIndex: try required(arguments, "display_index", minimum: 0),
                x: try required(arguments, "x", minimum: 0),
                y: try required(arguments, "y", minimum: 0),
                width: try required(arguments, "width", minimum: 1),
                height: try required(arguments, "height", minimum: 1),
                referenceDetail: try choice(arguments, "reference_detail", default: MCPDetail.standard),
                options: try options(arguments)
            )
        case .captureWindow:
            let id = try required(arguments, "window_id", minimum: 1)
            guard id <= Int(UInt32.max) else { throw .invalidArgument("window_id \(id) not found; call list_windows again.") }
            return .captureWindow(windowID: UInt32(id), options: try options(arguments))
        case .snapshot:
            return .snapshot(
                target: try appTarget(arguments, allowsRoot: true),
                interactiveOnly: try boolean(arguments, "interactive_only") ?? true,
                maxDepth: min(
                    AppConstants.mcpSnapshotMaxDepth,
                    try integer(arguments, "max_depth", minimum: 1) ?? AppConstants.mcpSnapshotDefaultDepth
                )
            )
        case .click:
            let count = try integer(arguments, "count", minimum: 1) ?? 1
            guard count <= 2 else { throw .invalidArgument(AppConstants.mcpClickCountMessage) }
            guard let target = try pointTarget(arguments) else { throw .invalidArgument(AppConstants.mcpPointTargetMessage) }
            return .click(
                target: target, button: try choice(arguments, "button", default: MCPMouseButton.left),
                count: count, screenshot: try boolean(arguments, "return_screenshot") ?? false
            )
        case .typeText:
            guard let text = arguments["text"] as? String, !text.isEmpty else {
                throw .invalidArgument(AppConstants.mcpMissingArgumentMessage("text"))
            }
            return .typeText(text: text, target: try pointTarget(arguments), screenshot: try boolean(arguments, "return_screenshot") ?? false)
        case .pressKey:
            guard let keys = try string(arguments, "keys") else { throw .invalidArgument(AppConstants.mcpMissingArgumentMessage("keys")) }
            return .pressKey(keys: keys, app: try string(arguments, "app"), screenshot: try boolean(arguments, "return_screenshot") ?? false)
        case .scroll:
            guard arguments["direction"] != nil else { throw .invalidArgument(AppConstants.mcpMissingArgumentMessage("direction")) }
            guard let target = try pointTarget(arguments) else { throw .invalidArgument(AppConstants.mcpPointTargetMessage) }
            return .scroll(
                target: target, direction: try choice(arguments, "direction", default: MCPScrollDirection.down),
                amount: try integer(arguments, "amount", minimum: 1) ?? 3,
                screenshot: try boolean(arguments, "return_screenshot") ?? false
            )
        case .drag:
            guard case .point(let index, let x, let y, let reference) = try pointTarget(arguments) else {
                throw .invalidArgument(AppConstants.mcpDragTargetMessage)
            }
            return .drag(
                from: .point(displayIndex: index, x: x, y: y, reference: reference),
                toX: try required(arguments, "to_x", minimum: 0), toY: try required(arguments, "to_y", minimum: 0),
                screenshot: try boolean(arguments, "return_screenshot") ?? false
            )
        case .find:
            let role = try string(arguments, "role")
            let text = try string(arguments, "text")
            guard role != nil || text != nil else { throw .invalidArgument(AppConstants.mcpFindFilterMessage) }
            return .find(target: try appTarget(arguments, allowsRoot: false), role: role, text: text)
        }
    }

    private static func appTarget(_ arguments: [String: Any], allowsRoot: Bool) throws(MCPRequestError) -> MCPAppTarget {
        let app = try string(arguments, "app")
        let window = try integer(arguments, "window_id", minimum: 1)
        let root = allowsRoot ? try string(arguments, "root") : nil
        let given = [app != nil, window != nil, root != nil].filter { $0 }.count
        guard given <= 1 else { throw .invalidArgument(AppConstants.mcpTargetConflictMessage) }
        if let app { return .app(app) }
        if let window {
            guard window <= Int(UInt32.max) else { throw .invalidArgument("window_id \(window) not found; call list_windows again.") }
            return .window(UInt32(window))
        }
        if let root { return .ref(root) }
        return .frontmost
    }

    private static func pointTarget(_ arguments: [String: Any]) throws(MCPRequestError) -> MCPPointTarget? {
        let ref = try string(arguments, "ref")
        let index = try integer(arguments, "display_index", minimum: 0)
        let x = try integer(arguments, "x", minimum: 0)
        let y = try integer(arguments, "y", minimum: 0)
        let pointKeys = [index, x, y].compactMap { $0 }.count
        if let ref {
            guard pointKeys == 0, arguments["reference_detail"] == nil else { throw .invalidArgument(AppConstants.mcpPointTargetMessage) }
            return .ref(ref)
        }
        guard pointKeys > 0 else { return nil }
        guard let index, let x, let y else { throw .invalidArgument(AppConstants.mcpPointTargetMessage) }
        return .point(displayIndex: index, x: x, y: y, reference: try choice(arguments, "reference_detail", default: MCPDetail.standard))
    }

    private static func string(_ arguments: [String: Any], _ key: String) throws(MCPRequestError) -> String? {
        guard let raw = arguments[key] else { return nil }
        guard let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw .invalidArgument("\(key) must be a non-empty string")
        }
        return value
    }

    static func toolResult(_ reply: MCPToolReply) -> [String: Any] {
        switch reply {
        case .failed(let message):
            return toolError(message)
        case .displays(let displays):
            let rows = displays.map {
                "\($0.displayIndex)\t\($0.standardWidth)\t\($0.standardHeight)\t\($0.lowWidth)\t\($0.lowHeight)"
            }
            let table = (["display_index\tstandard_image_width\tstandard_image_height\tlow_image_width\tlow_image_height"] + rows)
            return ["content": [textContent(table.joined(separator: "\n"))], "isError": false]
        case .windows(let windows):
            let rows = windows.map {
                "\($0.windowID)\t\($0.displayIndex)\t\($0.x)\t\($0.y)\t\($0.width)\t\($0.height)\t\(cell($0.app))\t\(cell($0.title))"
            }
            let table = ["window_id\tdisplay_index\tx\ty\twidth\theight\tapp\ttitle"] + rows
            return ["content": [textContent(table.joined(separator: "\n"))], "isError": false]
        case .image(let png, let markdown):
            var content: [[String: Any]] = []
            if let png { content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]) }
            if let markdown { content.append(textContent(markdown)) }
            return ["content": content, "isError": false]
        case .elements(let snapshot, let complete, let items):
            let rows = items.map { item in
                let place = item.displayIndex.map { "\($0)\t\(item.x)\t\(item.y)\t\(item.width)\t\(item.height)" } ?? "\t\t\t\t"
                return "\(item.ref)\t\(item.depth)\t\(item.role)\t\(cell(item.name))\t\(cell(item.value))\t\(item.enabled)\t\(place)"
            }
            let status = complete ? "complete" : "incomplete; expand a ref with root or narrow the target"
            let table = ["snapshot \(snapshot) \(status)", "ref\tdepth\trole\tname\tvalue\tenabled\tdisplay_index\tx\ty\twidth\theight"] + rows
            return ["content": [textContent(table.joined(separator: "\n"))], "isError": false]
        case .done(let message, let png):
            var content = [textContent(message)]
            if let png { content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]) }
            return ["content": content, "isError": false]
        }
    }

    static func toolError(_ message: String) -> [String: Any] {
        ["content": [textContent(message)], "isError": true]
    }

    static func response(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func fragment(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject([value]) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    }

    static func encode(_ object: [String: Any]) -> Data {
        if JSONSerialization.isValidJSONObject(object),
           let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) {
            return data
        }
        return internalErrorData(id: object["id"])
    }

    static func internalErrorData(id: Any?) -> Data {
        let idJSON = id.flatMap(fragment) ?? Data("null".utf8)
        return Data(#"{"jsonrpc":"2.0","id":"#.utf8) + idJSON
            + Data(#","error":{"code":\#(internalError),"message":"\#(AppConstants.mcpInternalErrorMessage)"}}"#.utf8)
    }

    static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func options(_ arguments: [String: Any]) throws(MCPRequestError) -> MCPCaptureOptions {
        MCPCaptureOptions(
            output: try choice(arguments, "output", default: MCPOutput.image),
            detail: try choice(arguments, "detail", default: MCPDetail.standard),
            includePositions: try boolean(arguments, "include_positions") ?? false
        )
    }

    private static func choice<T: RawRepresentable & CaseIterable>(
        _ arguments: [String: Any], _ key: String, default defaultValue: T
    ) throws(MCPRequestError) -> T where T.RawValue == String {
        guard let raw = arguments[key] else { return defaultValue }
        guard let value = (raw as? String).flatMap(T.init(rawValue:)) else {
            throw .invalidArgument("\(key) must be one of \(T.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return value
    }

    private static func boolean(_ arguments: [String: Any], _ key: String) throws(MCPRequestError) -> Bool? {
        guard let raw = arguments[key] else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw .invalidArgument("\(key) must be a boolean")
        }
        return number.boolValue
    }

    private static func required(_ arguments: [String: Any], _ key: String, minimum: Int) throws(MCPRequestError) -> Int {
        guard let value = try integer(arguments, key, minimum: minimum) else {
            throw .invalidArgument(AppConstants.mcpMissingArgumentMessage(key))
        }
        return value
    }

    private static func integer(_ arguments: [String: Any], _ key: String, minimum: Int) throws(MCPRequestError) -> Int? {
        guard let raw = arguments[key] else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded(), number.doubleValue >= Double(minimum),
              number.doubleValue <= Double(Int.max) else {
            throw .invalidArgument("\(key) must be an integer ≥ \(minimum)")
        }
        return number.intValue
    }

    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func textContent(_ text: String) -> [String: Any] {
        ["type": "text", "text": text]
    }
}

final class MCPForwardCall {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false

    func run(_ request: MCPToolRequest, path: String) -> MCPToolReply? {
        let connected: Int32
        do {
            connected = try MCPSocket.connect(path: path)
        } catch MCPSocketError.notRunning {
            return .failed(message: AppConstants.mcpNotRunningMessage)
        } catch {
            return .failed(message: AppConstants.mcpConnectFailedMessage(error.localizedDescription))
        }
        guard attach(connected) else { return nil }
        defer { detachAndClose(connected) }
        do {
            try MCPSocket.writeLine(JSONEncoder().encode(request), to: connected)
            guard let line = try MCPSocket.readLine(from: connected) else {
                return isCancelled ? nil : .failed(message: AppConstants.mcpConnectionClosedMessage)
            }
            return try JSONDecoder().decode(MCPToolReply.self, from: line)
        } catch is DecodingError {
            return isCancelled ? nil : .failed(message: AppConstants.mcpVersionMismatchMessage)
        } catch {
            return isCancelled ? nil : .failed(message: AppConstants.mcpCommunicationFailedMessage(error.localizedDescription))
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func attach(_ connected: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else {
            close(connected)
            return false
        }
        fd = connected
        return true
    }

    private func detachAndClose(_ connected: Int32) {
        lock.lock()
        fd = -1
        lock.unlock()
        close(connected)
    }
}

final class MCPHelperSession {
    private let socketPath: String
    private let version: String
    private let write: (Data) -> Void
    private let lock = NSLock()
    private var calls: [String: MCPForwardCall] = [:]

    init(socketPath: String, version: String, write: @escaping (Data) -> Void) {
        self.socketPath = socketPath
        self.version = version
        self.write = write
    }

    func receive(_ line: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) else {
            return emit(MCPProtocol.error(id: NSNull(), code: MCPProtocol.parseError, message: AppConstants.mcpParseErrorMessage))
        }
        guard let object = message as? [String: Any], object["jsonrpc"] as? String == "2.0",
              let method = object["method"] as? String else {
            let id = (message as? [String: Any])?["id"] ?? NSNull()
            return emit(MCPProtocol.error(id: id, code: MCPProtocol.invalidRequest, message: "Invalid Request"))
        }
        let params = object["params"] as? [String: Any] ?? [:]
        guard let id = object["id"] else { return notify(method, params: params) }
        guard let key = Self.key(id) else {
            return emit(MCPProtocol.error(id: NSNull(), code: MCPProtocol.invalidRequest, message: "Invalid Request"))
        }

        switch method {
        case "initialize":
            emit(MCPProtocol.response(id: id, result: MCPProtocol.initializeResult(params: params, version: version)))
        case "ping":
            emit(MCPProtocol.response(id: id, result: [:]))
        case "tools/list":
            emitRaw(id: id, result: MCPProtocol.toolsListResult())
        case "tools/call":
            call(id: id, key: key, params: params)
        default:
            emit(MCPProtocol.error(id: id, code: MCPProtocol.methodNotFound, message: AppConstants.mcpMethodNotFoundMessage(method)))
        }
    }

    private func call(id: Any, key: String, params: [String: Any]) {
        let request: MCPToolRequest
        do {
            request = try MCPProtocol.toolRequest(params: params)
        } catch {
            switch error {
            case .unknownTool(let name):
                return emit(MCPProtocol.error(id: id, code: MCPProtocol.invalidParams, message: AppConstants.mcpUnknownToolMessage(name)))
            case .invalidArgument(let message):
                return emit(MCPProtocol.response(id: id, result: MCPProtocol.toolError(message)))
            }
        }

        let forward = MCPForwardCall()
        lock.lock()
        calls[key] = forward
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let reply = forward.run(request, path: socketPath)
            lock.lock()
            calls[key] = nil
            lock.unlock()
            guard let reply else { return }
            emit(MCPProtocol.response(id: id, result: MCPProtocol.toolResult(reply)))
        }
    }

    private func notify(_ method: String, params: [String: Any]) {
        guard method == "notifications/cancelled", let id = params["requestId"], let key = Self.key(id) else { return }
        lock.lock()
        let forward = calls[key]
        lock.unlock()
        forward?.cancel()
    }

    private func emitRaw(id: Any, result: Data) {
        guard let idJSON = MCPProtocol.fragment(id) else {
            lock.lock()
            defer { lock.unlock() }
            write(MCPProtocol.internalErrorData(id: nil))
            return
        }
        var data = Data(#"{"jsonrpc":"2.0","id":"#.utf8)
        data.append(idJSON)
        data.append(Data(#","result":"#.utf8))
        data.append(result)
        data.append(Data("}".utf8))
        lock.lock()
        defer { lock.unlock() }
        write(data)
    }

    private func emit(_ object: [String: Any]) {
        let data = MCPProtocol.encode(object)
        lock.lock()
        defer { lock.unlock() }
        write(data)
    }

    private static func key(_ id: Any) -> String? {
        if let text = id as? String { return "s:\(text)" }
        if let number = id as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return "n:\(number.stringValue)" }
        return nil
    }
}
