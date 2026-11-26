import AppKit
import FlutterMacOS
import QuartzCore

enum CharRevealBatch {
    static func batchBase(previous: String, current: String) -> Int {
        guard !current.isEmpty else { return 0 }
        if previous == current { return current.count }
        if !previous.isEmpty && current.hasPrefix(previous) { return previous.count }
        return 0
    }

    static func stagger(
        revealingCount: Int,
        baseStagger: TimeInterval = AppConstants.charRevealStagger,
        maxSpread: TimeInterval = AppConstants.charRevealMaxSpread
    ) -> TimeInterval {
        guard revealingCount > 0 else { return 0 }
        return min(baseStagger, maxSpread / Double(revealingCount))
    }

    static func totalDuration(
        revealingCount: Int,
        charDuration: TimeInterval = AppConstants.charRevealDuration,
        baseStagger: TimeInterval = AppConstants.charRevealStagger,
        maxSpread: TimeInterval = AppConstants.charRevealMaxSpread
    ) -> TimeInterval {
        guard revealingCount > 0 else { return 0 }
        let step = stagger(revealingCount: revealingCount, baseStagger: baseStagger, maxSpread: maxSpread)
        return charDuration + step * Double(revealingCount - 1)
    }

    static func progress(
        elapsed: TimeInterval,
        index: Int,
        stagger: TimeInterval,
        charDuration: TimeInterval = AppConstants.charRevealDuration
    ) -> CGFloat {
        let delay = Double(index) * stagger
        guard charDuration > 0 else { return elapsed >= delay ? 1 : 0 }
        let ratio = (elapsed - delay) / charDuration
        return CGFloat(min(1, max(0, ratio)))
    }

    static func blurRadius(progress: CGFloat, maxBlur: CGFloat = AppConstants.charRevealBlur) -> CGFloat {
        let clamped = min(1, max(0, progress))
        return maxBlur * (1 - clamped)
    }
}

private final class LiveRevealLinkTarget: NSObject {
    weak var owner: LiveFitTextView?

    init(owner: LiveFitTextView) {
        self.owner = owner
    }

    @objc func step(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.stepReveal()
        }
    }
}

final class LiveFitTextView: NSView {
    var isReduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var text = "" {
        didSet {
            guard text != oldValue else { return }
            let base = CharRevealBatch.batchBase(previous: oldValue, current: text)
            let count = text.count - base
            if text.isEmpty || count <= 0 || isReduceMotion() {
                stopReveal()
                revealedBase = text.count
            } else {
                revealedBase = base
                batchStagger = CharRevealBatch.stagger(revealingCount: count)
                batchDuration = CharRevealBatch.totalDuration(revealingCount: count)
                batchStartedAt = CACurrentMediaTime()
                ensureDisplayLink()
            }
            needsDisplay = true
        }
    }

