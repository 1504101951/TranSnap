import AppKit
import CoreGraphics
import Darwin
import NaturalLanguage
import OSLog
import ScreenCaptureKit
import UniformTypeIdentifiers

enum DockPresence {
    private static var holders = Set<ObjectIdentifier>()

    static func enter(_ holder: AnyObject) {
        holders.insert(ObjectIdentifier(holder))
        apply()
    }

    static func leave(_ holder: AnyObject) {
        holders.remove(ObjectIdentifier(holder))
        apply()
    }

    private static func apply() {
        let policy: NSApplication.ActivationPolicy = holders.isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != policy { _ = NSApp.setActivationPolicy(policy) }
    }
}

enum CaptureStartupLog {
    private static let logger = Logger(subsystem: "TranSnap", category: "CaptureStartup")

    static func record(_ stage: String, since start: ContinuousClock.Instant) {
        let duration = start.duration(to: .now).components
        let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1_000_000_000_000_000
        logger.notice("stage=\(stage, privacy: .public) duration_ms=\(milliseconds, privacy: .public)")
    }
}

enum PerformanceLog {
    private static let logger = Logger(subsystem: "TranSnap", category: "Performance")

    static func record(_ stage: String, since start: ContinuousClock.Instant) {
        let duration = start.duration(to: .now).components
        note(stage, milliseconds: Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1_000_000_000_000_000)
    }

    static func note(_ stage: String, milliseconds: Double) {
        logger.notice("stage=\(stage, privacy: .public) duration_ms=\(milliseconds, privacy: .public)")
    }
}

enum LiveRegionLog {
    private static let logger = Logger(subsystem: "TranSnap", category: "LiveRegion")

    static func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

enum AppPreferences {
    static var current: [String: Any] {
        UserDefaults.standard.dictionary(forKey: AppConstants.preferencesKey) ?? [:]
    }
}

enum LanguageDetection {
    static func detect(_ text: String, preferred: [String]? = nil) -> String? {
        let preferred = preferred ?? {
            let preferences = AppPreferences.current
            return AppConstants.userLanguageKeys.compactMap { preferences[$0] as? String }
        }()
        let recognizer = NLLanguageRecognizer()
        recognizer.languageHints = hints(preferred: preferred)
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: AppConstants.languageDetectionCandidates)
            .map { (code: $0.key.rawValue, confidence: $0.value) }
        return resolve(hypotheses: hypotheses, text: text, preferred: preferred)
    }

    static func hints(preferred: [String]) -> [NLLanguage: Double] {
        var weights = Dictionary(uniqueKeysWithValues: AppConstants.languageDetectionAll.map {
            (NLLanguage(rawValue: $0), AppConstants.languageDetectionBaseWeight)
        })
        for code in AppConstants.languageDetectionPopular {
            weights[NLLanguage(rawValue: code)] = AppConstants.languageDetectionPopularWeight
        }
        for code in preferred {
            let identifier = chineseScript(code).map { "zh-\($0)" } ?? Locale.Language(identifier: code).languageCode?.identifier
            guard let identifier, AppConstants.languageDetectionAll.contains(identifier) else { continue }
            weights[NLLanguage(rawValue: identifier)] = AppConstants.languageDetectionUserWeight
        }
        return weights
    }

    static func resolve(hypotheses: [(code: String, confidence: Double)], text: String, preferred: [String]) -> String? {
        let bases = Set(preferred.compactMap { Locale.Language(identifier: $0).languageCode?.identifier })
        let ranked = hypotheses.sorted { $0.confidence > $1.confidence }
        guard let top = ranked.first else { return nil }
        let chosen = top.confidence >= AppConstants.languageDetectionConfidence
            ? top.code
            : ranked.first { Locale.Language(identifier: $0.code).languageCode.map { bases.contains($0.identifier) } == true }?.code
                ?? latinFallback(text: text, preferred: preferred)
        guard let chosen, Locale.Language(identifier: chosen).languageCode?.identifier == "zh" else { return chosen }
        guard let script = preferred.lazy.compactMap(chineseScript).first else { return chosen }
        let transform = StringTransform(script == "Hans" ? "Hant-Hans" : "Hans-Hant")
        return text.applyingTransform(transform, reverse: false) == text ? "zh-\(script)" : chosen
    }

    private static func latinFallback(text: String, preferred: [String]) -> String? {
        guard text.unicodeScalars.allSatisfy(\.isASCII), text.contains(where: \.isLetter) else { return nil }
        let latin = Set(preferred.compactMap { code -> String? in
            let language = Locale.Language(identifier: code)
            return language.maximalIdentifier.contains("Latn") ? language.languageCode?.identifier : nil
        })
        return latin.count == 1 ? latin.first : nil
    }

    private static func chineseScript(_ code: String) -> String? {
        let language = Locale.Language(identifier: code)
        guard language.languageCode?.identifier == "zh" else { return nil }
        return language.maximalIdentifier.contains("Hant") ? "Hant" : "Hans"
    }
}

enum PNGEncoding {
    static let failure = GIFExporter.ExportError(message: "无法编码图片。")

