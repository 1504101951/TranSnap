import AppKit

@MainActor
enum MCPToolRunner {
    static func run(_ request: MCPToolRequest) async -> MCPToolReply {
        do {
            switch request {
            case .listDisplays:
                return .displays(displays().map(\.info))
            case .listWindows:
                guard await ScreenCaptureService.requestAccess() else {
                    return .failed(message: AppConstants.mcpPermissionMessage)
                }
                return .windows(try await windows())
            case .captureScreen(let index, let options):
                guard let id = displayID(index) else { return displayOutOfRange(index) }
                return try await capture {
                    try await MCPImageOutput.reply(ScreenCaptureService.captureDisplayImage(
                        displayID: id, showsCursor: false, excludingWindowIDs: Set(MCPControl.shared.indicatorWindowIDs)
                    ).image, options: options)
                }
            case .captureRect(let index, let x, let y, let width, let height, let reference, let options):
                guard let id = displayID(index) else { return displayOutOfRange(index) }
                return try await capture {
                    let image = try await ScreenCaptureService.captureDisplayImage(
                        displayID: id, showsCursor: false, excludingWindowIDs: Set(MCPControl.shared.indicatorWindowIDs)
                    ).image
                    guard let rect = MCPImageOutput.sourceRect(
                        x: x, y: y, width: width, height: height, detail: reference,
                        sourceWidth: image.width, sourceHeight: image.height
                    ), let cropped = image.cropping(to: rect) else {
                        let size = MCPImageOutput.fitted(width: image.width, height: image.height, detail: reference)
                        return .failed(message: AppConstants.mcpRectangleOutOfRangeMessage(reference: reference.rawValue, display: index, width: size.width, height: size.height))
                    }
                    return try await MCPImageOutput.reply(cropped, options: options)
                }
            case .captureWindow(let windowID, let options):
                return try await capture {
                    guard let window = try await ScreenCaptureService.visibleWindows().first(where: { $0.windowID == windowID }) else {
                        return .failed(message: AppConstants.mcpWindowNotFoundMessage(windowID: windowID))
                    }
                    return try await MCPImageOutput.reply(ScreenCaptureService.captureWindowImage(window), options: options)
                }
            case .snapshot(let target, let interactiveOnly, let maxDepth):
                return await MCPAccessibility.snapshot(
                    target: target, interactiveOnly: interactiveOnly, maxDepth: maxDepth, displays: displays()
                )
            case .find(let target, let role, let text):
                return await MCPAccessibility.find(target: target, role: role, text: text, displays: displays())
            case .click, .typeText, .pressKey, .scroll, .drag:
                return await MCPControl.shared.perform(request)
            }
        } catch {
            return .failed(message: AppConstants.mcpCaptureFailedMessage(error.localizedDescription))
        }
    }

    private static func capture(_ body: () async throws -> MCPToolReply) async throws -> MCPToolReply {
        guard await ScreenCaptureService.requestAccess() else {
            return .failed(message: AppConstants.mcpPermissionMessage)
        }
        let finish = StatusBarController.shared.beginMCPCapture()
        defer { finish() }
        return try await body()
    }

    struct Display {
        let info: MCPDisplayInfo
        let bounds: CGRect
        let pixelWidth: Int
        let pixelHeight: Int
    }

    static func displays() -> [Display] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let id = screen.displayID else { return nil }
            let bounds = CGDisplayBounds(id)
            let pixelWidth = Int((bounds.width * screen.backingScaleFactor).rounded())
            let pixelHeight = Int((bounds.height * screen.backingScaleFactor).rounded())
            let standard = MCPImageOutput.fitted(width: pixelWidth, height: pixelHeight, detail: .standard)
            let low = MCPImageOutput.fitted(width: pixelWidth, height: pixelHeight, detail: .low)
            return Display(
                info: MCPDisplayInfo(
                    displayIndex: index, standardWidth: standard.width, standardHeight: standard.height,
                    lowWidth: low.width, lowHeight: low.height
                ),
                bounds: bounds, pixelWidth: pixelWidth, pixelHeight: pixelHeight
            )
        }
    }

    private static func windows() async throws -> [MCPWindowInfo] {
        let displays = displays()
        return try await ScreenCaptureService.visibleWindows().compactMap { window in
            guard let place = standardRect(window.frame, displays: displays) else { return nil }
            return MCPWindowInfo(
                windowID: window.windowID,
                displayIndex: place.displayIndex,
                x: place.x, y: place.y, width: place.width, height: place.height,
                app: window.owningApplication?.applicationName ?? "",
                title: window.title ?? ""
            )
        }
    }

    static func globalPoint(x: Int, y: Int, reference: MCPDetail, display: Display) -> CGPoint? {
        let width = reference == .standard ? display.info.standardWidth : display.info.lowWidth
        let height = reference == .standard ? display.info.standardHeight : display.info.lowHeight
        guard x < width, y < height else { return nil }
        return CGPoint(
            x: display.bounds.minX + (Double(x) + 0.5) * display.bounds.width / Double(width),
            y: display.bounds.minY + (Double(y) + 0.5) * display.bounds.height / Double(height)
        )
    }

    static func standardRect(
        _ frame: CGRect, displays: [Display]
    ) -> (displayIndex: Int, x: Int, y: Int, width: Int, height: Int)? {
        let areas = displays.map { display -> CGFloat in
            let overlap = display.bounds.intersection(frame)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else { return nil }
        let display = displays[best]
        let visible = display.bounds.intersection(frame)
        let scaleX = Double(display.info.standardWidth) / display.bounds.width
        let scaleY = Double(display.info.standardHeight) / display.bounds.height
        let left = Int(((visible.minX - display.bounds.minX) * scaleX).rounded(.down))
        let top = Int(((visible.minY - display.bounds.minY) * scaleY).rounded(.down))
        let right = min(display.info.standardWidth, Int(((visible.maxX - display.bounds.minX) * scaleX).rounded(.up)))
        let bottom = min(display.info.standardHeight, Int(((visible.maxY - display.bounds.minY) * scaleY).rounded(.up)))
        guard right > left, bottom > top else { return nil }
        return (display.info.displayIndex, left, top, right - left, bottom - top)
    }

    private static func displayID(_ index: Int) -> CGDirectDisplayID? {
        let screens = NSScreen.screens
        return screens.indices.contains(index) ? screens[index].displayID : nil
    }

    private static func displayOutOfRange(_ index: Int) -> MCPToolReply {
        .failed(message: AppConstants.mcpDisplayOutOfRangeMessage(index: index, count: NSScreen.screens.count))
    }
}