    private var revealedBase = 0
    private var batchStagger: TimeInterval = 0
    private var batchDuration: TimeInterval = 0
    private var batchStartedAt: TimeInterval?
    private var displayLink: CADisplayLink?
    private var fitted: (text: String, size: NSSize, font: NSFont)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopReveal()
        } else if revealedBase < text.count, batchStartedAt != nil, !isReduceMotion() {
            ensureDisplayLink()
        }
    }

    func reset() {
        stopReveal()
        revealedBase = 0
        fitted = nil
        text = ""
    }

    private func ensureDisplayLink() {
        guard window != nil, displayLink == nil else { return }
        let link = displayLink(target: LiveRevealLinkTarget(owner: self), selector: #selector(LiveRevealLinkTarget.step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopReveal() {
        displayLink?.invalidate()
        displayLink = nil
        batchStartedAt = nil
    }

    fileprivate func stepReveal() {
        guard !isReduceMotion(),
              revealedBase < text.count,
              let batchStartedAt else {
            stopReveal()
            revealedBase = text.count
            needsDisplay = true
            return
        }
        if CACurrentMediaTime() - batchStartedAt >= batchDuration {
            stopReveal()
            revealedBase = text.count
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = overlayColors()
        let radius = min(AppConstants.liveOverlayCornerRadius, min(bounds.width, bounds.height) / 2)
        let cardPath = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        colors.background.setFill()
        cardPath.fill()
        if bounds.width > 4 && bounds.height > 4 {
            colors.border.setStroke()
            let strokePath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: max(0, radius - 0.5), yRadius: max(0, radius - 0.5))
            strokePath.lineWidth = 1
            strokePath.stroke()
        }

        let padX = min(AppConstants.liveOverlayPadding.width, bounds.width * 0.12)
        let padY = min(AppConstants.liveOverlayPadding.height, bounds.height * 0.12)
        let contentRect = bounds.insetBy(dx: padX, dy: padY)
        guard !text.isEmpty, contentRect.width > 1, contentRect.height > 1 else { return }

        let fitted = fittedFont(in: contentRect.size)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: fitted,
            .foregroundColor: colors.text,
            .paragraphStyle: style,
        ]
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: contentRect.width, height: 10_000),
            options: [.usesLineFragmentOrigin],
            attributes: baseAttributes
        )
        let drawRect: NSRect
        if measured.height <= contentRect.height {
            let originY = contentRect.minY + (contentRect.height - measured.height) / 2
            drawRect = NSRect(
                x: contentRect.minX,
                y: originY,
                width: contentRect.width,
                height: max(1, contentRect.maxY - originY)
            )
        } else {
            drawRect = contentRect
        }

        let drawOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        let animatingElapsed: TimeInterval? = {
            guard !isReduceMotion(),
                  revealedBase < text.count,
                  let batchStartedAt else { return nil }
            let elapsed = CACurrentMediaTime() - batchStartedAt
            if elapsed >= batchDuration {
                stopReveal()
                revealedBase = text.count
                return nil
            }
            return elapsed
        }()

        NSGraphicsContext.saveGraphicsState()
        cardPath.addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        guard let elapsed = animatingElapsed else {
            (text as NSString).draw(
                with: drawRect,
                options: drawOptions,
                attributes: baseAttributes
            )
            return
        }

        let attributed = NSMutableAttributedString(string: text, attributes: baseAttributes)
        var cursor = text.index(text.startIndex, offsetBy: revealedBase)
        var offset = 0
        while cursor < text.endIndex {
            let next = text.index(after: cursor)
            let range = NSRange(cursor..<next, in: text)
            let t = CharRevealBatch.progress(elapsed: elapsed, index: offset, stagger: batchStagger)
            let color = colors.text.withAlphaComponent(t)
            attributed.addAttribute(.foregroundColor, value: color, range: range)
            let blur = CharRevealBatch.blurRadius(progress: t)
            if blur > 0.01 && t > 0.001 {
                let shadow = NSShadow()
                shadow.shadowColor = color
                shadow.shadowOffset = .zero
                shadow.shadowBlurRadius = blur
                attributed.addAttribute(.shadow, value: shadow, range: range)
            }
            cursor = next
            offset += 1
        }
        attributed.draw(with: drawRect, options: drawOptions)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func overlayColors() -> (background: NSColor, text: NSColor, border: NSColor) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let alpha: CGFloat = highContrast ? 0.96 : 0.88
        if dark {
            return (
                NSColor(srgbRed: 28.0 / 255.0, green: 28.0 / 255.0, blue: 30.0 / 255.0, alpha: alpha),
                NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1),
                NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14)
            )
        }
        return (
            NSColor(srgbRed: 249.0 / 255.0, green: 249.0 / 255.0, blue: 251.0 / 255.0, alpha: alpha),
            NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1),
            NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.10)
        )
    }

    private func fittedFont(in availableSize: NSSize) -> NSFont {
        if let fitted, fitted.text == text, fitted.size == availableSize { return fitted.font }
        let floorSize = min(AppConstants.liveOverlayMinFontSize, max(6, availableSize.height * 0.85))
        var low = floorSize
        var high = max(floorSize, availableSize.height)
        var best = floorSize
        while high - low > 0.5 {
            let size = (low + high) / 2
            let font = NSFont.systemFont(ofSize: size, weight: .semibold)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            let rect = (text as NSString).boundingRect(
                with: NSSize(width: availableSize.width, height: 10_000),
                options: [.usesLineFragmentOrigin],
                attributes: [.font: font, .paragraphStyle: style]
            )
            if rect.height <= availableSize.height + 0.5, rect.width <= availableSize.width + 0.5 {
                best = size
                low = size
            } else {
                high = size
            }
        }
        let font = NSFont.systemFont(ofSize: best, weight: .semibold)
        fitted = (text, availableSize, font)
        return font
    }
}

