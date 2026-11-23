import AppKit

/// 独立置顶贴图；不抢来源 App 焦点，生命周期与截图编辑会话、选区译文分离。
final class PinOverlayController {
    private var pins: [String: PinPanel] = [:]

    /// png 为最终合成图，origin 为选区左下角的 AppKit 屏幕坐标。
    /// 返回贴图 id；当 PNG 解码失败或像素为空时安全取消创建并返回 nil，避免崩溃（#144 U-29）。
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

    /// 无参数；关闭全部贴图，供应用退出时释放窗口。
    func closeAll() {
        // 先取出快照再清空，避免 close 回调在遍历时修改字典。
        let panels = Array(pins.values)
        pins.removeAll()
        for panel in panels {
            panel.closeSilently()
        }
    }

    /// 无参数；返回当前贴图数量，供测试断言生命周期。
    var count: Int { pins.count }

    /// pinId 是否仍显示；用于断言关闭与选区会话互不影响。
    func isVisible(pinId: String) -> Bool {
        pins[pinId]?.isVisible == true
    }

    /// 无参数；返回首个贴图窗口（测试用），不存在则为 nil。
    var firstPanel: PinPanel? { pins.values.first }
}

/// 图片层接管拖动：NSImageView 是控件，isMovableByWindowBackground 对其无效。
final class DraggablePinImageView: NSImageView {
    var onDoubleClick: (() -> Void)?
    /// 测试计数：每次进入单击拖动路径 +1，证明 mouseDown→performDrag 已接线。
    private(set) var dragBeginCountForTesting = 0

    /// 无参数；图片层不抢按键，Esc 才能落到贴图窗口。
    override var acceptsFirstResponder: Bool { false }

    /// event 为首次点击；非活动来源下也直接交给图片，避免首次点击仅激活窗口。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// event 为左键按下；单击拖动窗口，双击关闭。
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        dragBeginCountForTesting += 1
        // performDrag自行消费松开事件；拖前明确选中此贴图，让Esc可靠作用于它。
        window?.makeKey()
        window?.performDrag(with: event)
    }


}

/// 无边框非激活贴图窗；可拖动、捏合与 Command+滚轮中心缩放，悬停提供轻量关闭钮与右键上下文菜单（#144 U-29）。
final class PinPanel: NSPanel {
    private let rootView = PinHoverRootView()
    private let imageView = DraggablePinImageView()
    private let closeButton = PinHoverCloseButton()
    private let closeHandler: (String) -> Void
    private let pngData: Data
    let pinId: String
    private var baseSize: NSSize = .zero
    private var scale: CGFloat = 1

    /// png 为贴图像素，pinId 标识此窗，targetScreen 为贴出位置所在显示器（空时回退主屏），onClose 在关闭时回传 id。
    /// 当 PNG 解码失败或有效像素尺寸 <= 0 时返回 nil，避免主进程崩溃（#144 U-29）。
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
        // 图片层自行 performDrag；保留该标志仅作无控件空隙的兜底。
        isMovableByWindowBackground = true
        NativeGlassFactory.applyAppearance(to: self)

        // Dart 重编码没有 DPI；优先使用目标屏倍率把物理像素换算为逻辑点（#144 U-29）。
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

        // 关闭钮静息隐藏、仅悬停浮现，既不遮挡内容又保证可发现性与 24×24pt 命中区（#144 U-29）。
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

    /// 无参数；构造贴图标准右键菜单（复制图片、重置 100% 大小、关闭贴图），返回配置好的 NSMenu。
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

