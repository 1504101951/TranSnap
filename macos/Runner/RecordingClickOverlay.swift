import AppKit
import QuartzCore

/// 录屏鼠标点击特效透明覆盖层（#143）：穿透鼠标、不抢焦点、不标记控制窗口标识，
/// 由 ScreenCaptureKit 原生采集进视频，并在暂停/停止/取消时立即释放监听与图层。
@MainActor
final class RecordingClickOverlay {
    private var panel: NSPanel?
    private var hostLayer: CALayer?
    private var windowFrame: NSRect = .zero
    private var backingScale: CGFloat = 2
    private var effect: RecordingClickEffect = .off
    private var rightDistinct = true
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var activePressLayers: [Int: [CALayer]] = [:]
    private var lastTrailPoints: [Int: CGPoint] = [:]

    private(set) var isRunning = false

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }

    /// preferences 为主偏好字典；解析并返回点击特效枚举与是否区分右键及拖动轨迹。
    static func resolvedConfig(preferences: [String: Any]) -> (effect: RecordingClickEffect, rightDistinct: Bool) {
        let raw = preferences[AppConstants.recordingClickEffectKey] as? String
        let effect = raw.flatMap(RecordingClickEffect.init(rawValue:)) ?? .off
        let rightDistinct = preferences[AppConstants.recordingClickRightDistinctKey] as? Bool ?? true
        return (effect, rightDistinct)
    }

    /// effect 为已选特效，isApplicationTarget 为是否为窗口（应用）录制；仅非应用录制且选用自定义光学特效时开启覆盖层。
    static func shouldRenderOverlay(effect: RecordingClickEffect, isApplicationTarget: Bool) -> Bool {
        !isApplicationTarget && effect != .off && effect != .system
    }

    /// event 为本地或全局鼠标事件；过滤本应用合成事件（SyntheticEvent.isMarked），返回是否应渲染特效。
    nonisolated static func shouldAcceptMonitorEvent(_ event: NSEvent) -> Bool {
        !SyntheticEvent.isMarked(event)
    }

    /// globalPoint 为 AppKit 屏幕点坐标，windowFrame 为录制窗口帧；位于录制区域内时返回层内局部坐标，否则返回 nil。
    static func localPoint(globalPoint: NSPoint, in windowFrame: NSRect) -> CGPoint? {
        guard !windowFrame.isEmpty, windowFrame.contains(globalPoint) else { return nil }
        return CGPoint(x: globalPoint.x - windowFrame.minX, y: globalPoint.y - windowFrame.minY)
    }

    /// type 为鼠标事件类型；返回是否属于右键事件。
    static func isRightClick(_ type: NSEvent.EventType) -> Bool {
        type == .rightMouseDown || type == .rightMouseDragged || type == .rightMouseUp
    }

    /// frame 为录制区间 AppKit 屏幕坐标，preferences 为偏好字典，isApplicationTarget 标记是否为应用录制；
    /// 满足条件时显示透明穿透特效窗口并挂载鼠标监听，无返回值。
    func start(frame: NSRect?, preferences: [String: Any], isApplicationTarget: Bool = false) {
        stop()
        let config = Self.resolvedConfig(preferences: preferences)
        guard let frame, !frame.isEmpty,
              Self.shouldRenderOverlay(effect: config.effect, isApplicationTarget: isApplicationTarget) else {
            return
        }
        effect = config.effect
        rightDistinct = config.rightDistinct
        windowFrame = frame

        let overlay = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // 不设置 captureControlWindowIdentifier，确保 ScreenCaptureKit 按正常内容采集入画（#143）。
        overlay.isReleasedWhenClosed = false
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.hidesOnDeactivate = false
        overlay.becomesKeyOnlyIfNeeded = false
        overlay.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.frame = NSRect(origin: .zero, size: frame.size)
        rootLayer.masksToBounds = true
        backingScale = overlay.backingScaleFactor
        rootLayer.contentsScale = backingScale
        view.layer = rootLayer
        overlay.contentView = view
        overlay.orderFrontRegardless()

        panel = overlay
        hostLayer = rootLayer
        isRunning = true

        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .rightMouseDown, .rightMouseDragged, .rightMouseUp,
        ]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard Self.shouldAcceptMonitorEvent(event) else { return event }
            let type = event.type
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleMouse(type: type, globalPoint: location)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard Self.shouldAcceptMonitorEvent(event) else { return }
            let type = event.type
            let location = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleMouse(type: type, globalPoint: location)
            }
        }
    }

    /// 无参数；卸载全部鼠标监听、清空图层并关闭透明覆盖窗口，无返回值。
    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        for layers in activePressLayers.values {
            for layer in layers { layer.removeFromSuperlayer() }
        }
        activePressLayers.removeAll()
        lastTrailPoints.removeAll()
        hostLayer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        hostLayer = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        windowFrame = .zero
        isRunning = false
    }

    /// type 为事件类型，globalPoint 为全局鼠标坐标；按当前特效样式驱动按下、拖动轨迹与释放动画。
    private func handleMouse(type: NSEvent.EventType, globalPoint: NSPoint) {
        guard isRunning, let rootLayer = hostLayer else { return }
        let right = Self.isRightClick(type)
        let buttonKey = right ? 2 : 0
        let distinctRight = right && rightDistinct

        switch type {
        case .leftMouseDown, .rightMouseDown:
            clearPressLayers(for: buttonKey)
            lastTrailPoints.removeValue(forKey: buttonKey)
            guard let point = Self.localPoint(globalPoint: globalPoint, in: windowFrame) else { return }
            lastTrailPoints[buttonKey] = point
            activePressLayers[buttonKey] = makePressLayers(at: point, isRight: distinctRight, in: rootLayer)

        case .leftMouseDragged, .rightMouseDragged:
            guard let point = Self.localPoint(globalPoint: globalPoint, in: windowFrame) else { return }
            if let layers = activePressLayers[buttonKey] {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for layer in layers { layer.position = point }
                CATransaction.commit()
            }
            if rightDistinct {
                if let last = lastTrailPoints[buttonKey] {
                    let distance = hypot(point.x - last.x, point.y - last.y)
                    if distance >= AppConstants.clickEffectTrailMinDistance {
                        lastTrailPoints[buttonKey] = point
                        emitTrailDot(at: point, isRight: distinctRight, in: rootLayer)
                    }
                } else {
                    lastTrailPoints[buttonKey] = point
                }
            }

        case .leftMouseUp, .rightMouseUp:
            clearPressLayers(for: buttonKey)
            lastTrailPoints.removeValue(forKey: buttonKey)
            guard let point = Self.localPoint(globalPoint: globalPoint, in: windowFrame) else { return }
            emitReleaseEffect(at: point, isRight: distinctRight, in: rootLayer)

        default:
            break
        }
    }

    /// buttonKey 标识左键(0)或右键(2)；移除尚未释放的按下态图层，避免失焦或越界残留。
    private func clearPressLayers(for buttonKey: Int) {
        guard let layers = activePressLayers.removeValue(forKey: buttonKey) else { return }
        for layer in layers {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
    }

    /// isRight 表示是否为区分后的右键；返回主高亮色及双对比衬线色。
    private func colors(isRight: Bool) -> (accent: NSColor, contrastDark: NSColor, contrastLight: NSColor) {
        let accent = isRight ? AppConstants.clickEffectRightColor : AppConstants.clickEffectLeftColor
        return (
            accent,
            NSColor.black.withAlphaComponent(0.32),
            NSColor.white.withAlphaComponent(0.92)
        )
    }

    /// point 为层内点坐标，isRight 为右键区分标记，rootLayer 为宿主根图层；创建按下收缩提示图层并返回以便跟随或清除。
    private func makePressLayers(at point: CGPoint, isRight: Bool, in rootLayer: CALayer) -> [CALayer] {
        let palette = colors(isRight: isRight)
        var created: [CALayer] = []
        let startR = effect == .minimal ? AppConstants.clickEffectMinimalStartRadius : AppConstants.clickEffectPressRadius
        let endR = effect == .prism ? 7.0 : (effect == .minimal ? 10.5 : AppConstants.clickEffectBaseRadius)

        let contrastRing = makeCircleShape(at: point, radius: startR, stroke: palette.contrastDark, lineWidth: 2.6, dashed: isRight && effect == .minimal)
        let mainRing = makeCircleShape(at: point, radius: startR, stroke: effect == .minimal ? palette.contrastLight : palette.accent, lineWidth: 1.6, dashed: isRight && effect == .minimal)
        if effect == .spotlight || effect == .liquid {
            mainRing.fillColor = palette.accent.withAlphaComponent(effect == .spotlight ? 0.30 : 0.22).cgColor
        }
        rootLayer.addSublayer(contrastRing)
        rootLayer.addSublayer(mainRing)
        created.append(contentsOf: [contrastRing, mainRing])

        // 按下平滑微缩蓄力。
        let startPath = circlePath(radius: startR)
        let endPath = circlePath(radius: endR)
        for layer in [contrastRing, mainRing] {
            let anim = CABasicAnimation(keyPath: "path")
            anim.fromValue = startPath
            anim.toValue = endPath
            anim.duration = 0.14
            anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            layer.add(anim, forKey: "pressContract")
        }
        return created
    }

    /// point 为轨迹采样点，isRight 为右键标记，rootLayer 为宿主图层；绘制按住拖动期间的柔和淡出微光点。
    private func emitTrailDot(at point: CGPoint, isRight: Bool, in rootLayer: CALayer) {
        let palette = colors(isRight: isRight)
        let r: CGFloat = effect == .liquid ? 5.0 : 4.0
        let dot = makeCircleShape(at: point, radius: r, stroke: palette.contrastDark, lineWidth: 0.8)
        dot.fillColor = palette.accent.withAlphaComponent(0.36).cgColor
        rootLayer.addSublayer(dot)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak dot] in dot?.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0.0
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1.0
        shrink.toValue = 0.4
        let group = CAAnimationGroup()
        group.animations = [fade, shrink]
        group.duration = AppConstants.clickEffectTrailDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        dot.add(group, forKey: "trailFade")
        CATransaction.commit()
    }

    /// point 为松开点坐标，isRight 为右键标记，rootLayer 为宿主图层；按所选光学特效生成完整释放动画并自动销毁图层。
    private func emitReleaseEffect(at point: CGPoint, isRight: Bool, in rootLayer: CALayer) {
        switch effect {
        case .off, .system:
            break
        case .optical:
            emitOptical(at: point, isRight: isRight, in: rootLayer)
        case .liquid:
            emitLiquid(at: point, isRight: isRight, in: rootLayer)
        case .spotlight:
            emitSpotlight(at: point, isRight: isRight, in: rootLayer)
        case .prism:
            emitPrism(at: point, isRight: isRight, in: rootLayer)
        case .minimal:
            emitMinimal(at: point, isRight: isRight, in: rootLayer)
        }
    }

    /// 1. 光学涟漪：主水光双对比环 + 延迟回声细环。
    private func emitOptical(at point: CGPoint, isRight: Bool, in rootLayer: CALayer) {
        let palette = colors(isRight: isRight)
        let duration = AppConstants.clickEffectDuration
        addExpandingRing(
            at: point, from: AppConstants.clickEffectBaseRadius, to: AppConstants.clickEffectExpandRadius,
            stroke: palette.contrastDark, fromWidth: 2.8, toWidth: 1.5,
            fromOpacity: 0.34, duration: duration, dashed: isRight, in: rootLayer
        )
        addExpandingRing(
            at: point, from: AppConstants.clickEffectBaseRadius, to: AppConstants.clickEffectExpandRadius,
            stroke: palette.accent, fromWidth: AppConstants.clickEffectStrokeWidth, toWidth: 1.0,
            fromOpacity: 0.92, duration: duration, dashed: isRight, in: rootLayer
        )
        addExpandingRing(
            at: point, from: 6, to: AppConstants.clickEffectExpandRadius + 8,
            stroke: palette.accent, fromWidth: 1.1, toWidth: 0.8,
            fromOpacity: 0.48, duration: duration, delay: 0.11, in: rootLayer
        )
    }

    /// 2. 液态弹波：玻璃微珠弹性过冲 + 外围折射水波环。
    private func emitLiquid(at point: CGPoint, isRight: Bool, in rootLayer: CALayer) {
        let palette = colors(isRight: isRight)
        let duration = AppConstants.clickEffectDuration
        let droplet = makeCircleShape(at: point, radius: 11, stroke: palette.accent.withAlphaComponent(0.78), lineWidth: 1.3)
        droplet.fillColor = palette.accent.withAlphaComponent(0.22).cgColor
        rootLayer.addSublayer(droplet)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak droplet] in droplet?.removeFromSuperlayer() }
        let bounce = CASpringAnimation(keyPath: "transform.scale")
        bounce.fromValue = 0.82
        bounce.toValue = 1.95
        bounce.stiffness = 280
        bounce.damping = 13
        bounce.mass = 1
        bounce.duration = duration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.95
        fade.toValue = 0.0
        fade.duration = duration
        let group = CAAnimationGroup()
        group.animations = [bounce, fade]
        group.duration = duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        droplet.add(group, forKey: "liquidDrop")
        CATransaction.commit()

        addExpandingRing(
            at: point, from: 10, to: AppConstants.clickEffectExpandRadius + 6,
            stroke: palette.accent, fromWidth: isRight ? 1.8 : 1.25, toWidth: 0.8,
            fromOpacity: 0.62, duration: duration, in: rootLayer
        )
    }

    /// 3. 聚光微点：柔和光片绽放扩散 + 右键外弧提示。
    private func emitSpotlight(at point: CGPoint, isRight: Bool, in rootLayer: CALayer) {
        let palette = colors(isRight: isRight)
        let duration = AppConstants.clickEffectDuration
        let disc = makeCircleShape(at: point, radius: 9, stroke: palette.accent.withAlphaComponent(0.58), lineWidth: 1.3)
        disc.fillColor = palette.accent.withAlphaComponent(0.26).cgColor
        rootLayer.addSublayer(disc)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak disc] in disc?.removeFromSuperlayer() }
        let pathAnim = CABasicAnimation(keyPath: "path")
        pathAnim.fromValue = circlePath(radius: 9)
        pathAnim.toValue = circlePath(radius: AppConstants.clickEffectExpandRadius)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [pathAnim, fade]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        disc.add(group, forKey: "spotlightBloom")
        CATransaction.commit()

        if isRight {
            let arc = CAShapeLayer()
            arc.position = point
            arc.bounds = CGRect(x: -44, y: -44, width: 88, height: 88)
            arc.contentsScale = backingScale
            arc.fillColor = nil
            arc.strokeColor = palette.accent.withAlphaComponent(0.85).cgColor
            arc.lineWidth = 2.2
            arc.lineCap = .round
            let startPath = CGMutablePath()
            startPath.addArc(center: .zero, radius: 12, startAngle: -.pi * 0.35, endAngle: .pi * 0.35, clockwise: false)
            let endPath = CGMutablePath()
            endPath.addArc(center: .zero, radius: AppConstants.clickEffectExpandRadius + 3, startAngle: -.pi * 0.35, endAngle: .pi * 0.35, clockwise: false)
            arc.path = startPath
            rootLayer.addSublayer(arc)

            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak arc] in arc?.removeFromSuperlayer() }
            let pAnim = CABasicAnimation(keyPath: "path")
            pAnim.fromValue = startPath
            pAnim.toValue = endPath
            let oAnim = CABasicAnimation(keyPath: "opacity")
            oAnim.fromValue = 0.9
            oAnim.toValue = 0.0
            let grp = CAAnimationGroup()
            grp.animations = [pAnim, oAnim]
            grp.duration = duration
            grp.timingFunction = CAMediaTimingFunction(name: .easeOut)
            grp.fillMode = .forwards
            grp.isRemovedOnCompletion = false
            arc.add(grp, forKey: "spotlightRightArc")
            CATransaction.commit()
        }
    }

    /// 4. 星芒微烁：8 道精密光学短射线 + 中心细微环。
    private func emitPrism(at point: CGPoint, isRight: Bool, in rootLayer: CALayer) {
        let palette = colors(isRight: isRight)
        let duration = AppConstants.clickEffectDuration
        addExpandingRing(
            at: point, from: 5, to: 19,
            stroke: palette.accent, fromWidth: 1.2, toWidth: 0.7,
            fromOpacity: 0.65, duration: duration * 0.65, in: rootLayer
        )
        let count = 8
        let rotOffset: CGFloat = isRight ? .pi / 8 : 0
        let startPath = CGMutablePath()
        let endPath = CGMutablePath()
        for idx in 0..<count {
            let angle = rotOffset + CGFloat(idx) * (.pi * 2 / CGFloat(count))
            let lenScale: CGFloat = (isRight && idx % 2 == 0) ? 1.25 : 1.0
            let c = cos(angle)
            let s = sin(angle)
            startPath.move(to: CGPoint(x: c * 7, y: s * 7))
            startPath.addLine(to: CGPoint(x: c * 14 * lenScale, y: s * 14 * lenScale))
            endPath.move(to: CGPoint(x: c * 28, y: s * 28))
            endPath.addLine(to: CGPoint(x: c * AppConstants.clickEffectExpandRadius * lenScale,
                                      y: s * AppConstants.clickEffectExpandRadius * lenScale))
        }
        for (color, width) in [(palette.contrastDark, CGFloat(2.5)), (palette.accent, CGFloat(1.5))] {
            let rays = CAShapeLayer()
            rays.position = point
            rays.bounds = CGRect(x: -50, y: -50, width: 100, height: 100)
            rays.contentsScale = backingScale
            rays.fillColor = nil
            rays.strokeColor = color.cgColor
            rays.lineWidth = width
            rays.lineCap = .round
            rays.path = startPath
            rootLayer.addSublayer(rays)

            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak rays] in rays?.removeFromSuperlayer() }
            let pathAnim = CABasicAnimation(keyPath: "path")
            pathAnim.fromValue = startPath
            pathAnim.toValue = endPath
            let opAnim = CABasicAnimation(keyPath: "opacity")
            opAnim.fromValue = 0.95
            opAnim.toValue = 0.0
            let group = CAAnimationGroup()
            group.animations = [pathAnim, opAnim]
            group.duration = duration
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            rays.add(group, forKey: "prismRays")
            CATransaction.commit()
        }
    }

    /// 5. 极简双对比环：原生黑白圆环的丝滑缓动升级版。
    private func emitMinimal(at point: CGPoint, isRight: Bool, in rootLayer: CALayer) {
        let palette = colors(isRight: isRight)
        let duration = AppConstants.clickEffectMinimalDuration
        addExpandingRing(
            at: point, from: AppConstants.clickEffectMinimalStartRadius + 1.1, to: AppConstants.clickEffectMinimalEndRadius + 1.1,
            stroke: palette.contrastDark, fromWidth: AppConstants.clickEffectMinimalStrokeWidth + 1.2, toWidth: 1.8,
            fromOpacity: 0.62, duration: duration, dashed: isRight, in: rootLayer
        )
        addExpandingRing(
            at: point, from: AppConstants.clickEffectMinimalStartRadius, to: AppConstants.clickEffectMinimalEndRadius,
            stroke: palette.contrastLight, fromWidth: AppConstants.clickEffectMinimalStrokeWidth, toWidth: 1.0,
            fromOpacity: 0.95, duration: duration, dashed: isRight, in: rootLayer
        )
    }

    /// 共享扩散圆环动画构造器；动画完成后自动从父图层移除。
    private func addExpandingRing(
        at point: CGPoint,
        from startR: CGFloat,
        to endR: CGFloat,
        stroke: NSColor,
        fromWidth: CGFloat,
        toWidth: CGFloat,
        fromOpacity: Float,
        duration: CFTimeInterval,
        delay: CFTimeInterval = 0,
        dashed: Bool = false,
        in rootLayer: CALayer
    ) {
        let ring = makeCircleShape(at: point, radius: startR, stroke: stroke, lineWidth: fromWidth, dashed: dashed)
        ring.opacity = delay > 0 ? 0 : fromOpacity
        rootLayer.addSublayer(ring)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak ring] in ring?.removeFromSuperlayer() }
        let pathAnim = CABasicAnimation(keyPath: "path")
        pathAnim.fromValue = circlePath(radius: startR)
        pathAnim.toValue = circlePath(radius: endR)
        let widthAnim = CABasicAnimation(keyPath: "lineWidth")
        widthAnim.fromValue = fromWidth
        widthAnim.toValue = toWidth
        let opAnim = CABasicAnimation(keyPath: "opacity")
        opAnim.fromValue = fromOpacity
        opAnim.toValue = Float(0)

        let group = CAAnimationGroup()
        group.animations = [pathAnim, widthAnim, opAnim]
        group.duration = duration
        if delay > 0 {
            group.beginTime = CACurrentMediaTime() + delay
        }
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        ring.add(group, forKey: "ringExpand")
        CATransaction.commit()
    }

    /// point 为中心点，radius 为初始半径，stroke 为描边色，lineWidth 为线宽，dashed 为是否虚线；构造清晰圆形 CAShapeLayer。
    private func makeCircleShape(at point: CGPoint, radius: CGFloat, stroke: NSColor, lineWidth: CGFloat, dashed: Bool = false) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.position = point
        let side = (AppConstants.clickEffectExpandRadius + 16) * 2
        layer.bounds = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
        layer.contentsScale = backingScale
        layer.fillColor = nil
        layer.strokeColor = stroke.cgColor
        layer.lineWidth = lineWidth
        layer.lineCap = .round
        if dashed { layer.lineDashPattern = [4, 3] }
        layer.path = circlePath(radius: radius)
        return layer
    }

    /// radius 为圆半径；返回以原点为中心的椭圆路径。
    private func circlePath(radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
    }
}
