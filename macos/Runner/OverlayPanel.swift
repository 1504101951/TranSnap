import AppKit
import FlutterMacOS

/// 非激活窗口只承载 Flutter 内容；拖动、显隐和屏幕边界由原生处理。
final class OverlayPanelController {
    var isPanelVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    private let panel: TranslationPanel
    private let host = OverlayHostViewController()
    private var currentSessionId: String?
    private var mouseMonitor: Any?
    private var dragStartEvent: NSEvent?
    private var capturedSessionId: String?
    private var captureHidden = false

    /// 无参数；创建不能成为 key/main 的透明浮层。
    init() {
        panel = TranslationPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // Warp 等来源 App 的置顶窗口可能位于 status-bar 及以上并反复置前；screenSaver 层级保持译文可见，仍不取得 key/main（#19）。
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentViewController = host
        // AppKit 要求最初的 mouseDown；跨 Flutter 通道后 currentEvent 已不可靠。
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            self.dragStartEvent = event.type == .leftMouseDown && event.window === self.panel ? event : nil
            return event
        }
    }

    /// 无参数、无返回值；释放窗口鼠标监听，避免旧控制器残留。
    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    /// point 为 AppKit 屏幕坐标；返回它是否位于可见浮层中。
    func contains(_ point: NSPoint) -> Bool {
        panel.isVisible && panel.frame.contains(point)
    }

    /// controller 为共享 Flutter 引擎的视图控制器；挂载内容并同步面板外观，无返回值。
    func attachFlutter(_ controller: FlutterViewController) {
        NativeGlassFactory.applyAppearance(to: panel)
        // child controller 保持引擎及视图生命周期一致。
        host.embed(controller)
    }

    /// size 为浮层目标尺寸；触发胶囊与展开卡片采用不同宿主裁切圆角，消除与 Flutter 卡片的边角断层（#144 U-18）。
    static func cornerRadius(for size: NSSize) -> CGFloat {
        size.height <= AppConstants.overlayTriggerMaxHeight
            ? AppConstants.overlayTriggerCornerRadius
            : AppConstants.overlayCardCornerRadius
    }

    /// point 为选区锚点，size 为完整内容尺寸，sessionId 为会话；显示窗口，无返回值。
    func show(at point: NSPoint, size: NSSize, sessionId: String) {
        currentSessionId = sessionId
        dragStartEvent = nil
        NativeGlassFactory.applyAppearance(to: panel)
        host.setCornerRadius(Self.cornerRadius(for: size))
        var frame = NSRect(x: point.x + 8, y: point.y - size.height - 8, width: size.width, height: size.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            let maxX = max(visible.minX, visible.maxX - size.width)
            let maxY = max(visible.minY, visible.maxY - size.height)
            frame.origin.x = min(max(frame.minX, visible.minX), maxX)
            frame.origin.y = min(max(frame.minY, visible.minY), maxY)
        }
        panel.setFrame(frame, display: true)
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        // 显示和交互都不调用 activate / makeKey，键盘继续留在来源应用。
        if captureHidden {
            capturedSessionId = sessionId
        } else if !panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = AppConstants.overlayFadeInDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }
    }

    /// sessionId 标识要关闭的会话；过期指令不影响当前窗口，无返回值。
    func hide(sessionId: String) {
        guard currentSessionId == sessionId else { return }
        currentSessionId = nil
        dragStartEvent = nil
        panel.alphaValue = 1
        panel.orderOut(nil)
    }

    /// sessionId 标识会话，size 为内容尺寸；保留左上角、同步动态圆角并夹取屏幕边界，无返回值。
    func resize(sessionId: String, size: NSSize) {
        // 流式译文反复通知同一尺寸，不能在系统拖动期间重新夹取窗口位置。
        guard currentSessionId == sessionId, panel.frame.size != size else { return }
        host.setCornerRadius(Self.cornerRadius(for: size))
        var frame = panel.frame
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        if let screen = panel.screen {
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            let maxX = max(visible.minX, visible.maxX - size.width)
            let maxY = max(visible.minY, visible.maxY - size.height)
            frame.origin.x = min(max(frame.minX, visible.minX), maxX)
            frame.origin.y = min(max(frame.minY, visible.minY), maxY)
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = AppConstants.overlayResizeAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
            }
        }
    }

    /// hidden 表示系统正在框选；临时排除翻译浮层，完成后只恢复仍有效的会话，无返回值。
    func setCaptureHidden(_ hidden: Bool) {
        captureHidden = hidden
        if hidden {
            capturedSessionId = panel.isVisible ? currentSessionId : nil
            panel.orderOut(nil)
        } else {
            if let capturedSessionId, capturedSessionId == currentSessionId { panel.orderFrontRegardless() }
            capturedSessionId = nil
        }
    }

    /// sessionId 标识会话；将该窗口原始按下事件交给系统拖动，无返回值。
    func drag(sessionId: String) {
        guard currentSessionId == sessionId, let event = dragStartEvent,
              NSEvent.pressedMouseButtons & 1 != 0 else { return }
        dragStartEvent = nil
        panel.performDrag(with: event)
    }
}

