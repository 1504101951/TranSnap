import AppKit
import CoreGraphics
import CoreVideo
import ScreenCaptureKit
import Vision

enum ScreenCaptureService {
    private static let displayUnreadableMessage = "无法读取显示器内容，请检查屏幕录制权限。"

    struct FreezeFrame {
        let displayID: CGDirectDisplayID
        let scale: CGFloat
        let image: CGImage
        let pixelWidth: Int
        let pixelHeight: Int
        let displayFrame: NSRect
        let windowCrop: NSRect?
    }

    static func isAuthorized() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @MainActor
    static func requestAccess(promoteToRegularApp: Bool = false) async -> Bool {
        if isAuthorized() { return true }
        let presence = NSObject()
        if promoteToRegularApp {
            DockPresence.enter(presence)
            NSApp.activate(ignoringOtherApps: true)
        }
        defer { DockPresence.leave(presence) }
        _ = CGRequestScreenCaptureAccess()
        _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        for _ in 0..<20 {
            if isAuthorized() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return isAuthorized()
    }

    static func openScreenRecordingSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    @MainActor
    static func captureActiveDisplay(displayID: CGDirectDisplayID?, showsCursor: Bool) async throws -> FreezeFrame {
        let mouse = NSEvent.mouseLocation
        let screen = displayID == nil
            ? (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)
            : NSScreen.screens.first { $0.displayID == displayID }
        guard let screen else {
            throw NSError(
                domain: AppConstants.errorDomain,
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "找不到可用显示器。"]
            )
        }
        guard let screenNumber = screen.displayID else {
            throw NSError(
                domain: AppConstants.errorDomain,
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: displayUnreadableMessage]
            )
        }
        let captureStart = ContinuousClock.now
        let (image, scale) = try await captureDisplayImage(displayID: screenNumber, showsCursor: showsCursor, excludingWindowIDs: [])
        PerformanceLog.record("screenshot-capture-image", since: captureStart)
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, order == .byteOrder32Little,
              [.premultipliedFirst, .noneSkipFirst, .first].contains(image.alphaInfo) else {
            throw NSError(
                domain: AppConstants.errorDomain,
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "截图像素格式不受支持。"]
            )
        }
        var windowCrop: NSRect?
        if displayID == nil {
            let cropStart = ContinuousClock.now
            windowCrop = CaptureGeometry.frontmostWindowPixelCrop(
                displayFrame: screen.frame,
                pixelWidth: image.width,
                pixelHeight: image.height
            )
            PerformanceLog.record("screenshot-window-crop", since: cropStart)
        }
        return FreezeFrame(
            displayID: screenNumber,
            scale: scale,
            image: image,
            pixelWidth: image.width,
            pixelHeight: image.height,
            displayFrame: screen.frame,
            windowCrop: windowCrop
        )
    }

    static func captureDisplayImage(
        displayID: CGDirectDisplayID, showsCursor: Bool, excludingWindowIDs: Set<CGWindowID>
    ) async throws -> (image: CGImage, scale: CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(
                domain: AppConstants.errorDomain,
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: displayUnreadableMessage]
            )
        }
        let filter = SCContentFilter(
            display: display, excludingWindows: content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        )
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = imageConfiguration(
            width: max(display.width, Int((filter.contentRect.width * scale).rounded())),
            height: max(display.height, Int((filter.contentRect.height * scale).rounded())),
            showsCursor: showsCursor
        )
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return (image, scale)
    }

    static func visibleWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.filter {
            $0.isOnScreen && $0.windowLayer == 0 && $0.owningApplication?.processID != ownPID
                && $0.frame.width > 0 && $0.frame.height > 0
        }
    }

    static func captureWindowImage(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = imageConfiguration(
            width: max(1, Int((filter.contentRect.width * scale).rounded())),
            height: max(1, Int((filter.contentRect.height * scale).rounded())),
            showsCursor: false
        )
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private static func imageConfiguration(width: Int, height: Int, showsCursor: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.showsCursor = showsCursor
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.scalesToFit = false
        return configuration
    }

    static func decodeImage(png: Data) throws -> CGImage {
        guard let image = NSBitmapImageRep(data: png)?.cgImage else {
            throw NSError(
                domain: AppConstants.errorDomain,
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "无法读取截图以识别文字。"]
            )
        }
        return image
    }

    static func prewarmTextRecognition() {
        Task.detached(priority: .utility) {
            let start = ContinuousClock.now
            guard let image = prewarmImage() else { return }
            async let document = try? paragraphRequest().perform(on: image)
            async let codes = try? DetectBarcodesRequest().perform(on: image)
            _ = await (document, codes)
            PerformanceLog.record("ocr-prewarm", since: start)
        }
    }

    static func prewarmImage() -> CGImage? {
        let width = 960, height = 760
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let lines = ["# Heading 标题 標題", "• item one 第一项", "• item two 第二項", "Paragraph 段落 text."]
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(
                at: NSPoint(x: 20, y: height - 60 - index * 50),
                withAttributes: [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black]
            )
        }
        NSColor.black.setStroke()
        for row in 0...4 {
            NSBezierPath.strokeLine(from: NSPoint(x: 20, y: 300 - row * 50), to: NSPoint(x: 900, y: 300 - row * 50))
        }
        for column in 0...3 {
            NSBezierPath.strokeLine(from: NSPoint(x: 20 + column * 293, y: 100), to: NSPoint(x: 20 + column * 293, y: 300))
        }
        for row in 0..<4 {
            for column in 0..<3 {
                ("Cell \(row)\(column) 单元" as NSString).draw(
                    at: NSPoint(x: 30 + column * 293, y: 110 + row * 50),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black]
                )
            }
        }
        return bitmap.cgImage
    }

    static func recognizeText(image: CGImage) async throws -> String {
        try await recognizeDocument(image: image).map(\.markdown).joined(separator: "\n\n")
    }

    static func detectCodes(image: CGImage) async throws -> [[String: String]] {
        let observations = try await DetectBarcodesRequest().perform(on: image)
        let ordered = observations.sorted { first, second in
            let a = first.boundingBox.cgRect, b = second.boundingBox.cgRect
            return a.maxY != b.maxY ? a.maxY > b.maxY : a.minX < b.minX
        }
        var seen = Set<String>()
        return ordered.compactMap { observation in
            guard let payload = observation.payloadString, !payload.isEmpty else { return nil }
            let symbology = String(describing: observation.symbology)
            guard seen.insert("\(symbology)\n\(payload)").inserted else { return nil }
            return ["symbology": symbology, "payload": payload]
        }
    }

    struct OCRBlock: Equatable {
        let markdown: String
        let rect: CGRect
    }

    struct OCRLayout {
        struct Cell {
            let row: Int
            let column: Int
            let text: String
        }

        var title: (text: String, rect: CGRect)?
        var paragraphs: [(text: String, rect: CGRect)] = []
        var lists: [(items: [String], rect: CGRect)] = []
        var tables: [(cells: [Cell], rect: CGRect)] = []
    }

    static func recognizeDocument(image: CGImage) async throws -> [OCRBlock] {
        let observations = try await paragraphRequest().perform(on: image)
        let width = Double(image.width)
        let height = Double(image.height)
        let pixels = { (region: NormalizedRegion) -> CGRect in
            pixelRect(region.boundingBox.cgRect, width: width, height: height)
        }
        return observations.flatMap { observation -> [OCRBlock] in
            let document = observation.document
            var layout = OCRLayout()
            layout.title = document.title.map { ($0.transcript, pixels($0.boundingRegion)) }
            layout.paragraphs = document.paragraphs.map { ($0.transcript, pixels($0.boundingRegion)) }
            layout.lists = document.lists.map { list in (list.items.map(\.itemString), pixels(list.boundingRegion)) }
            layout.tables = document.tables.map { table in
                let cells = table.rows.flatMap { $0 }.map {
                    OCRLayout.Cell(row: $0.rowRange.lowerBound, column: $0.columnRange.lowerBound, text: $0.content.text.transcript)
                }
                return (cells, pixels(table.boundingRegion))
            }
            return markdownBlocks(layout)
        }
    }

    static func markdownBlocks(_ layout: OCRLayout) -> [OCRBlock] {
        var blocks: [OCRBlock] = []
        let title = layout.title.map { (text: normalized($0.text), rect: $0.rect) }
        if let title, !title.text.isEmpty {
            blocks.append(OCRBlock(markdown: "# \(title.text.replacingOccurrences(of: "\n", with: " "))", rect: title.rect))
        }
        let covered = layout.lists.map(\.rect) + layout.tables.map(\.rect)
        for paragraph in layout.paragraphs {
            let text = normalized(paragraph.text)
            let center = CGPoint(x: paragraph.rect.midX, y: paragraph.rect.midY)
            guard !text.isEmpty, text != title?.text, !covered.contains(where: { $0.contains(center) }) else { continue }
            blocks.append(OCRBlock(markdown: text, rect: paragraph.rect))
        }
        for list in layout.lists {
            let items = list.items.map { cellText($0, escapePipes: false) }.filter { !$0.isEmpty }
            guard !items.isEmpty else { continue }
            blocks.append(OCRBlock(markdown: items.map { "- \($0)" }.joined(separator: "\n"), rect: list.rect))
        }
        for table in layout.tables {
            guard let markdown = tableMarkdown(table.cells) else { continue }
            blocks.append(OCRBlock(markdown: markdown, rect: table.rect))
        }
        return blocks.sorted { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }
    }

    private static func tableMarkdown(_ cells: [OCRLayout.Cell]) -> String? {
        guard let rows = cells.map(\.row).max().map({ $0 + 1 }),
              let columns = cells.map(\.column).max().map({ $0 + 1 }) else { return nil }
        var grid = Array(repeating: Array(repeating: Optional<String>.none, count: columns), count: rows)
        for cell in cells where grid[cell.row][cell.column] == nil {
            grid[cell.row][cell.column] = cellText(cell.text, escapePipes: true)
        }
        let lines = grid.map { row in "| " + row.map { $0 ?? "" }.joined(separator: " | ") + " |" }
        let separator = "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
        return ([lines[0], separator] + lines.dropFirst()).joined(separator: "\n")
    }

    private static func normalized(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func cellText(_ text: String, escapePipes: Bool) -> String {
        let single = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return escapePipes ? single.replacingOccurrences(of: "|", with: "\\|") : single
    }

    static func recognizeParagraphs(pixelBuffer: CVPixelBuffer) async throws -> [[String: Any]] {
        let observations = try await paragraphRequest().perform(on: pixelBuffer)
        return paragraphBlocks(
            observations.flatMap { $0.document.paragraphs },
            width: Double(CVPixelBufferGetWidth(pixelBuffer)),
            height: Double(CVPixelBufferGetHeight(pixelBuffer))
        )
    }

    private static func paragraphRequest() -> RecognizeDocumentsRequest {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.useLanguageCorrection = true
        request.textRecognitionOptions.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].map {
            Locale.Language(identifier: $0)
        }
        return request
    }

    private static func paragraphBlocks(
        _ paragraphs: [DocumentObservation.Container.Text],
        width: Double,
        height: Double
    ) -> [[String: Any]] {
        paragraphs.compactMap { paragraph in
            let text = paragraph.transcript
            guard !text.isEmpty else { return nil }
            return textBlock(text, box: paragraph.boundingRegion.boundingBox.cgRect, width: width, height: height)
        }
    }

    private static func pixelRect(_ box: CGRect, width: Double, height: Double) -> CGRect {
        CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
    }

    private static func textBlock(_ text: String, box: CGRect, width: Double, height: Double) -> [String: Any] {
        let rect = pixelRect(box, width: width, height: height)
        return ["text": text, "x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }

    static func recognizeBlocks(png: Data) async throws -> [[String: Any]] {
        let image = try decodeImage(png: png)
        let observations = try await paragraphRequest().perform(on: image)
        return paragraphBlocks(
            observations.flatMap { $0.document.paragraphs },
            width: Double(image.width),
            height: Double(image.height)
        )
    }
}