    static func data(_ image: CGImage, scale: CGFloat? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw failure
        }
        let properties = scale.map { scale -> CFDictionary in
            let dpi = 72.0 * Double(max(scale, 1))
            return [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw failure }
        return data as Data
    }
}

enum DisplayCapture {
    static func requireAuthorization() throws {
        guard ScreenCaptureService.isAuthorized() else { throw GIFExporter.ExportError(message: AppConstants.screenRecordingRequiredMessage) }
    }

    static func display(_ displayID: CGDirectDisplayID?, in content: SCShareableContent) throws -> SCDisplay {
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw GIFExporter.ExportError(message: "捕获目标已不可用，请重新选择。")
        }
        return display
    }

    @MainActor
    static func controlWindows() async throws -> [SCWindow] {
        let ids = Set(NSApp.windows
            .filter { $0.identifier == AppConstants.captureControlWindowIdentifier && $0.windowNumber > 0 }
            .map { CGWindowID($0.windowNumber) })
        let all = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let windows = all.windows.filter { ids.contains($0.windowID) }
        guard windows.count == ids.count else { throw GIFExporter.ExportError(message: "无法排除采集控制窗口，请重新开始。") }
        return windows
    }

    static func ownApplications(in content: SCShareableContent) throws -> [SCRunningApplication] {
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        guard !own.isEmpty else { throw GIFExporter.ExportError(message: "无法排除采集控制窗口，请重新开始。") }
        return own
    }

    static func crop(_ region: MediaCaptureService.Region, in filter: SCContentFilter) throws -> CGRect {
        guard abs(CGFloat(filter.pointPixelScale) - region.scale) < 0.01 else {
            throw GIFExporter.ExportError(message: "显示器缩放已改变，请重新框选。")
        }
        let crop = CGRect(x: region.rect.minX / region.scale, y: region.rect.minY / region.scale,
                          width: region.rect.width / region.scale, height: region.rect.height / region.scale)
        guard CGRect(origin: .zero, size: filter.contentRect.size).contains(crop) else {
            throw GIFExporter.ExportError(message: "选区超出当前显示器，请重新框选。")
        }
        return crop
    }

    static func requireMinimumSize(width: Int, height: Int) throws {
        guard width >= 32, height >= 64 else { throw GIFExporter.ExportError(message: "选区至少需要32×64像素。") }
    }
}

enum PNGPasteboard {
    static func write(_ png: Data, to pasteboard: NSPasteboard = .general) -> Bool {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

enum SyntheticEvent {
    static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: AppConstants.syntheticEventTag)
    }

    static func isMarked(_ event: NSEvent) -> Bool {
        event.cgEvent?.getIntegerValueField(.eventSourceUserData) == AppConstants.syntheticEventTag
    }
}

enum CaptureGeometry {
    private static var primaryScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
    }

    static func appKitRect(fromCGWindowBounds cgBounds: CGRect) -> NSRect {
        let top = primaryScreen?.frame.maxY ?? cgBounds.maxY
        return NSRect(
            x: cgBounds.origin.x,
            y: top - cgBounds.origin.y - cgBounds.height,
            width: cgBounds.width,
            height: cgBounds.height
        )
    }

    static func cgPoint(fromAppKitPoint point: NSPoint) -> CGPoint {
        return CGPoint(x: point.x, y: (primaryScreen?.frame.maxY ?? point.y) - point.y)
    }

    static func pixelCrop(
        window: NSRect,
        displayFrame: NSRect,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> NSRect? {
        let intersection = window.intersection(displayFrame)
        guard intersection.width >= 32, intersection.height >= 32 else { return nil }
        let scaleX = CGFloat(pixelWidth) / max(displayFrame.width, 1)
        let scaleY = CGFloat(pixelHeight) / max(displayFrame.height, 1)
        return NSRect(
            x: (intersection.minX - displayFrame.minX) * scaleX,
            y: (displayFrame.maxY - intersection.maxY) * scaleY,
            width: intersection.width * scaleX,
            height: intersection.height * scaleY
        )
    }

    static func frontmostWindowPixelCrop(displayFrame: NSRect, pixelWidth: Int, pixelHeight: Int) -> NSRect? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let myPid = getpid()
        for window in info {
            let pid = window[kCGWindowOwnerPID as String] as? pid_t ?? 0
            if pid == myPid { continue }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            if layer != 0 { continue }
            let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
            if alpha < 0.05 { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat else { continue }
            let appKit = appKitRect(fromCGWindowBounds: CGRect(x: x, y: y, width: width, height: height))
            if let crop = pixelCrop(
                window: appKit,
                displayFrame: displayFrame,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            ) {
                return crop
            }
        }
        return nil
    }
}

enum StickerImage {
    struct Unreadable: LocalizedError {
        var errorDescription: String? { "无法读取这张图片，请换一张 png、jpg、gif、heic 或 webp 图片。" }
    }

    static func normalized(url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Unreadable() }
        return try downscaled(image, maxPixels: AppConstants.stickerMaxPixels)
    }

    static func downscaled(_ image: CGImage, maxPixels: Int) throws -> CGImage {
        let long = max(image.width, image.height)
        guard long > maxPixels else { return image }
        let scale = Double(maxPixels) / Double(long)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw Unreadable() }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw Unreadable() }
        return scaled
    }
}