/// 不可成为key或main的透明浮层窗口；显示译文时不夺取来源应用的键盘焦点。
final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Flutter 填满窗口，圆角裁切按触发胶囊或展开卡片动态切换，不额外占用内容空间。
final class OverlayHostViewController: NSViewController {
    private var cornerRadius = AppConstants.overlayCardCornerRadius

    /// 无参数；创建透明圆角容器，无返回值。
    override func loadView() {
        view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
    }

    /// radius 为当前窗口内容圆角（触发胶囊 10pt / 译文卡片 16pt）；实时同步容器裁切半径，无返回值（#144 U-18）。
    func setCornerRadius(_ radius: CGFloat) {
        cornerRadius = radius
        guard isViewLoaded else { return }
        view.layer?.cornerRadius = radius
    }

    /// controller 为 Flutter 内容；约束至容器四边，无返回值。
    func embed(_ controller: FlutterViewController) {
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

/// 输入翻译状态浮标：进行中浮标与失败气泡共用一个非激活玻璃面板，显示在选中区域附近，不抢焦点（#67、#99）。
@MainActor
final class InputStatusBubble {
    static let shared = InputStatusBubble()

    /// 当前显示内容的种类；会话结束只收起进行中浮标，不能带走刚显示的失败气泡。
    private enum Kind { case progress, failure }

    private var panel: NSPanel?
    private var kind: Kind?
    /// 每次显示、关闭、悬停或重新计时都递增，使旧计时失效。
    private var generation = 0

    /// anchor 为定位依据（选中区域与来源窗口，AppKit 全局坐标）；等待 inputProgressDelayMs 后仍未被收起才显示「翻译中…」浮标，忽略鼠标事件，无返回值。
    func showProgress(anchor: InputAnchor) {
        close()
        let current = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(AppConstants.inputProgressDelayMs))
            guard let self, self.generation == current else { return }
            let label = NSTextField(labelWithString: AppConstants.inputProgressText)
            label.font = .systemFont(ofSize: AppConstants.inputProgressFontSize)
            label.textColor = .labelColor
            label.lineBreakMode = .byClipping
            label.sizeToFit()
            let size = Self.progressSize(textWidth: label.frame.width)
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            let spinnerSize = AppConstants.inputProgressSpinnerSize
            spinner.frame = NSRect(x: AppConstants.inputProgressPaddingX, y: ((size.height - spinnerSize) / 2).rounded(),
                                   width: spinnerSize, height: spinnerSize)
            spinner.startAnimation(nil)
            label.frame.origin = NSPoint(x: spinner.frame.maxX + AppConstants.inputProgressSpacing,
                                         y: ((size.height - label.frame.height) / 2).rounded())
            let content = NSView(frame: NSRect(origin: .zero, size: size))
            content.addSubview(spinner)
            content.addSubview(label)
            // 浮标只提示进度，不抢焦点也不播报；失败结果由失败气泡播报。
            self.present(content: content, size: size, anchor: anchor, kind: .progress, ignoresMouse: true)
        }
    }