@MainActor
final class LiveTextOverlay {
    private var panels: [(screen: NSRect, panel: NSPanel)] = []
    private var appearanceObserver: NSObjectProtocol?

    deinit {
        if let observer = appearanceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func open() {
        close()
        for screen in NSScreen.screens {
            let panel = makePanel(frame: screen.frame)
            panel.orderFrontRegardless()
            panels.append((screen.frame, panel))
        }
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.appearanceChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAppearance() }
        }
    }

    private func syncAppearance() {
        for item in panels {
            NativeGlassFactory.applyAppearance(to: item.panel)
            for case let label as LiveFitTextView in item.panel.contentView?.subviews ?? [] {
                label.needsDisplay = true
            }
        }
    }

    nonisolated static func matchSlots(
        previousFrames: [NSRect],
        previousTexts: [String],
        newItems: [(text: String, rect: NSRect)]
    ) -> [Int?] {
        var candidates: [(newIndex: Int, oldIndex: Int, score: Double)] = []
        for (newIdx, item) in newItems.enumerated() {
            for (oldIdx, oldFrame) in previousFrames.enumerated() {
                let threshold = max(max(oldFrame.width, item.rect.width), max(oldFrame.height, item.rect.height)) * 0.65
                let dist = hypot(item.rect.midX - oldFrame.midX, item.rect.midY - oldFrame.midY)
                let overlaps = !oldFrame.intersection(item.rect).isEmpty
                guard overlaps || dist <= threshold else { continue }
                let oldText = oldIdx < previousTexts.count ? previousTexts[oldIdx] : ""
                let textBonus: Double
                if !oldText.isEmpty && oldText == item.text {
                    textBonus = 10_000
                } else if !oldText.isEmpty && (item.text.hasPrefix(oldText) || oldText.hasPrefix(item.text)) {
                    textBonus = 5_000
                } else {
                    textBonus = 0
                }
                candidates.append((newIdx, oldIdx, textBonus - dist))
            }
        }
        candidates.sort { $0.score > $1.score }
        var assigned = Array<Int?>(repeating: nil, count: newItems.count)
        var usedOld = Set<Int>()
        for candidate in candidates {
            guard assigned[candidate.newIndex] == nil, !usedOld.contains(candidate.oldIndex) else { continue }
            assigned[candidate.newIndex] = candidate.oldIndex
            usedOld.insert(candidate.oldIndex)
        }
        return assigned
    }

    func apply(_ chips: [[String: Any]]) {
        var grouped: [[(text: String, rect: NSRect)]] = panels.map { _ in [] }
        for chip in chips {
            guard let text = chip["text"] as? String,
                  let x = chip["x"] as? Double,
                  let y = chip["y"] as? Double,
                  let width = chip["width"] as? Double,
                  let height = chip["height"] as? Double,
                  width > 1, height > 1 else { continue }
            let rect = NSRect(x: x, y: y, width: width, height: height)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            guard let index = panels.firstIndex(where: { $0.screen.contains(center) }) else { continue }
            grouped[index].append((text, rect.offsetBy(dx: -panels[index].screen.minX, dy: -panels[index].screen.minY)))
        }
        for (index, items) in grouped.enumerated() {
            guard let canvas = panels[index].panel.contentView else { continue }
            let allViews = canvas.subviews.compactMap { $0 as? LiveFitTextView }
            let activeViews = allViews.filter { !$0.isHidden }
            var idleViews = allViews.filter(\.isHidden)

            let matches = Self.matchSlots(
                previousFrames: activeViews.map(\.frame),
                previousTexts: activeViews.map(\.text),
                newItems: items
            )
            let usedOldIndices = Set(matches.compactMap { $0 })
            for (oldIdx, view) in activeViews.enumerated() where !usedOldIndices.contains(oldIdx) {
                view.reset()
                view.isHidden = true
                idleViews.append(view)
            }

            for (newIdx, item) in items.enumerated() {
                let targetView: LiveFitTextView
                if let matchedIdx = matches[newIdx] {
                    targetView = activeViews[matchedIdx]
                } else if let recycled = idleViews.popLast() {
                    recycled.reset()
                    targetView = recycled
                } else {
                    let created = LiveFitTextView(frame: .zero)
                    canvas.addSubview(created)
                    targetView = created
                }
                if targetView.frame != item.rect { targetView.frame = item.rect }
                targetView.text = item.text
                targetView.isHidden = false
            }
        }
    }

    func clear() {
        apply([])
    }

    func close() {
        if let observer = appearanceObserver {
            NotificationCenter.default.removeObserver(observer)
            appearanceObserver = nil
        }
        for item in panels {
            for case let label as LiveFitTextView in item.panel.contentView?.subviews ?? [] {
                label.reset()
            }
            item.panel.orderOut(nil)
        }
        panels = []
    }

    private func makePanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        NativeGlassFactory.applyAppearance(to: panel)
        return panel
    }
}

