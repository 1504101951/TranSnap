import AppKit
import FlutterMacOS

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
    private let tooltip = OverlayTooltipBubble()

    init() {
        panel = TranslationPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
        panel.contentViewController = host
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            self.dragStartEvent = event.type == .leftMouseDown && event.window === self.panel ? event : nil
            return event
        }
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    func contains(_ point: NSPoint) -> Bool {
        panel.isVisible && panel.frame.contains(point)
    }

    func attachFlutter(_ controller: FlutterViewController) {
        NativeGlassFactory.applyAppearance(to: panel)
        controller.mouseTrackingMode = .always
        host.embed(controller)
    }

    static func cornerRadius(for size: NSSize) -> CGFloat {
        size.height <= AppConstants.overlayTriggerMaxHeight
            ? AppConstants.overlayTriggerCornerRadius
            : AppConstants.overlayCardCornerRadius
    }

    func show(at point: NSPoint, size: NSSize, sessionId: String) {
        tooltip.hide()
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

    func hide(sessionId: String) {
        guard currentSessionId == sessionId else { return }
        tooltip.hide()
        currentSessionId = nil
        dragStartEvent = nil
        panel.alphaValue = 1
        panel.orderOut(nil)
    }

    func resize(sessionId: String, size: NSSize) {
        guard currentSessionId == sessionId, panel.frame.size != size else { return }
        tooltip.hide()
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

    func setCaptureHidden(_ hidden: Bool) {
        captureHidden = hidden
        if hidden {
            tooltip.hide()
            capturedSessionId = panel.isVisible ? currentSessionId : nil
            panel.orderOut(nil)
        } else {
            if let capturedSessionId, capturedSessionId == currentSessionId { panel.orderFrontRegardless() }
            capturedSessionId = nil
        }
    }

    func drag(sessionId: String) {
        guard currentSessionId == sessionId, let event = dragStartEvent,
              NSEvent.pressedMouseButtons & 1 != 0 else { return }
        tooltip.hide()
        dragStartEvent = nil
        panel.performDrag(with: event)
    }

    func showTooltip(sessionId: String, message: String, anchor: NSRect, preferAbove: Bool) {
        guard currentSessionId == sessionId, panel.isVisible else { return }
        let screenAnchor = NSRect(
            x: panel.frame.minX + anchor.origin.x,
            y: panel.frame.maxY - anchor.origin.y - anchor.height,
            width: anchor.width,
            height: anchor.height
        )
        let screenRect = (panel.screen ?? NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main)?.visibleFrame
            ?? screenAnchor
        tooltip.show(message: message, anchor: screenAnchor, screen: screenRect, preferAbove: preferAbove)
    }

    func hideTooltip() {
        tooltip.hide()
    }
}

final class OverlayTooltipBubble {
    private lazy var label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byClipping
        return label
    }()

    private lazy var bubble: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.addSubview(label)
        return view
    }()

    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.contentView = bubble
        return panel
    }()

    func show(message: String, anchor: NSRect, screen: NSRect, preferAbove: Bool) {
        NativeGlassFactory.applyAppearance(to: panel)
        let dark = panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        bubble.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.898, green: 0.898, blue: 0.918, alpha: 1) : NSColor(srgbRed: 0.173, green: 0.173, blue: 0.180, alpha: 1)).cgColor
        label.textColor = dark ? NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1) : .white
        label.font = AppFonts.font(.ui, size: 12)
        label.stringValue = message
        label.sizeToFit()
        let size = NSSize(
            width: (label.frame.width + 16).rounded(.up),
            height: (label.frame.height + 8).rounded(.up)
        )
        label.frame.origin = NSPoint(
            x: ((size.width - label.frame.width) / 2).rounded(),
            y: ((size.height - label.frame.height) / 2).rounded()
        )
        panel.setFrame(Self.frame(size: size, anchor: anchor, screen: screen, preferAbove: preferAbove), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    nonisolated static func frame(size: NSSize, anchor: NSRect, screen: NSRect, preferAbove: Bool) -> NSRect {
        let area = screen.insetBy(dx: 6, dy: 6)
        let gap: CGFloat = 6
        let above = anchor.maxY + gap
        let below = anchor.minY - gap - size.height
        let y: CGFloat
        if preferAbove {
            y = above + size.height <= area.maxY
                ? above
                : max(area.minY, below)
        } else {
            y = below >= area.minY
                ? below
                : min(area.maxY - size.height, above)
        }
        let centeredX = anchor.midX - size.width / 2
        let maxX = max(area.minX, area.maxX - size.width)
        let x = min(max(centeredX, area.minX), maxX)
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
}

final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayHostViewController: NSViewController {
    private var cornerRadius = AppConstants.overlayCardCornerRadius

    override func loadView() {
        view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
    }

    func setCornerRadius(_ radius: CGFloat) {
        cornerRadius = radius
        guard isViewLoaded else { return }
        view.layer?.cornerRadius = radius
    }

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

@MainActor
final class InputStatusBubble {
    static let shared = InputStatusBubble()

    private enum Kind { case progress, failure }

    private var panel: NSPanel?
    private var kind: Kind?
    private var generation = 0

    func showProgress(anchor: InputAnchor) {
        close()
        let current = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(AppConstants.inputProgressDelayMs))
            guard let self, self.generation == current else { return }
            let label = NSTextField(labelWithString: AppConstants.inputProgressText)
            label.font = AppFonts.font(.ui, size: AppConstants.inputProgressFontSize)
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
            self.present(content: content, size: size, anchor: anchor, kind: .progress, ignoresMouse: true)
        }
    }

    func showFailure(_ message: String, anchor: InputAnchor) {
        close()
        let padding = AppConstants.scrollHintPadding
        let iconSize = AppConstants.inputFailureIconSize
        let iconSpacing = AppConstants.inputFailureIconSpacing
        let maxTextWidth = AppConstants.scrollHintMaxWidth - padding.width * 2 - iconSize - iconSpacing
        let styled = NSMutableAttributedString(attributedString: CaptureShadeView.hintText(message, isError: true))
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 18
        paragraph.maximumLineHeight = 18
        paragraph.alignment = .left
        styled.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: styled.length))

        let label = NSTextField(wrappingLabelWithString: message)
        label.attributedStringValue = styled
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
                self.generation += 1
            } else {
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

    private func scheduleFailureDismiss() {
        generation += 1
        let current = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(AppConstants.inputFailureDurationMs))
            guard let self, self.generation == current else { return }
            self.close()
        }
    }

    func close() {
        generation += 1
        panel?.orderOut(nil)
        panel = nil
        kind = nil
    }

    func closeProgress() {
        if kind == .progress || kind == nil { close() }
    }

    @discardableResult
    private func present(content: NSView, size: NSSize, anchor: InputAnchor, kind: Kind, ignoresMouse: Bool) -> NSView {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor.selection) } ?? NSScreen.screens[0]
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

    nonisolated static func progressSize(textWidth: CGFloat) -> NSSize {
        let width = AppConstants.inputProgressPaddingX * 2 + AppConstants.inputProgressSpinnerSize
            + AppConstants.inputProgressSpacing + textWidth
        return NSSize(width: width.rounded(.up), height: AppConstants.inputProgressHeight)
    }

    nonisolated static func availableArea(visible: NSRect, window: NSRect?) -> NSRect {
        guard let window else { return visible }
        let overlap = visible.intersection(window)
        return overlap.isEmpty ? visible : overlap
    }

    nonisolated static func frame(size: NSSize, anchor: NSRect, area: NSRect) -> NSRect {
        let gap = AppConstants.inputFailureGap
        let below = anchor.minY - gap - size.height
        let above = anchor.maxY + gap
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

private final class BubbleClickView: NSView {
    var onClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
