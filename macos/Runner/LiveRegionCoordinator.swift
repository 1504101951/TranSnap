import AppKit
import FlutterMacOS
import QuartzCore

/// 实时翻译盖层的逐字显影计算（#142）：批内追加仅显影新字、错峰受总长上限约束，与 Dart CharReveal 一致。
enum CharRevealBatch {
    /// previous 为上一帧译文，current 为当前帧译文；返回本帧已完整显示的前缀字数（Character 粒度）。
    /// 内容不变时返回全长，紧跟上次前缀追加时保留已显示部分，首次或整段替换时从头显影。
    static func batchBase(previous: String, current: String) -> Int {
        guard !current.isEmpty else { return 0 }
        if previous == current { return current.count }
        if !previous.isEmpty && current.hasPrefix(previous) { return previous.count }
        return 0
    }

    /// revealingCount 为本批待显影字数，baseStagger 为基准字间隔，maxSpread 为整段错峰总长上限；返回单个字符间的错峰时长。
    static func stagger(
        revealingCount: Int,
        baseStagger: TimeInterval = AppConstants.charRevealStagger,
        maxSpread: TimeInterval = AppConstants.charRevealMaxSpread
    ) -> TimeInterval {
        guard revealingCount > 0 else { return 0 }
        return min(baseStagger, maxSpread / Double(revealingCount))
    }

    /// revealingCount 为本批待显影字数，charDuration 为单字显现时长，其余为错峰上限；返回本批显影总时长（秒）。
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

    /// elapsed 为本批已经过时间（秒），index 为本批内字符序号，stagger 为字间错峰，charDuration 为单字显影时长；返回 0...1 进度。
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

    /// progress 为单字 0...1 显影进度，maxBlur 为初始模糊半径（pt）；返回当前同色阴影近似模糊半径。
    static func blurRadius(progress: CGFloat, maxBlur: CGFloat = AppConstants.charRevealBlur) -> CGFloat {
        let clamped = min(1, max(0, progress))
        return maxBlur * (1 - clamped)
    }
}

/// 逐帧显影定时器代理；以弱引用连接视图，视图销毁时自动释放显示链路，避免循环引用与跨线程清理冲突。
private final class LiveRevealLinkTarget: NSObject {
    weak var owner: LiveFitTextView?

    /// owner 为驱动逐帧显影的段落视图；保存弱引用，不延长视图寿命。
    init(owner: LiveFitTextView) {
        self.owner = owner
    }

    /// link 为显示器刷新信号；宿主视图已销毁时立即停止链路，否则触发下一帧显影重绘。
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

/// 把整段译文缩进段落块矩形并在矩形内换行。字号可以很小，绘制不超出该矩形，并按批次逐字显现（#142）。
final class LiveFitTextView: NSView {
    /// 读取系统「减少动态效果」设置；测试可覆写以隔离系统偏好。
    var isReduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// 段落译文；内容不变时不重画，追加新字仅显影后缀，替换则整段重播（减少动态效果下直接显示）。
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

    /// 本批开始前已完整显示的字符数；显影区间为 [revealedBase, text.count)。
    private var revealedBase = 0
    private var batchStagger: TimeInterval = 0
    private var batchDuration: TimeInterval = 0
    private var batchStartedAt: TimeInterval?
    private var displayLink: CADisplayLink?
    /// 最近一次适配的结果：同一段文字在同一尺寸下不重复计算字号。
    private var fitted: (text: String, size: NSSize, font: NSFont)?