@MainActor
final class LiveRegionCoordinator {
    private let bridge: MacPlatformBridge
    private let controls: CaptureWindowController
    private let overlay = LiveTextOverlay()
    private let capture = LiveRegionCapture()
    private var generation = 0
    private var running = false
    private var ended = false
    private var busy = false
    private var source: [String: Any] = [:]
    private var region: MediaCaptureService.Region?
    private var recording = false

    init(bridge: MacPlatformBridge, controls: CaptureWindowController) {
        self.bridge = bridge
        self.controls = controls
        capture.onRecognized = { [weak self] generation, blocks, failure in
            self?.sendOcr(generation: generation, blocks: blocks, failure: failure)
        }
        capture.onUnavailable = { [weak self] message in
            Task { await self?.unavailable(message) }
        }
        capture.onFrame = { [weak self] frame in
            self?.controls.setLiveShade(frame)
        }
        controls.onLivePause = { [weak self] paused in
            Task { paused ? await self?.pause() : await self?.resume() }
        }
        controls.onLiveStop = { [weak self] in
            Task { await self?.end() }
        }
        controls.onLiveCancel = { [weak self] in
            Task { await self?.discard() }
        }
    }

    func preview(on screen: NSScreen?) {
        controls.prepareControls()
    }

    func cancelPreview() {}

    func begin(source: [String: Any], region: MediaCaptureService.Region?) async throws {
        guard !running, !controls.hasPendingCapture else {
            throw GIFExporter.ExportError(message: "请先结束或放弃当前采集。")
        }
        self.source = source
        self.region = region
        generation += 1
        let token = generation
        running = true
        ended = false
        let displayID = (source["sourceID"] as? NSNumber)?.uint32Value
        let screen = NSScreen.screens.first { $0.displayID == displayID }
        let preferences = AppPreferences.current
        recording = preferences[AppConstants.liveRecordingKey] as? Bool == true
        overlay.open()
        bridge.screenshot.hideForCapture()
        controls.showLiveControls(id: "live-\(token)", screen: screen)
        StatusBarController.shared.setLiveAbort(true) { [weak self] in
            Task { await self?.end() }
        }
        do {
            try await command(.start, generation: token)
            try await capture.start(source: source, region: region, generation: token)
            if recording {
                if let region { try controls.service.select(region) }
                try await controls.service.startRecording(source, delay: 0)
            }
        } catch {
            generation += 1
            await capture.stop()
            await cancelRecording()
            if token != generation { try? await command(.discard, generation: generation) }
            running = false
            overlay.close()
            bridge.screenshot.restoreAfterCapturePreparation()
            controls.hideLiveControls()
            throw error
        }
        guard running, generation == token else { return }
        bridge.screenshot.closeForCapture()
        controls.showLiveControls(id: "live-\(token)", screen: screen)
    }