    /// event 为按键；Esc 关闭当前贴图，Command+C 复制图片，Command+0 重置 100% 大小，无返回值（#144 U-29）。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == AppConstants.escapeKeyCode {
            closeFromUserAction()
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command {
            if event.keyCode == 8 { // kVK_ANSI_C
                copyPinImage()
                return
            }
            if event.keyCode == 29 { // kVK_ANSI_0
                resetPinScale()
                return
            }
        }
        super.keyDown(with: event)
    }

    /// sender 为菜单/系统取消动作；Esc 的标准响应路径，与 keyDown 同源关闭。
    override func cancelOperation(_ sender: Any?) {
        closeFromUserAction()
    }

    /// 无参数；关闭并通知控制器移除，不改剪贴板/文件。
    override func close() {
        closeHandler(pinId)
        super.close()
    }

    /// 无参数；控制器批量关闭时使用，避免回调再次改字典。
    func closeSilently() {
        orderOut(nil)
        super.close()
    }

    /// 无参数；将贴图 PNG 数据写入系统剪贴板，供右键菜单或 Command+C 调用，无返回值（#144 U-29）。
    @objc func copyPinImage() {
        _ = PNGPasteboard.write(pngData, to: .general)
    }

    /// 无参数；将贴图以当前中心点恢复为 100% 原始尺寸并夹紧可见屏幕，无返回值（#144 U-29）。
    @objc func resetPinScale() {
        applyScale(1)
    }

    /// 无参数；用户按Escape、双击图片或点击悬停关闭钮时关闭此贴图。
    @objc func closeFromUserAction() {
        close()
    }

    /// 无参数；返回可拖动图片层，供测试发送 mouseDown。
    var imageViewForTesting: DraggablePinImageView { imageView }

    /// 无参数；返回悬停关闭按钮，供测试验证静息态隐藏与可访问尺寸（#144 U-29）。
    var closeButtonForTesting: NSButton { closeButton }

    /// newScale 为目标倍率；供测试直接触发中心缩放并验证边界夹紧（#144 U-29）。
    func applyScaleForTesting(_ newScale: CGFloat) {
        applyScale(newScale)
    }

    /// 无参数；返回贴图 NSImage 像素尺寸，供断言 pinScreenshot 消费的是合成 bytes。
    var pinnedImagePixelSizeForTesting: NSSize {
        guard let image = imageView.image else { return .zero }
        // representations 优先取位图像素；否则回退逻辑 size。
        if let rep = image.representations.first {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    /// event 为捏合手势；委托中心锚点缩放方法，限制在当前屏可见范围内，无返回值。
    @objc private func onMagnify(_ event: NSMagnificationGestureRecognizer) {
        guard event.state == .changed || event.state == .ended else { return }
        let nextScale = scale * (1 + event.magnification)
        event.magnification = 0
        applyScale(nextScale)
    }

    /// event 为滚轮；Command+滚轮同样走中心锚点缩放与屏幕夹紧，避免顶出屏外（#144 U-29）。
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        applyScale(scale * (delta > 0 ? 1.05 : 0.95))
    }

    /// newScale 为目标缩放倍率；围绕当前窗口中心按倍率更新尺寸，并将结果严格夹紧在贴图所在显示器可见区内（#144 U-29）。
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

    /// size 为期望内容尺寸，targetScreen 为所在显示器（为空回退主屏）；限制最大不超过该显示器可见区域（#144 U-29）。
    private func clampedSize(for size: NSSize, on targetScreen: NSScreen?) -> NSSize {
        let visible = (targetScreen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 16, dy: 16)
            ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let maxW = max(80, visible.width)
        let maxH = max(80, visible.height)
        let ratio = min(1, min(maxW / max(size.width, 1), maxH / max(size.height, 1)))
        return NSSize(width: max(40, (size.width * ratio).rounded()), height: max(40, (size.height * ratio).rounded()))
    }
}

/// 监听整张贴图鼠标移入移出，控制关闭按钮仅在悬停时可见。
private final class PinHoverRootView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    /// 无参数；贴图缩放后重建追踪区域，无返回值。
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

/// 贴图右上角半透明轻量关闭按钮；非激活状态下支持首次点击直接关闭。
private final class PinHoverCloseButton: NSButton {
    /// frameRect 为按钮边界；初始化半透明深色圆形底与高对比 × 符号。
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

    /// event 为首次点击；非激活面板不先激活应用，返回 true 直接响应关闭。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