    /// 无参数；视图挂入或移出窗口时同步维护显影刷新链路，离窗即停，无返回值。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopReveal()
        } else if revealedBase < text.count, batchStartedAt != nil, !isReduceMotion() {
            ensureDisplayLink()
        }
    }

    /// 无参数；停止显影刷新并清空段落内容，在段落槽位复用前或盖层关闭时调用，无返回值。
    func reset() {
        stopReveal()
        revealedBase = 0
        fitted = nil
        text = ""
    }

    /// 无参数；确认显示刷新链路已激活，用于显影期间逐帧重绘，无返回值。
    private func ensureDisplayLink() {
        guard window != nil, displayLink == nil else { return }
        let link = displayLink(target: LiveRevealLinkTarget(owner: self), selector: #selector(LiveRevealLinkTarget.step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// 无参数；停止当前显影链路并清理计时起点，无返回值。
    private func stopReveal() {
        displayLink?.invalidate()
        displayLink = nil
        batchStartedAt = nil
    }

    /// 无参数；处理每次屏幕刷新：未到总时长时请求重绘，完成后停表并固化全段，无返回值。
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

    /// dirtyRect 为需要重画的区域。白底盖住原文，黑色半粗体缩进框内，逐字显影期用透明度与同色阴影柔和渐入。
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0xCC / 255).setFill()
        bounds.fill()
        guard !text.isEmpty, bounds.width > 1, bounds.height > 1 else { return }
        // 字号与居中边界始终按完整文本测算，避免显影期间文字换行跳动。
        let fitted = fittedFont()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: fitted,
            .foregroundColor: NSColor.black,
            .paragraphStyle: style,
        ]
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: bounds.width, height: 10_000),
            options: [.usesLineFragmentOrigin],
            attributes: baseAttributes
        )
        let origin = NSPoint(
            x: 0,
            y: max(0, (bounds.height - measured.height) / 2)
        )
        let drawRect = NSRect(origin: origin, size: NSSize(width: bounds.width, height: bounds.height))

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

        guard let elapsed = animatingElapsed else {
            (text as NSString).draw(
                with: drawRect,
                options: [.usesLineFragmentOrigin],
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
            let color = NSColor.black.withAlphaComponent(t)
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
        attributed.draw(with: drawRect, options: [.usesLineFragmentOrigin])
    }

    /// 无参数。返回能把整段留在当前矩形里的最大半粗体字号；文字与尺寸都没变时沿用上次结果。
    private func fittedFont() -> NSFont {
        if let fitted, fitted.text == text, fitted.size == bounds.size { return fitted.font }
        var low = 1.0
        var high = max(1, bounds.height)
        var best = low
        while high - low > 0.5 {
            let size = (low + high) / 2
            let font = NSFont.systemFont(ofSize: size, weight: .semibold)
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            let rect = (text as NSString).boundingRect(
                with: NSSize(width: bounds.width, height: 10_000),
                options: [.usesLineFragmentOrigin],
                attributes: [.font: font, .paragraphStyle: style]
            )
            if rect.height <= bounds.height + 0.5, rect.width <= bounds.width + 0.5 {
                best = size
                low = size
            } else {
                high = size
            }
        }
        let font = NSFont.systemFont(ofSize: best, weight: .semibold)
        fitted = (text, bounds.size, font)
        return font
    }
}

/// 点击穿透的译文盖层。每个显示器一个透明窗口，段落块是窗口里的子视图。
/// 窗口属于本应用，识别用的捕获流不会再次捕获它；同步录制只排除采集控制窗口，盖层自然进入录制画面。
@MainActor
final class LiveTextOverlay {
    private var panels: [(screen: NSRect, panel: NSPanel)] = []

    /// 无参数。在每个显示器上铺一个空的透明窗口并显示；会话开始时调用。
    func open() {
        close()
        for screen in NSScreen.screens {
            let panel = makePanel(frame: screen.frame)
            panel.orderFrontRegardless()
            panels.append((screen.frame, panel))
        }
    }

    /// chips 为已归属译文的屏幕矩形。按矩形中心所在的显示器放进对应窗口；空列表撤掉全部译文。
    func apply(_ chips: [[String: Any]]) {
        var grouped: [[(String, NSRect)]] = panels.map { _ in [] }
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
            // 屏幕坐标换成该窗口内的坐标。
            grouped[index].append((text, rect.offsetBy(dx: -panels[index].screen.minX, dy: -panels[index].screen.minY)))
        }
        for (index, items) in grouped.enumerated() {
            guard let canvas = panels[index].panel.contentView else { continue }
            // 复用已有的段落视图，只补建不够的部分。
            while canvas.subviews.count < items.count {
                canvas.addSubview(LiveFitTextView(frame: .zero))
            }
            for (position, view) in canvas.subviews.enumerated() {
                guard position < items.count, let label = view as? LiveFitTextView else {
                    (view as? LiveFitTextView)?.reset()
                    view.isHidden = true
                    continue
                }
                // 位置与文字没变的段落块不触发重画。
                if label.frame != items[position].1 { label.frame = items[position].1 }
                label.text = items[position].0
                label.isHidden = false
            }
        }
    }

    /// 无参数。撤掉全部译文，窗口保持显示。
    func clear() {
        apply([])
    }

    /// 无参数。关闭全部盖层窗口并停止显影链路；会话结束时调用。
    func close() {
        for item in panels {
            for case let label as LiveFitTextView in item.panel.contentView?.subviews ?? [] {
                label.reset()
            }
            item.panel.orderOut(nil)
        }
        panels = []
    }

    /// frame 为显示器的屏幕矩形。返回铺满该显示器、不接收鼠标、不成为 key 的透明窗口。
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
        return panel
    }
}