    private func pause() async {
        guard running, !ended, !busy else { return }
        busy = true
        defer { busy = false }
        generation += 1
        await capture.pause(generation: generation)
        overlay.clear()
        await pauseRecording(true)
        controls.setLivePaused(true)
        try? await command(.pause, generation: generation)
    }

    private func resume() async {
        guard running, !ended, !busy else { return }
        busy = true
        defer { busy = false }
        generation += 1
        let token = generation
        do {
            try await command(.resume, generation: token)
            try await capture.resume(source: source, region: region, generation: token)
            await pauseRecording(false)
            controls.setLivePaused(false)
        } catch {
            await unavailable(error.localizedDescription)
        }
    }

    private func end() async {
        guard running, !ended, !busy else { return }
        busy = true
        defer { busy = false }
        generation += 1
        ended = true
        running = false
        await capture.stop()
        await stopRecording()
        controls.hideLiveControls()
        controls.setLiveShade(nil)
        overlay.close()
        StatusBarController.shared.setLiveAbort(false)
        try? await command(.end, generation: generation)
    }

    private func discard() async {
        guard (running || ended || windowVisible), !busy else { return }
        busy = true
        defer { busy = false }
        generation += 1
        let token = generation
        running = false
        ended = false
        await capture.stop()
        await cancelRecording()
        controls.hideLiveControls()
        controls.setLiveShade(nil)
        overlay.close()
        StatusBarController.shared.setLiveAbort(false)
        try? await command(.discard, generation: token)
    }

    private func unavailable(_ message: String) async {
        guard running || ended else { return }
        generation += 1
        running = false
        ended = true
        await capture.stop()
        await stopRecording()
        controls.hideLiveControls()
        controls.setLiveShade(nil)
        overlay.close()
        StatusBarController.shared.setLiveAbort(false)
        try? await command(.captureFailed, generation: generation, failure: message)
    }

    private func pauseRecording(_ paused: Bool) async {
        guard recording else { return }
        do {
            try await controls.service.setPaused(paused)
        } catch {
            LiveRegionLog.note("record pause=\(paused) error=\(error.localizedDescription)")
        }
    }

    private func stopRecording() async {
        guard recording else { return }
        recording = false
        do {
            try await controls.service.stop()
        } catch {
            LiveRegionLog.note("record stop error=\(error.localizedDescription)")
        }
    }

    private func cancelRecording() async {
        guard recording else { return }
        recording = false
        await controls.service.cancel()
    }

    private var windowVisible: Bool { running || ended }

    private func command(_ action: LiveRegionAction, generation: Int, failure: String? = nil) async throws {
        var arguments: [String: Any] = ["action": action.rawValue, "generation": generation]
        if let failure { arguments["failure"] = failure }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            bridge.requestApplication(AppConstants.liveRegionCommandMethod, arguments: arguments) { result in
                if let error = result as? FlutterError {
                    continuation.resume(throwing: GIFExporter.ExportError(message: error.message ?? error.code))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func sendOcr(generation: Int, blocks: [ScreenCaptureService.OCRBlock]?, failure: String?) {
        var arguments: [String: Any] = ["generation": generation]
        if let blocks { arguments["blocks"] = blocks.map(\.channelValue) }
        if let failure { arguments["failure"] = failure }
        bridge.requestApplication(AppConstants.liveRegionOcrMethod, arguments: arguments) { _ in }
    }

    func publish(_ state: [String: Any]) {
        guard let raw = state["phase"] as? String, let phase = LiveRegionPhase(rawValue: raw),
              let status = state["status"] as? String,
              let overlays = state["overlays"] as? [[String: Any]],
              let metrics = state["metrics"] as? [[String: Any]] else {
            preconditionFailure("实时翻译快照缺少可识别的字段")
        }
        for item in metrics {
            let fields = ["blocks", "chars", "waitMs", "firstMs", "totalMs", "inflight", "outcome"]
                .map { "\($0)=\(item[$0]!)" }
                .joined(separator: " ")
            LiveRegionLog.note("batch \(fields)")
        }
        let runningNow = phase == .running
        overlay.apply(runningNow ? overlays : [])
        controls.setLiveDetail(runningNow ? status : "")
    }
}
