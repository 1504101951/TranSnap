import Cocoa
import CoreGraphics
import FlutterMacOS
import ImageIO
import UniformTypeIdentifiers

final class ScreenshotWindowController: NSObject, NSWindowDelegate {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        super.init()
    }
    private var engine: FlutterEngine?
    private var window: NSWindow?
    private var channel: FlutterMethodChannel?
    private var pendingStartup: WindowEngine.Startup?
    private var pendingCompact = false
    private var showRequested = false
    private var textInputActive = false
    private var hasNativeCursor = false
    private var capturing = false
    private var captureTask: Task<Void, Never>?
    private var sourceApplicationID: String?
    private var captureSources: [[String: Any]] = []
    private var targetPreviews: [NSWindow] = []
    private var previewSource: (kind: String, applicationID: String?)?

    private func clearTargetPreviews() {
        targetPreviews.forEach { $0.close() }
        targetPreviews.removeAll()
    }

    private func previewTarget(kind: String, applicationID: String?) {
        clearTargetPreviews()
        previewSource = (kind, applicationID)
        guard kind == CaptureTarget.application.rawValue else { return }
        let source = captureSources.first { $0["applicationID"] as? String == applicationID }
        let rects = (source?["windows"] as? [[String: CGFloat]])?.map {
            CGRect(x: $0["x"]!, y: $0["y"]!, width: $0["width"]!, height: $0["height"]!)
        }
        for screen in NSScreen.screens {
            let id = screen.displayID!
            guard id != selectedDisplayID else { continue }
            let panel = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.identifier = AppConstants.captureControlWindowIdentifier
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let shade = CaptureShadeView(frame: NSRect(origin: .zero, size: screen.frame.size))
            shade.selection = shade.bounds
            let display = CGDisplayBounds(id)
            shade.contentRects = rects?.compactMap { rect in
                let clipped = rect.intersection(display)
                guard !clipped.isNull else { return nil }
                return CGRect(x: clipped.minX - display.minX, y: display.maxY - clipped.maxY,
                              width: clipped.width, height: clipped.height)
            }
            panel.contentView = shade
            targetPreviews.append(panel)
            panel.orderFrontRegardless()
        }
    }

    private var selectedDisplayID: CGDirectDisplayID = 0
    private var selectedScale: CGFloat = 1
    private var lastLoggedTranslationStatus: String?
    private var image: CGImage?
    private var captureId: String? {
        didSet {
            guard let oldValue, oldValue != captureId else { return }
            MacPlatformBridge.Shared.instance?.requestApplication(
                AppConstants.cancelScreenshotTranslationMethod, arguments: ["id": oldValue]
            ) { _ in }
        }
    }
    private static let staleCaptureFailure = FlutterError(
        code: AppConstants.staleCaptureError, message: "截图已关闭或被替换，请重新截图。", details: nil)
    private var capturedAt: Int64 = 0
    private var pixels = NSSize.zero
    private var displayFrame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    private var initialCrop: NSRect?
    private var initialCropSelected = false
    private var message: String?
    private let freezeView = NSImageView()
    private var displaysFrozenScreen = true
    private var localKeys: Any?
    private var globalKeyTap: CFMachPort?
    private var globalKeySource: CFRunLoopSource?
    let pins = PinOverlayController()
    var onCapturingChanged: ((Bool) -> Void)?
    var onFrozenEditorVisibleChanged: ((Bool) -> Void)?
    var onPrepareCapture: (@MainActor ([String: Any], Bool, MediaCaptureService.Region?) async throws -> Void)?
    var onPreviewLiveRegion: (@MainActor (NSScreen?) -> Void)?
    var onCancelLivePreview: (@MainActor () -> Void)?
    var onPrepareCaptureControls: (@MainActor () -> Void)?
    var onCaptureSources: (@MainActor (String?) async throws -> [[String: Any]])?

    var liveCaptureID: String? { !capturing && displaysFrozenScreen && image != nil ? captureId : nil }

    func openImage() {
        guard !capturing, window?.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "打开图片进行标注、识别或翻译"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadImage { try Data(contentsOf: url) }
    }

    func openClipboardImage() {
        guard !capturing, window?.attachedSheet == nil else { return }
        guard let source = (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first,
              let data = source.tiffRepresentation else {
            let alert = NativeGlassFactory.applyAppearance(to: NSAlert())
            alert.alertStyle = .informational
            alert.messageText = "剪贴板中没有可读取的图片"
            alert.informativeText = "请先复制图片，再从剪贴板打开。"
            NSApp.activate()
            AppFonts.prepare(alert).runModal()
            return
        }
        loadImage { data }
    }

    private func loadImage(_ read: @escaping @Sendable () throws -> Data) {
        MainActor.assumeIsolated { MacPlatformBridge.Shared.instance?.capture.cancelCountdown() }
        cancelCapture()
        window?.orderOut(nil)
        displaysFrozenScreen = false
        selectedDisplayID = 0
        selectedScale = NSScreen.main?.backingScaleFactor ?? 1
        displayFrame = NSScreen.main?.visibleFrame ?? displayFrame
        capturing = true
        onCapturingChanged?(true)
        captureTask = Task { @MainActor in
            defer {
                self.capturing = false
                self.captureTask = nil
                self.onCapturingChanged?(false)
            }
            let decoding = Task.detached { try Self.decodeImage(read()) }
            do {
                let decoded = try await withTaskCancellationHandler {
                    try await decoding.value
                } onCancel: { decoding.cancel() }
                try Task.checkCancellation()
                self.image = decoded
                self.pixels = NSSize(width: decoded.width, height: decoded.height)
                self.captureId = UUID().uuidString
                self.capturedAt = Int64(Date().timeIntervalSince1970 * 1000)
                self.initialCrop = NSRect(origin: .zero, size: self.pixels)
                self.initialCropSelected = true
                self.show(compact: false)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.message = error.localizedDescription
                self.show(compact: true)
            }
        }
    }

    static func decodeImage(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary),
              let context = CGContext(data: nil, width: decoded.width, height: decoded.height,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                              userInfo: [NSLocalizedDescriptionKey: "无法解码图片，请选择系统支持的图片文件。"]) }
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        try Task.checkCancellation()
        guard let image = context.makeImage() else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建图片像素。"])
        }
        return image
    }

    func closeForCapture() {
        if let window { window.close() }
        else {
            cancelCapture()
        }
    }

    func hideForCapture() {
        clearTargetPreviews()
        window?.orderOut(nil)
        onFrozenEditorVisibleChanged?(false)
    }

    func restoreAfterCapturePreparation() {
        guard liveCaptureID != nil else { return }
        if let source = previewSource { previewTarget(kind: source.kind, applicationID: source.applicationID) }
        onFrozenEditorVisibleChanged?(true)
        window?.makeKeyAndOrderFront(nil)
    }

    func capture(_ target: ScreenshotTarget = .pointerDisplay) {
        MainActor.assumeIsolated { MacPlatformBridge.Shared.instance?.capture.cancelCountdown() }
        guard !capturing, window?.attachedSheet == nil else { return }
        captureId = nil
        displaysFrozenScreen = true
        capturing = true
        clearTargetPreviews()
        captureSources.removeAll()
        previewSource = nil
        sourceApplicationID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        onCapturingChanged?(true)
        if window?.isVisible == true {
            window?.orderOut(nil)
        }
        let captureStart = ContinuousClock.now
        captureTask = Task { @MainActor in
            defer {
                self.capturing = false
                self.captureTask = nil
                self.onCapturingChanged?(false)
            }
            let granted = await ScreenCaptureService.requestAccess()
            guard !Task.isCancelled else { return }
            guard granted else {
                self.image = nil
                self.captureId = nil
                self.initialCrop = nil
                self.message = AppConstants.screenRecordingRequiredMessage
                ScreenCaptureService.openScreenRecordingSettings()
                self.show(compact: true)
                return
            }
            do {
                let showsCursor = AppPreferences.current[
                    AppConstants.screenshotIncludesCursorKey
                ] as? Bool == true
                let frame = try await ScreenCaptureService.captureActiveDisplay(displayID: target.displayID, showsCursor: showsCursor)
                try Task.checkCancellation()
                let selection = target.selection(in: frame)
                self.selectedDisplayID = frame.displayID
                self.selectedScale = frame.scale
                self.image = frame.image
                self.captureId = UUID().uuidString
                self.capturedAt = Int64(Date().timeIntervalSince1970 * 1000)
                self.pixels = NSSize(width: frame.pixelWidth, height: frame.pixelHeight)
                self.displayFrame = frame.displayFrame
                self.initialCrop = selection.crop
                self.initialCropSelected = selection.selected
                self.message = nil
                let showStart = ContinuousClock.now
                self.show(compact: false)
                PerformanceLog.record("screenshot-show-sync", since: showStart)
                PerformanceLog.record("screenshot-to-show", since: captureStart)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.image = nil
                self.captureId = nil
                self.initialCrop = nil
                self.message = error.localizedDescription
                self.show(compact: true)
            }
        }
    }

    func cancelCapture() {
        pendingStartup?.cancel()
        pendingStartup = nil
        pendingCompact = false
        showRequested = false
        captureTask?.cancel()
        previewSource = nil
        clearTargetPreviews()
        captureSources.removeAll()
        if hasNativeCursor { NSCursor.arrow.set(); hasNativeCursor = false }
        removeScreenshotKeys()
        textInputActive = false
        image = nil
        captureId = nil
        message = nil
        initialCrop = nil
        freezeView.image = nil
        onFrozenEditorVisibleChanged?(false)
        channel?.invokeMethod(AppConstants.screenshotChangedMethod, arguments: snapshot())
    }

    func publishTranslation(_ state: [String: Any]) {
        guard let id = state["id"] as? String, id == captureId else { return }
        let status = state["status"] as? String ?? ""
        let key = "\(id)\n\(status)"
        if key != lastLoggedTranslationStatus {
            lastLoggedTranslationStatus = key
            let overlays = (state["overlays"] as? [Any])?.count ?? 0
            LiveRegionLog.note("screenshot status=\(status) phase=\(state["phase"] ?? "") overlays=\(overlays)")
        }
        for item in state["metrics"] as? [[String: Any]] ?? [] {
            let fields = ["blocks", "chars", "waitMs", "firstMs", "totalMs", "inflight", "outcome"]
                .map { "\($0)=\(item[$0] ?? "")" }
                .joined(separator: " ")
            LiveRegionLog.note("screenshot batch \(fields)")
        }
        channel?.invokeMethod(AppConstants.publishScreenshotTranslationMethod, arguments: state)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    func shutdown() {
        cancelCapture()
        if let window { DockPresence.leave(window) }
        window?.delegate = nil
        window?.close()
        window = nil
        channel?.setMethodCallHandler(nil)
        engine?.shutDownEngine()
        engine = nil
        channel = nil
        pins.closeAll()
    }

    func isCurrentCapture(_ id: String) -> Bool {
        captureId == id
    }

    private func recordHistory(id: String, payload: Data) {
        let arguments: [String: Any] = [
            "id": id, "bytes": FlutterStandardTypedData(bytes: payload), "capturedAt": capturedAt,
        ]
        MacPlatformBridge.Shared.instance?.requestApplication(AppConstants.screenshotHistoryRecordingMethod) { enabled in
            guard enabled as? Bool == true else { return }
            MacPlatformBridge.Shared.instance?.requestApplication(
                AppConstants.recordScreenshotHistoryMethod, arguments: arguments
            ) { _ in }
        }
    }

    private func snapshot() -> [String: Any] {
        var value: [String: Any] = [
            "canCaptureMedia": displaysFrozenScreen && image != nil,

            "directory": UserDefaults.standard.string(forKey: AppConstants.screenshotSaveDirectoryKey) ?? "",
            "screenAccess": ScreenCaptureService.isAuthorized(),
            "capturedAt": capturedAt,
            "width": pixels.width,
            "height": pixels.height,
            "captureDisplayX": CGDisplayBounds(selectedDisplayID).minX,
            "captureDisplayY": CGDisplayBounds(selectedDisplayID).minY,
            "displayX": displayFrame.origin.x,
            "displayY": displayFrame.origin.y,
            "displayWidth": displayFrame.width,
            "displayHeight": displayFrame.height,
        ]
        if let screen = NSScreen.screens.first(where: { $0.displayID == selectedDisplayID }), displaysFrozenScreen {
            value["toolbarSafeX"] = screen.visibleFrame.minX - displayFrame.minX
            value["toolbarSafeY"] = displayFrame.maxY - screen.visibleFrame.maxY
            value["toolbarSafeWidth"] = screen.visibleFrame.width
            value["toolbarSafeHeight"] = screen.visibleFrame.height
        }
        if !displaysFrozenScreen { value["imageScale"] = selectedScale }
        if let image, let captureId {
            value["id"] = captureId
            value["pixels"] = FlutterStandardTypedData(bytes: image.dataProvider!.data! as Data)
            value["rowBytes"] = image.bytesPerRow
        }
        if let initialCrop {
            value["cropX"] = initialCrop.origin.x
            value["cropY"] = initialCrop.origin.y
            value["cropWidth"] = initialCrop.width
            value["cropHeight"] = initialCrop.height
            value["cropSelected"] = initialCropSelected
        }
        if let message { value["error"] = message }
        value.merge(toolbarPreferences()) { _, current in current }
        return value
    }

    private func toolbarPreferences() -> [String: Any] {
        let preferences = AppPreferences.current
        return preferences.filter { [AppConstants.screenshotToolbarColumnsKey, AppConstants.screenshotToolbarChildrenKey, AppConstants.screenshotToolbarHiddenKey, AppConstants.screenshotToolbarFavoritesKey, AppConstants.screenshotDrawingKey, AppConstants.screenshotConfirmActionKey, AppConstants.recordingDelayKey, AppConstants.recordingClickEffectEnabledKey, AppConstants.stickersKey].contains($0.key) }
            .merging([AppConstants.stickerDirectoryKey: AppConstants.stickersURL.path]) { current, _ in current }
    }

    func toolbarPreferencesChanged() {
        channel?.invokeMethod(AppConstants.screenshotToolbarChangedMethod, arguments: toolbarPreferences())
    }

    func seedCaptureForTesting(image: CGImage, id: String, width: CGFloat = 1, height: CGFloat = 1, showEditor: Bool = false) {
        self.displaysFrozenScreen = true
        self.image = image
        self.captureId = id
        self.pixels = NSSize(width: width, height: height)
        self.capturedAt = Int64(Date().timeIntervalSince1970 * 1000)
        self.message = nil
        if showEditor { show(compact: false) }
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case AppConstants.previewCaptureTargetMethod:
            guard let id = args["id"] as? String, id == liveCaptureID,
                  let kind = args["kind"] as? String,
                  CaptureTarget(rawValue: kind) != nil else {
                result(FlutterError(code: AppConstants.badArgsError, message: "录制预览已失效。", details: nil))
                return
            }
            previewTarget(kind: kind, applicationID: args["applicationID"] as? String)
            Task { @MainActor in
                guard id == self.liveCaptureID else {
                    result(FlutterError(code: AppConstants.badArgsError, message: "录制预览已失效。", details: nil))
                    return
                }
                self.onPrepareCaptureControls?()
                result(nil)
            }
        case AppConstants.captureSourcesMethod:
            guard let id = args["id"] as? String, id == liveCaptureID,
                  let sources = onCaptureSources else {
                result(FlutterError(code: AppConstants.badArgsError, message: "请在当前屏幕截图中选择录制应用。", details: nil))
                return
            }
            Task { @MainActor in
                do {
                    let values = try await sources(sourceApplicationID)
                    guard id == self.liveCaptureID else { throw CancellationError() }
                    self.captureSources = values
                    result(values)
                } catch {
                    result(FlutterError(code: AppConstants.captureFailedError, message: error.localizedDescription, details: nil))
                }
            }
        case AppConstants.previewLiveRegionMethod:
            guard let id = args["id"] as? String, id == liveCaptureID else {
                result(FlutterError(code: AppConstants.badArgsError, message: "请在当前屏幕截图中开始实时翻译。", details: nil))
                return
            }
            let screen = window?.screen
            Task { @MainActor in self.onPreviewLiveRegion?(screen) }
            result(nil)
        case AppConstants.cancelLivePreviewMethod:
            Task { @MainActor in self.onCancelLivePreview?() }
            result(nil)
        case AppConstants.prepareCaptureMethod:
            guard !capturing, let id = args["id"] as? String, id == liveCaptureID,
                  let kind = args["kind"] as? String, [CaptureTarget.region.rawValue, CaptureTarget.display.rawValue, CaptureTarget.application.rawValue].contains(kind),
                  let scrolling = args["scrolling"] as? Bool, !scrolling || kind == CaptureTarget.region.rawValue,
                  scrolling || args["live"] as? Bool == true || AppConstants.recordingDelays.contains(args["delay"] as? Int ?? -1),
                  let prepare = onPrepareCapture else {
                result(FlutterError(code: AppConstants.badArgsError, message: "请在当前屏幕截图中选择采集工具。", details: nil))
                return
            }
            Task { @MainActor in
                guard id == self.liveCaptureID else {
                    result(FlutterError(code: AppConstants.badArgsError, message: "截图已变化，请重新选择采集工具。", details: nil))
                    return
                }
                do {
                    var source = args
                    source["sourceID"] = selectedDisplayID
                    try await prepare(source, scrolling, kind == CaptureTarget.region.rawValue ? captureRegion(args) : nil)
                    result(nil)
                } catch {
                    result(FlutterError(code: AppConstants.captureFailedError, message: error.localizedDescription, details: nil))
                }
            }
        case AppConstants.setResizeCursorMethod:
            let position: NSCursor.FrameResizePosition
            switch args["direction"] as? String {
            case AppConstants.resizeNorthWestSouthEast: position = .topLeft
            case AppConstants.resizeNorthEastSouthWest: position = .topRight
            default:
                result(FlutterError(code: AppConstants.badArgsError, message: "无效的拉伸光标方向。", details: nil))
                return
            }
            guard window?.isVisible == true else { result(nil); return }
            NSCursor.frameResize(position: position, directions: .all).set()
            hasNativeCursor = true
            result(nil)
        case AppConstants.setBrushCursorMethod:
            guard let diameter = args["diameter"] as? Double, diameter > 0 else {
                result(FlutterError(code: AppConstants.badArgsError, message: "无效的画笔光标直径。", details: nil))
                return
            }
            guard window?.isVisible == true else { result(nil); return }
            Self.brushCursor(diameter: CGFloat(diameter), argb: (args["color"] as? NSNumber)?.uint32Value).set()
            hasNativeCursor = true
            result(nil)
        case AppConstants.perfMarkMethod:
            PerformanceLog.note(args["stage"] as! String, milliseconds: (args["ms"] as! NSNumber).doubleValue)
            result(nil)
        case AppConstants.openStickerSettingsMethod:
            closeForCapture()
            MainActor.assumeIsolated { StatusBarController.shared.showSettings?() }
            result(nil)
        case AppConstants.saveDrawingPreferencesMethod:
            MacPlatformBridge.Shared.instance?.routeWindowRequest(call, result: result)
        case AppConstants.saveRecordingOptionsMethod:
            MacPlatformBridge.Shared.instance?.routeWindowRequest(call) { value in
                if !(value is FlutterError) { MainActor.assumeIsolated { StatusBarController.shared.refreshSettings?() } }
                result(value)
            }
        case AppConstants.getScreenshotMethod:
            result(snapshot())
        case AppConstants.recognizeBlocksMethod:
            guard let id = args["id"] as? String, id == captureId else {
                result(Self.staleCaptureFailure)
                return
            }
            guard let payload = (args["bytes"] as? FlutterStandardTypedData)?.data else {
                result(FlutterError(code: AppConstants.badArgsError, message: "缺少识别图片。", details: nil))
                return
            }
            Task { @MainActor in
                let started = ContinuousClock.now
                do {
                    let blocks = try await Task.detached { try await ScreenCaptureService.recognizeBlocks(png: payload) }.value
                    LiveRegionLog.note("screenshot ocr ms=\(Self.milliseconds(since: started)) paragraphs=\(blocks.count)")
                    guard id == self.captureId else {
                        result(Self.staleCaptureFailure)
                        return
                    }
                    result(blocks.map(\.channelValue))
                } catch {
                    LiveRegionLog.note("screenshot ocr ms=\(Self.milliseconds(since: started)) failed")
                    result(FlutterError(code: AppConstants.ocrFailedError, message: error.localizedDescription, details: nil))
                }
            }
        case AppConstants.recognizeTextMethod:
            guard let id = args["id"] as? String, id == captureId else {
                result(Self.staleCaptureFailure)
                return
            }
            guard let payload = (args["bytes"] as? FlutterStandardTypedData)?.data else {
                result(FlutterError(code: AppConstants.badArgsError, message: "缺少识别图片。", details: nil))
                return
            }
            Task { @MainActor in
                do {
                    let image = try await Task.detached { try ScreenCaptureService.decodeImage(png: payload) }.value
                    async let text = ScreenCaptureService.recognizeText(image: image)
                    async let codes = ScreenCaptureService.detectCodes(image: image)
                    result(["text": try await text, "codes": try await codes])
                } catch {
                    result(FlutterError(code: AppConstants.ocrFailedError, message: error.localizedDescription, details: nil))
                }
            }
        case AppConstants.openLinkMethod:
            guard let id = args["id"] as? String, id == captureId else {
                result(Self.staleCaptureFailure)
                return
            }
            guard let raw = args["url"] as? String, let url = ScreenshotLink.url(from: raw) else {
                result(FlutterError(code: AppConstants.badArgsError, message: "只能打开 http 或 https 链接。", details: nil))
                return
            }
            result(NSWorkspace.shared.open(url))
        case AppConstants.copyTextMethod:
            guard let text = args["text"] as? String, !text.isEmpty else {
                result(FlutterError(code: AppConstants.ocrEmptyError, message: "没有可复制的文字。", details: nil))
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            result(nil)
        case AppConstants.prewarmTranslationMethod:
            MacPlatformBridge.Shared.instance?.requestApplication(
                AppConstants.prewarmTranslationMethod, arguments: nil, result: result
            )
        case AppConstants.translateScreenshotBlocksMethod:
            guard let id = args["id"] as? String, id == captureId else {
                result(Self.staleCaptureFailure); return
            }
            guard let blocks = args["blocks"] as? [[String: Any]] else {
                result(FlutterError(code: AppConstants.badArgsError, message: "缺少识别段落。", details: nil))
                return
            }
            LiveRegionLog.note("screenshot translate start paragraphs=\(blocks.count)")
            let started = ContinuousClock.now
            MacPlatformBridge.Shared.instance?.requestApplication(
                AppConstants.translateScreenshotBlocksMethod,
                arguments: ["id": id, "blocks": blocks]
            ) { reply in
                let outcome = reply is FlutterError ? "failed" : "accepted"
                LiveRegionLog.note("screenshot translate \(outcome) ms=\(Self.milliseconds(since: started))")
                result(reply)
            }
        case AppConstants.closeScreenshotMethod:
            closeForCapture(); result(nil)
        case AppConstants.requestScreenAccessMethod:
            Task { @MainActor in
                let granted = await ScreenCaptureService.requestAccess()
                if !granted {
                    ScreenCaptureService.openScreenRecordingSettings()
                }
                result(self.snapshot())
            }
        case AppConstants.copyScreenshotMethod, AppConstants.saveScreenshotMethod, AppConstants.pinScreenshotMethod:
            guard let id = args["id"] as? String, id == captureId else {
                result(Self.staleCaptureFailure)
                return
            }
            guard let typed = args["bytes"] as? FlutterStandardTypedData else {
                result(Self.staleCaptureFailure)
                return
            }
            let payload = typed.data
            let exportStart = ContinuousClock.now
            switch call.method {
            case AppConstants.copyScreenshotMethod:
                defer { PerformanceLog.record("export-copy", since: exportStart) }
                guard PNGPasteboard.write(payload, to: pasteboard) else {
                    result(FlutterError(code: AppConstants.copyFailedError, message: "无法复制截图，请重试。", details: nil))
                    return
                }
                recordHistory(id: id, payload: payload)
                result(nil)
            case AppConstants.saveScreenshotMethod:
                let name = args["name"] as? String ?? "screenshot.png"
                let basePath = UserDefaults.standard.string(forKey: AppConstants.screenshotSaveDirectoryKey)
                let copies = args["copy"] as? Bool == true
                Task { @MainActor in
                    defer { PerformanceLog.record("export-save", since: exportStart) }
                    do {
                        let url = try await Task.detached {
                            let directory = try ScreenshotStorage.datedDirectory(basePath: basePath, category: .screenshot)
                            return try ScreenshotStorage.save(payload, directory: directory, name: name)
                        }.value
                        guard id == self.captureId else { result(url.path); return }
                        if copies, !PNGPasteboard.write(payload, to: self.pasteboard) {
                            result(FlutterError(code: AppConstants.copyFailedError, message: "无法复制截图，请重试。", details: nil))
                            return
                        }
                        self.recordHistory(id: id, payload: payload)
                        result(url.path)
                    } catch {
                        result(FlutterError(code: AppConstants.saveFailedError, message: error.localizedDescription, details: nil))
                    }
                }
            case AppConstants.pinScreenshotMethod:
                guard let x = args["x"] as? NSNumber, let y = args["y"] as? NSNumber else {
                    result(FlutterError(code: AppConstants.badArgsError, message: "贴图缺少选区坐标。", details: nil))
                    return
                }
                guard let pinId = pins.pin(
                    png: payload,
                    origin: NSPoint(x: x.doubleValue, y: y.doubleValue)
                ) else {
                    result(FlutterError(code: AppConstants.saveFailedError, message: "无法解码贴图内容，请重试。", details: nil))
                    return
                }
                window?.orderOut(nil)
                recordHistory(id: id, payload: payload)
                result(pinId)
            default:
                result(FlutterMethodNotImplemented)
            }
        case AppConstants.screenshotTextInputMethod:
            guard let active = args["active"] as? Bool else {
                result(FlutterError(code: AppConstants.badArgsError, message: "缺少文字编辑状态。", details: nil))
                return
            }
            if let id = args["id"] as? String, id == captureId {
                textInputActive = active
            }
            result(nil)
        case AppConstants.revealFileMethod:
            guard let path = args["path"] as? String else {
                result(FlutterError(code: AppConstants.badArgsError, message: "缺少文件路径。", details: nil))
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func show(compact: Bool) {
        pendingCompact = compact
        let overlay = compact || displaysFrozenScreen
        if engine == nil {
            showRequested = true
            guard pendingStartup == nil else { return }
            startEngine()
            return
        }
        if let old = window, old.styleMask.contains(.nonactivatingPanel) != overlay {
            let content = old.contentViewController!
            old.contentViewController = nil
            old.delegate = nil
            DockPresence.leave(old)
            old.close()
            window = makeWindow(content: content, overlay: overlay)
        }
        let frame = compact
            ? NSRect(x: displayFrame.midX - 220, y: displayFrame.midY - 90, width: 440, height: 180)
            : overlay ? displayFrame : Self.imageResultFrame(pixels: pixels, scale: selectedScale, visible: displayFrame)
        if let window {
            if !overlay {
                window.title = pixels.width > 0 && pixels.height > 0
                    ? "图片 · \(Int(pixels.width)) × \(Int(pixels.height))" : "图片"
                window.contentMinSize = AppConstants.longScreenshotResultMinimumSize
            }
            NativeGlassFactory.applyAppearance(to: window)
            window.setFrame(frame, display: true)
        }
        installFreezeImage(compact: compact)
        window?.displayIfNeeded()
        channel?.invokeMethod(AppConstants.screenshotChangedMethod, arguments: snapshot())
        onFrozenEditorVisibleChanged?(displaysFrozenScreen && !compact)
        if overlay {
            if NSApp.isHidden { NSApp.unhideWithoutActivation() }
            window?.orderFrontRegardless()
            window?.makeKey()
        } else if let window {
            WindowEngine.present(window)
        }
        installScreenshotKeys()
    }

    func prewarm() {
        guard engine == nil, pendingStartup == nil else { return }
        startEngine()
    }

    private func startEngine() {
        pendingStartup = WindowEngine.start(
            name: AppConstants.screenshotEngineName, entrypoint: AppConstants.screenshotEntrypoint,
            channel: AppConstants.screenshotChannel,
            handler: { [weak self] call, result in self?.handle(call, result: result) },
            completion: { [weak self] started in
                guard let self else { return }
                self.pendingStartup = nil
                guard let started else {
                    self.cancelCapture()
                    WindowEngine.reportStartFailure("截图预览")
                    return
                }
                self.engine = started.engine
                self.channel = started.channel
                let flutter = started.flutter
                flutter.view.wantsLayer = true
                flutter.view.layer?.isOpaque = false
                flutter.view.layer?.backgroundColor = CGColor.clear
                self.window = self.makeWindow(
                    content: flutter,
                    overlay: self.showRequested ? self.pendingCompact || self.displaysFrozenScreen : true)
                self.freezeView.imageScaling = .scaleAxesIndependently
                self.freezeView.wantsLayer = true
                guard self.showRequested, !self.capturing else { return }
                self.showRequested = false
                self.show(compact: self.pendingCompact)
            })
    }

    private func makeWindow(content: NSViewController, overlay: Bool) -> ScreenshotPanel {
        let style: NSWindow.StyleMask = overlay
            ? [.borderless, .fullSizeContentView, .nonactivatingPanel] : AppConstants.captureResultWindowStyle
        let panel = ScreenshotPanel(contentRect: displayFrame, styleMask: style, backing: .buffered, defer: false)
        panel.identifier = AppConstants.captureControlWindowIdentifier
        panel.onEscape = { [weak self] in
            self?.channel?.invokeMethod(AppConstants.escapePressedMethod, arguments: nil)
        }
        panel.onUndo = { [weak self] in self?.channel?.invokeMethod(AppConstants.undoPressedMethod, arguments: nil) }
        panel.onRedo = { [weak self] in self?.channel?.invokeMethod(AppConstants.redoPressedMethod, arguments: nil) }
        panel.title = overlay ? "" : (pixels.width > 0 && pixels.height > 0
            ? "图片 · \(Int(pixels.width)) × \(Int(pixels.height))" : "图片")
        panel.isFloatingPanel = overlay
        panel.level = overlay ? .statusBar : .normal
        panel.collectionBehavior = overlay ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.isOpaque = !overlay
        if overlay {
            panel.backgroundColor = .clear
        } else {
            panel.backgroundColor = NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let value: CGFloat = dark ? 28.0 / 255.0 : 233.0 / 255.0
                return NSColor(srgbRed: value, green: value, blue: value, alpha: 1)
            }
        }
        panel.hasShadow = !overlay
        if !overlay { panel.contentMinSize = AppConstants.longScreenshotResultMinimumSize }
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentViewController = content
        NativeGlassFactory.applyAppearance(to: panel)
        return panel
    }

    static func imageResultFrame(pixels: NSSize, scale: CGFloat, visible: NSRect) -> NSRect {
        let style = AppConstants.captureResultWindowStyle
        let available = NSWindow.contentRect(forFrameRect: visible, styleMask: style)
        let reservedWidth = AppConstants.resultWindowCanvasPadding * 2
        let reservedHeight = AppConstants.resultWindowCanvasPadding * 2 + AppConstants.resultWindowBarHeight
        let minSize = AppConstants.longScreenshotResultMinimumSize
        let size = NSSize(width: min(available.width, max(minSize.width, pixels.width / scale + reservedWidth)),
                          height: min(available.height, max(minSize.height, pixels.height / scale + reservedHeight)))
        let frame = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: size), styleMask: style)
        return NSRect(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2,
                      width: frame.width, height: frame.height)
    }

    private func installFreezeImage(compact: Bool) {
        guard let host = window?.contentView else { return }
        freezeView.frame = host.bounds
        freezeView.autoresizingMask = [.width, .height]
        if freezeView.superview !== host {
            host.addSubview(freezeView, positioned: .below, relativeTo: nil)
        }
        guard !compact, displaysFrozenScreen, let image else {
            freezeView.image = nil
            freezeView.isHidden = true
            return
        }
        freezeView.isHidden = false
        freezeView.image = NSImage(cgImage: image, size: displayFrame.size)
    }

    private func captureRegion(_ args: [String: Any]) throws -> MediaCaptureService.Region {
        guard let x = args["x"] as? Double, let y = args["y"] as? Double,
              let width = args["width"] as? Double, let height = args["height"] as? Double,
              [x, y, width, height].allSatisfy({ $0.isFinite }), x >= 0, y >= 0,
              width >= 32, height >= 64, x + width <= pixels.width, y + height <= pixels.height else {
            throw GIFExporter.ExportError(message: "请在单个显示器内选择至少32×64像素的区域。")
        }
        return MediaCaptureService.Region(displayID: selectedDisplayID,
            rect: CGRect(x: x, y: y, width: width, height: height), scale: selectedScale,
            edges: .init(top: 0, bottom: 0, automatic: true))
    }

    static func brushCursor(diameter: CGFloat, argb: UInt32?) -> NSCursor {
        let border: CGFloat = argb == nil ? 2 : 1
        let side = diameter + border * 2
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let circle = NSRect(x: border, y: border, width: diameter, height: diameter)
            if let argb {
                NSColor(srgbRed: CGFloat((argb >> 16) & 0xFF) / 255, green: CGFloat((argb >> 8) & 0xFF) / 255,
                        blue: CGFloat(argb & 0xFF) / 255, alpha: 1).setFill()
                NSBezierPath(ovalIn: circle).fill()
            } else {
                let outer = NSBezierPath(ovalIn: circle.insetBy(dx: -1.5, dy: -1.5))
                outer.lineWidth = 1
                NSColor.black.setStroke()
                outer.stroke()
            }
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: -0.5, dy: -0.5))
            ring.lineWidth = 1
            NSColor.white.setStroke()
            ring.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }

    func routeScreenshotKey(_ event: NSEvent) -> Bool {
        guard window?.isVisible == true, window?.attachedSheet == nil,
              displaysFrozenScreen || window?.isKeyWindow == true else { return false }
        if textInputActive && event.keyCode != AppConstants.escapeKeyCode { return false }
        if [AppConstants.returnKeyCode, AppConstants.keypadEnterKeyCode].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           let id = captureId {
            if let input = window?.firstResponder as? NSTextInputClient, input.hasMarkedText() {
                return false
            }
            if !event.isARepeat {
                channel?.invokeMethod(AppConstants.confirmScreenshotMethod, arguments: ["id": id])
            }
            return true
        }
        if event.keyCode == AppConstants.escapeKeyCode {
            (window as? ScreenshotPanel)?.onEscape?()
            return true
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) {
                (window as? ScreenshotPanel)?.onRedo?()
            } else {
                (window as? ScreenshotPanel)?.onUndo?()
            }
            return true
        }
        if let direction = AppConstants.arrowKeyDirections[event.keyCode],
           event.modifierFlags.intersection([.command, .control]).isEmpty,
           let id = captureId {
            channel?.invokeMethod(AppConstants.nudgeScreenshotCropMethod, arguments: [
                "id": id, "dx": direction.dx, "dy": direction.dy,
                "shift": event.modifierFlags.contains(.shift),
                "option": event.modifierFlags.contains(.option),
            ])
            return true
        }
        if AppConstants.deleteKeyCodes.contains(event.keyCode),
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let id = captureId {
            if !event.isARepeat {
                channel?.invokeMethod(AppConstants.deleteScreenshotSelectionMethod, arguments: ["id": id])
            }
            return true
        }
        if event.keyCode == AppConstants.tabKeyCode,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           let id = captureId {
            if !event.isARepeat {
                channel?.invokeMethod(AppConstants.screenshotToolbarTabMethod, arguments: ["id": id])
            }
            return true
        }
        guard let id = captureId,
              let slot = AppConstants.screenshotToolbarSlotKeyCodes.firstIndex(of: event.keyCode),
              !event.modifierFlags.contains(.shift) else {
            return false
        }
        let flags = event.modifierFlags
        let modifiers = (flags.contains(.control) ? 1 : 0)
            | (flags.contains(.option) ? 2 : 0)
            | (flags.contains(.command) ? 8 : 0)
        if !event.isARepeat {
            channel?.invokeMethod(
                AppConstants.screenshotToolbarSlotMethod,
                arguments: ["id": id, "modifiers": modifiers, "digit": slot + 1]
            )
        }
        return true
    }

    func filterScreenshotEvent(_ event: CGEvent) -> CGEvent? {
        guard let key = NSEvent(cgEvent: event) else { return event }
        return routeScreenshotKey(key) ? nil : event
    }

    private func installScreenshotKeys() {
        removeScreenshotKeys()
        localKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.routeScreenshotKey(event) == true { return nil }
            return event
        }
        guard displaysFrozenScreen else { return }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<ScreenshotWindowController>.fromOpaque(pointer).takeUnretainedValue()
                if type == .tapDisabledByTimeout {
                    if let tap = controller.globalKeyTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                guard let forwarded = controller.filterScreenshotEvent(event) else { return nil }
                return Unmanaged.passUnretained(forwarded)
            }, userInfo: pointer
        ) else {
            message = "无法启用截图跨应用按键，请检查辅助功能权限后重新截图。"
            channel?.invokeMethod(AppConstants.screenshotChangedMethod, arguments: snapshot())
            return
        }
        globalKeyTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
        globalKeySource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeScreenshotKeys() {
        if let localKeys { NSEvent.removeMonitor(localKeys) }
        if let globalKeyTap {
            CGEvent.tapEnable(tap: globalKeyTap, enable: false)
            CFMachPortInvalidate(globalKeyTap)
        }
        if let globalKeySource { CFRunLoopRemoveSource(CFRunLoopGetMain(), globalKeySource, .commonModes) }
        localKeys = nil
        globalKeyTap = nil
        globalKeySource = nil
    }

}

final class ScreenshotPanel: NSPanel {
    var onEscape: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == AppConstants.escapeKeyCode {
            onEscape?()
            return
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) {
                onRedo?()
            } else {
                onUndo?()
            }
            return
        }
        super.keyDown(with: event)
    }
}

extension ScreenshotWindowController {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { DockPresence.leave(window) }
        cancelCapture()
    }
}

enum ScreenshotLink {
    static func url(from raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              AppConstants.openableLinkSchemes.contains(scheme),
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

enum ScreenshotTarget {
    case pointerDisplay
    case display(CGDirectDisplayID)

    var displayID: CGDirectDisplayID? {
        switch self {
        case .pointerDisplay: nil
        case .display(let id): id
        }
    }

    func selection(in frame: ScreenCaptureService.FreezeFrame) -> (crop: NSRect?, selected: Bool) {
        switch self {
        case .pointerDisplay:
            return (frame.windowCrop, false)
        case .display:
            return (NSRect(x: 0, y: 0, width: frame.pixelWidth, height: frame.pixelHeight), true)
        }
    }
}