/// 连接译文盖层、采集悬浮条、未编码捕获和主引擎会话。不保存译文。
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
    /// 本次实时翻译是否同步录制。
    private var recording = false

    /// bridge 转发主引擎命令，controls 复用采集悬浮条。
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

    /// screen 为截图显示器。准备阶段先建好录制同款控制条，开始前不显示。
    func preview(on screen: NSScreen?) {
        controls.prepareControls()
    }

    /// 无参数。准备阶段没有预览窗可关。
    func cancelPreview() {}

    /// source 为截图确认的目标，region 为区域选区。锁定预览并开始识别。
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
        // 是否同步录制取自已保存的设置，对区域、窗口和全屏目标都生效。
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
                // 录制与识别各用一路捕获；录制只排除采集控制窗口，译文盖层自然进入画面。
                if let region { try controls.service.select(region) }
                // 实时翻译的同步录制随翻译立即开始，不延时（#129）。
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
        // 先结束录制再撤控制条；控制条随后按媒体阶段显示完成进度与录制结果。
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
        // 采集失效时保留已经录到的内容，交给录制结果窗口处理。
        await stopRecording()
        controls.hideLiveControls()
        controls.setLiveShade(nil)
        overlay.close()
        StatusBarController.shared.setLiveAbort(false)
        try? await command(.captureFailed, generation: generation, failure: message)
    }

    /// paused 为真暂停录制，为假继续录制。未同步录制时不做任何事；失败写入排查日志。
    private func pauseRecording(_ paused: Bool) async {
        guard recording else { return }
        do {
            try await controls.service.setPaused(paused)
        } catch {
            LiveRegionLog.note("record pause=\(paused) error=\(error.localizedDescription)")
        }
    }

    /// 无参数。结束同步录制并保留结果；未同步录制时不做任何事，失败写入排查日志。
    private func stopRecording() async {
        guard recording else { return }
        recording = false
        do {
            try await controls.service.stop()
        } catch {
            LiveRegionLog.note("record stop error=\(error.localizedDescription)")
        }
    }

    /// 无参数。丢弃同步录制及其临时文件；未同步录制时不做任何事。
    private func cancelRecording() async {
        guard recording else { return }
        recording = false
        await controls.service.cancel()
    }

    private var windowVisible: Bool { running || ended }

    /// action/generation 交给主引擎。failure 只用于采集失效。
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

    private func sendOcr(generation: Int, blocks: [[String: Any]]?, failure: String?) {
        var arguments: [String: Any] = ["generation": generation]
        if let blocks {
            arguments["blocks"] = blocks
            arguments["text"] = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        if let failure { arguments["failure"] = failure }
        bridge.requestApplication(AppConstants.liveRegionOcrMethod, arguments: arguments) { _ in }
    }

    /// state 为主引擎快照。只在运行中把已归属译文盖到段落块上。
    func publish(_ state: [String: Any]) {
        // 主引擎快照总带 phase、status、overlays、metrics 四个字段（LiveRegionView.toMap）；
        // 缺少或类型不符即两端协议不一致，直接终止，不补默认值（#127、#132）。
        guard let raw = state["phase"] as? String, let phase = LiveRegionPhase(rawValue: raw),
              let status = state["status"] as? String,
              let overlays = state["overlays"] as? [[String: Any]],
              let metrics = state["metrics"] as? [[String: Any]] else {
            preconditionFailure("实时翻译快照缺少可识别的字段")
        }
        // metrics 为主引擎给出的批次计时，每个批次只出现一次；字段固定由主引擎写入，逐项记入日志。
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
