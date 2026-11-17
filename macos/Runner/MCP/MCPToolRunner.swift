import AppKit

/// 在 App 进程执行 MCP 工具（#96「工具」）：列出显示器与窗口，按显示器、矩形或窗口截图并生成结果。
/// 不进入截图编辑或采集会话，不写翻译历史，不保存文件；截图类工具执行期间菜单栏显示采集状态。
@MainActor
enum MCPToolRunner {
    /// 作用：执行一次工具请求。
    /// 参数 request：helper 转来的、已通过参数类型校验的请求。
    /// 返回：清单或截图结果；序号越界、矩形越界、窗口不存在、权限不足与截图失败返回 failed。
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
                    // 截图排除操控边框（#67「电脑操控提示」）。
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
                    // sourceRect 把 reference 清晰度下 capture_screen 输出图的坐标换算回原始像素。
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
                // MCPAccessibility 遍历无障碍树并保存 ref；坐标换成各显示器 standard 输出图像素。
                return await MCPAccessibility.snapshot(
                    target: target, interactiveOnly: interactiveOnly, maxDepth: maxDepth, displays: displays()
                )
            case .find(let target, let role, let text):
                return await MCPAccessibility.find(target: target, role: role, text: text, displays: displays())
            case .click, .typeText, .pressKey, .scroll, .drag:
                // MCPControl 管理操控会话、授权与执行分档。
                return await MCPControl.shared.perform(request)
            }
        } catch {
            return .failed(message: AppConstants.mcpCaptureFailedMessage(error.localizedDescription))
        }
    }

    /// 作用：截图类工具的公共流程：确认屏幕录制授权，执行期间切换菜单栏采集状态。
    /// 参数 body：实际截图与结果生成。返回：body 的结果；未授权时返回权限错误。
    private static func capture(_ body: () async throws -> MCPToolReply) async throws -> MCPToolReply {
        // requestAccess 已授权时直接返回；未授权时请求系统授权并等待结果。
        guard await ScreenCaptureService.requestAccess() else {
            return .failed(message: AppConstants.mcpPermissionMessage)
        }
        // beginMCPCapture 切换菜单栏图标，返回的回调在最短保持时间后恢复。
        let finish = StatusBarController.shared.beginMCPCapture()
        defer { finish() }
        return try await body()
    }

    /// 一块显示器的几何：bounds 为全局点坐标（原点主显示器左上角），pixelWidth/Height 为物理像素尺寸。
    struct Display {
        let info: MCPDisplayInfo
        let bounds: CGRect
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// 作用：列出显示器。返回：按 NSScreen.screens 顺序的显示器，0 为主显示器。
    static func displays() -> [Display] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let id = screen.displayID else { return nil }
            let bounds = CGDisplayBounds(id)
            // 与 captureDisplayImage 一致：物理像素为点尺寸乘点到像素比例。
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

    /// 作用：列出屏上可见窗口。
    /// 返回：与任一显示器相交的窗口；display_index 为相交面积最大的显示器，范围为该显示器 standard 输出图像素并裁到图内。
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

    /// 作用：把截图像素坐标换成全局点坐标（操作工具的坐标目标，#140）。
    /// 参数 x、y：reference 清晰度下 capture_screen 输出图的像素；reference：参考清晰度；display：所在显示器几何。
    /// 返回：该像素中心对应的全局点；坐标超出输出图时为 nil。
    static func globalPoint(x: Int, y: Int, reference: MCPDetail, display: Display) -> CGPoint? {
        let width = reference == .standard ? display.info.standardWidth : display.info.lowWidth
        let height = reference == .standard ? display.info.standardHeight : display.info.lowHeight
        guard x < width, y < height else { return nil }
        // 取像素中心，再按点尺寸与输出图尺寸之比换回该显示器内的点，加上显示器原点。
        return CGPoint(
            x: display.bounds.minX + (Double(x) + 0.5) * display.bounds.width / Double(width),
            y: display.bounds.minY + (Double(y) + 0.5) * display.bounds.height / Double(height)
        )
    }

    /// 作用：把全局点坐标矩形换成显示器 standard 输出图像素（窗口与无障碍元素共用，#140）。
    /// 参数 frame：全局点坐标矩形（原点主显示器左上角）；displays：当前显示器几何。
    /// 返回：相交面积最大的显示器序号与裁到图内的像素范围；不与任何显示器相交或裁剪后为空时为 nil。
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
        // 全局点坐标先换成该显示器内的相对点，再按 standard 输出图与点尺寸之比换成输出图像素。
        let scaleX = Double(display.info.standardWidth) / display.bounds.width
        let scaleY = Double(display.info.standardHeight) / display.bounds.height
        let left = Int(((visible.minX - display.bounds.minX) * scaleX).rounded(.down))
        let top = Int(((visible.minY - display.bounds.minY) * scaleY).rounded(.down))
        let right = min(display.info.standardWidth, Int(((visible.maxX - display.bounds.minX) * scaleX).rounded(.up)))
        let bottom = min(display.info.standardHeight, Int(((visible.maxY - display.bounds.minY) * scaleY).rounded(.up)))
        guard right > left, bottom > top else { return nil }
        return (display.info.displayIndex, left, top, right - left, bottom - top)
    }

    /// 作用：把显示器序号转换为 CGDirectDisplayID。参数 index：0 起序号。返回：越界时为 nil。
    private static func displayID(_ index: Int) -> CGDirectDisplayID? {
        let screens = NSScreen.screens
        return screens.indices.contains(index) ? screens[index].displayID : nil
    }

    /// 作用：生成显示器序号越界的错误。参数 index：请求的序号。返回：failed 结果。
    private static func displayOutOfRange(_ index: Int) -> MCPToolReply {
        .failed(message: AppConstants.mcpDisplayOutOfRangeMessage(index: index, count: NSScreen.screens.count))
    }
}