    /// message 为失败原因，anchor 为定位依据（选中区域与来源窗口，AppKit 全局坐标）；先收起进行中浮标并替换旧气泡，
    /// 停留 2000ms（悬停时暂停，鼠标移开后重新计算 2000ms），点击或到时关闭（#144 U-18、用户意见 #1）。
    func showFailure(_ message: String, anchor: InputAnchor) {
        close()
        let padding = AppConstants.scrollHintPadding
        let iconSize = AppConstants.inputFailureIconSize
        let iconSpacing = AppConstants.inputFailureIconSpacing
        let maxTextWidth = AppConstants.scrollHintMaxWidth - padding.width * 2 - iconSize - iconSpacing
        // 与长截图提示共用基础字号/行高/错误色，并配语义图标与左对齐排版避免仅靠颜色传达错误。
        let styled = NSMutableAttributedString(attributedString: CaptureShadeView.hintText(message, isError: true))
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 18
        paragraph.maximumLineHeight = 18
        paragraph.alignment = .left
        styled.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: styled.length))

        let label = NSTextField(wrappingLabelWithString: message)
        label.attributedStringValue = styled
        // 用实际绘制文字的控件测量，计入左侧图标与内边距，末尾文字不会被换到不可见的第二行。
        label.preferredMaxLayoutWidth = maxTextWidth
        let fitting = label.fittingSize
        let textSize = NSSize(width: min(ceil(fitting.width), maxTextWidth), height: max(18, ceil(fitting.height)))
        let bodyHeight = max(iconSize, textSize.height)
        let size = NSSize(
            width: padding.width * 2 + iconSize + iconSpacing + textSize.width,
            height: padding.height * 2 + bodyHeight
        )

        let icon = NSImageView(frame: NSRect(
            x: padding.width,
            y: ((size.height - iconSize) / 2).rounded(),
            width: iconSize,
            height: iconSize
        ))
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "错误")
        icon.contentTintColor = .systemRed
        icon.imageScaling = .scaleProportionallyDown

        label.frame = NSRect(
            origin: NSPoint(x: icon.frame.maxX + iconSpacing, y: ((size.height - textSize.height) / 2).rounded()),
            size: textSize
        )
        let content = BubbleClickView(frame: NSRect(origin: .zero, size: size))
        content.toolTip = "点击关闭"
        content.onClick = { [weak self] in self?.close() }
        content.onHoverChanged = { [weak self] hovering in
            guard let self, self.kind == .failure else { return }
            if hovering {
                // 鼠标悬停阅读长报错时暂停自动消失。
                self.generation += 1
            } else {
                // 鼠标离开后重新开始 2000ms 倒计时。
                self.scheduleFailureDismiss()
            }
        }
        content.addSubview(icon)
        content.addSubview(label)
        let container = present(content: content, size: size, anchor: anchor, kind: .failure, ignoresMouse: false)
        NSAccessibility.post(element: container, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        scheduleFailureDismiss()
    }

    /// 无参数；从当前代次起安排 2000ms 后自动关闭失败气泡，悬停或后续更新会递增 generation 使本次作废，无返回值。
    private func scheduleFailureDismiss() {
        generation += 1
        let current = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(AppConstants.inputFailureDurationMs))
            guard let self, self.generation == current else { return }
            self.close()
        }
    }

    /// 无参数；关闭当前浮标或气泡并取消尚未到点的浮标，没有内容时保持原状，无返回值。
    func close() {
        generation += 1
        panel?.orderOut(nil)
        panel = nil
        kind = nil
    }

    /// 无参数；会话结束时调用：取消尚未显示的浮标并收起已显示的浮标，失败气泡保持到自己的计时结束，无返回值。
    func closeProgress() {
        // 待显示的浮标由 generation 失效；已显示的失败气泡不受影响。
        if kind == .progress || kind == nil { close() }
    }

    /// content 为面板内容，size 为内容尺寸，anchor 为定位依据，kind 为内容种类，ignoresMouse 为是否点击穿透；
    /// 通过 NativeGlassFactory 创建统一玻璃容器与明暗外观，返回包裹内容的容器视图（#144 U-18）。
    @discardableResult
    private func present(content: NSView, size: NSSize, anchor: InputAnchor, kind: Kind, ignoresMouse: Bool) -> NSView {
        // 锚点所在屏；锚点不在任何屏幕上时按主屏放置。
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor.selection) } ?? NSScreen.screens[0]
        // 可用区域为锚点所在屏可见区与来源窗口的交集，气泡不越出来源窗口。
        let area = Self.availableArea(visible: screen.visibleFrame, window: anchor.window)
        let frame = Self.frame(size: size, anchor: anchor.selection, area: area)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = ignoresMouse
        NativeGlassFactory.applyAppearance(to: panel)
        let radius = kind == .progress ? AppConstants.inputProgressRadius : AppConstants.scrollHintRadius
        let container = NativeGlassFactory.makeGlassContainer(content: content, size: size, cornerRadius: radius)
        panel.contentView = container
        panel.orderFrontRegardless()
        self.panel = panel
        self.kind = kind
        return container
    }

    /// textWidth 为「翻译中…」单行文字宽；返回浮标尺寸：高固定，宽为左右内边距、转圈、间距与文字之和（取整点）。
    nonisolated static func progressSize(textWidth: CGFloat) -> NSSize {
        let width = AppConstants.inputProgressPaddingX * 2 + AppConstants.inputProgressSpinnerSize
            + AppConstants.inputProgressSpacing + textWidth
        return NSSize(width: width.rounded(.up), height: AppConstants.inputProgressHeight)
    }

    /// visible 为锚点所在屏可见区，window 为来源应用窗口矩形（可为 nil，均为 AppKit 坐标）；
    /// 返回二者的交集，没有窗口或交集为空时返回 visible。
    nonisolated static func availableArea(visible: NSRect, window: NSRect?) -> NSRect {
        guard let window else { return visible }
        let overlap = visible.intersection(window)
        return overlap.isEmpty ? visible : overlap
    }

    /// size 为气泡尺寸，anchor 为选中区域，area 为可用区域（均为 AppKit 坐标）；
    /// 返回锚点下方 8pt、放不下时上方 8pt、上下都放不下时贴可用区域底部，左边与锚点对齐并限制在可用区域内的整点位置。
    nonisolated static func frame(size: NSSize, anchor: NSRect, area: NSRect) -> NSRect {
        let gap = AppConstants.inputFailureGap
        let below = anchor.minY - gap - size.height
        let above = anchor.maxY + gap
        // 下方放得下用下方；否则上方放得下用上方；都放不下贴区域底部，再保证不超出区域顶部。
        let y: CGFloat
        if below >= area.minY {
            y = below
        } else if above + size.height <= area.maxY {
            y = above
        } else {
            y = min(area.minY, area.maxY - size.height)
        }
        let x = min(max(anchor.minX, area.minX), area.maxX - size.width)
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
}

/// 失败气泡内容视图：非激活面板首次点击即关闭气泡，鼠标悬停期间通知外层暂停自动消失（#144 用户意见 #1）。
private final class BubbleClickView: NSView {
    var onClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    /// 无参数；重建悬停追踪区域以适配气泡宽高，无返回值。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    /// event 为首次点击；非激活面板不先激活应用，返回 true 直接处理。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// event 为鼠标进入；暂停自动消失计时，无返回值。
    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    /// event 为鼠标离开；恢复并重新计时 2000ms，无返回值。
    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    /// event 为鼠标按下；关闭气泡，无返回值。
    override func mouseDown(with event: NSEvent) { onClick?() }
}
