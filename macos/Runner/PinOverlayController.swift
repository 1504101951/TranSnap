import AppKit

final class PinOverlayController {
    private var pins: [String: PinPanel] = [:]

    @discardableResult
    func pin(png: Data, origin: NSPoint) -> String? {
        let id = UUID().uuidString
        let targetScreen = NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main
        guard let panel = PinPanel(png: png, pinId: id, targetScreen: targetScreen, onClose: { [weak self] closedId in
            self?.pins.removeValue(forKey: closedId)
        }) else {
            return nil
        }
        var pinnedOrigin = origin
        if let visible = (targetScreen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 8, dy: 8) {
            let size = panel.frame.size
            let maxX = max(visible.minX, visible.maxX - size.width)
            let maxY = max(visible.minY, visible.maxY - size.height)
            pinnedOrigin.x = min(max(pinnedOrigin.x, visible.minX), maxX)
            pinnedOrigin.y = min(max(pinnedOrigin.y, visible.minY), maxY)
        }
        panel.setFrameOrigin(pinnedOrigin)
        pins[id] = panel
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        panel.orderFrontRegardless()
        return id
    }

    func closeAll() {
        let panels = Array(pins.values)
        pins.removeAll()
        for panel in panels {
            panel.closeSilently()
        }
    }

    var count: Int { pins.count }

    func isVisible(pinId: String) -> Bool {
        pins[pinId]?.isVisible == true
    }

    var firstPanel: PinPanel? { pins.values.first }
}

final class DraggablePinImageView: NSImageView {
    var onDoubleClick: (() -> Void)?
    private(set) var dragBeginCountForTesting = 0

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        dragBeginCountForTesting += 1
        window?.makeKey()
        window?.performDrag(with: event)
    }


}

final class PinPanel: NSPanel {
    private let rootView = PinHoverRootView()
    private let imageView = DraggablePinImageView()
    private let closeButton = PinHoverCloseButton()
    private let closeHandler: (String) -> Void
    private let pngData: Data
    let pinId: String
    private var baseSize: NSSize = .zero
    private var scale: CGFloat = 1

    init?(png: Data, pinId: String, targetScreen: NSScreen? = nil, onClose: @escaping (String) -> Void) {
        guard let image = NSImage(data: png),
              let rep = image.representations.first,
              rep.pixelsWide > 0,
              rep.pixelsHigh > 0 else {
            return nil
        }
        self.pinId = pinId
        self.closeHandler = onClose
        self.pngData = png
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovableByWindowBackground = true
        NativeGlassFactory.applyAppearance(to: self)

        let initialScreen = targetScreen ?? NSScreen.main
        let backing = max(initialScreen?.backingScaleFactor ?? 1, 1)
        image.size = NSSize(
            width: CGFloat(rep.pixelsWide) / backing,
            height: CGFloat(rep.pixelsHigh) / backing
        )
        baseSize = image.size
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.onDoubleClick = { [weak self] in self?.closeFromUserAction() }
        imageView.menu = buildContextMenu()

        closeButton.target = self
        closeButton.action = #selector(closeFromUserAction)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        rootView.wantsLayer = true
        rootView.onHoverChanged = { [weak self] hovering in
            self?.closeButton.isHidden = !hovering
        }
        rootView.addSubview(imageView)
        rootView.addSubview(closeButton)
        contentView = rootView
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: rootView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            closeButton.topAnchor.constraint(equalTo: rootView.topAnchor, constant: AppConstants.pinCloseButtonInset),
            closeButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -AppConstants.pinCloseButtonInset),
            closeButton.widthAnchor.constraint(equalToConstant: AppConstants.pinCloseButtonSize),
            closeButton.heightAnchor.constraint(equalToConstant: AppConstants.pinCloseButtonSize),
        ])
        setContentSize(clampedSize(for: baseSize, on: initialScreen))

        let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(onMagnify(_:)))
        imageView.addGestureRecognizer(magnify)
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu(title: "贴图")
        let copyItem = NSMenuItem(title: "复制图片", action: #selector(copyPinImage), keyEquivalent: "c")
        copyItem.target = self
        let resetItem = NSMenuItem(title: "重置 100% 大小", action: #selector(resetPinScale), keyEquivalent: "0")
        resetItem.target = self
        let closeItem = NSMenuItem(title: "关闭贴图", action: #selector(closeFromUserAction), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(copyItem)
        menu.addItem(resetItem)
        menu.addItem(.separator())
        menu.addItem(closeItem)
        return menu
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == AppConstants.escapeKeyCode {
            closeFromUserAction()
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command {
            if event.keyCode == 8 {
                copyPinImage()
                return
            }
            if event.keyCode == 29 {
                resetPinScale()
                return
            }
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        closeFromUserAction()
    }

    override func close() {
        closeHandler(pinId)
        super.close()
    }

    func closeSilently() {
        orderOut(nil)
        super.close()
    }

    @objc func copyPinImage() {
        _ = PNGPasteboard.write(pngData, to: .general)
    }

    @objc func resetPinScale() {
        applyScale(1)
    }

    @objc func closeFromUserAction() {
        close()
    }

    var imageViewForTesting: DraggablePinImageView { imageView }

    var closeButtonForTesting: NSButton { closeButton }

    func applyScaleForTesting(_ newScale: CGFloat) {
        applyScale(newScale)
    }

    var pinnedImagePixelSizeForTesting: NSSize {
        guard let image = imageView.image else { return .zero }
        if let rep = image.representations.first {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    @objc private func onMagnify(_ event: NSMagnificationGestureRecognizer) {
        guard event.state == .changed || event.state == .ended else { return }
        let nextScale = scale * (1 + event.magnification)
        event.magnification = 0
        applyScale(nextScale)
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        applyScale(scale * (delta > 0 ? 1.05 : 0.95))
    }

    private func applyScale(_ newScale: CGFloat) {
        scale = min(5, max(0.2, newScale))
        let targetScreen = screen ?? NSScreen.main
        let size = clampedSize(for: NSSize(width: baseSize.width * scale, height: baseSize.height * scale), on: targetScreen)
        let current = frame
        var next = NSRect(
            x: current.midX - size.width / 2,
            y: current.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        if let visible = targetScreen?.visibleFrame.insetBy(dx: 8, dy: 8) {
            let maxX = max(visible.minX, visible.maxX - size.width)
            let maxY = max(visible.minY, visible.maxY - size.height)
            next.origin.x = min(max(next.minX, visible.minX), maxX)
            next.origin.y = min(max(next.minY, visible.minY), maxY)
        }
        next.origin.x = next.origin.x.rounded()
        next.origin.y = next.origin.y.rounded()
        setFrame(next, display: true)
    }

    private func clampedSize(for size: NSSize, on targetScreen: NSScreen?) -> NSSize {
        let visible = (targetScreen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 16, dy: 16)
            ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let maxW = max(80, visible.width)
        let maxH = max(80, visible.height)
        let ratio = min(1, min(maxW / max(size.width, 1), maxH / max(size.height, 1)))
        return NSSize(width: max(40, (size.width * ratio).rounded()), height: max(40, (size.height * ratio).rounded()))
    }
}

private final class PinHoverRootView: NSView {
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

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}

private final class PinHoverCloseButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        wantsLayer = true
        layer?.cornerRadius = AppConstants.pinCloseButtonSize / 2
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        if let symbol = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭贴图") {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            image = symbol.withSymbolConfiguration(config)
        }
        contentTintColor = .white
        toolTip = "关闭贴图（Esc / 双击）"
        setAccessibilityLabel("关闭贴图")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PinHoverCloseButton requires programmatic initialization")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
