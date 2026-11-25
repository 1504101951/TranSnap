import AppKit
import QuartzCore

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

    var isReduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private(set) var isRunning = false

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }

    static func resolvedConfig(preferences: [String: Any]) -> (effect: RecordingClickEffect, rightDistinct: Bool) {
        let raw = preferences[AppConstants.recordingClickEffectKey] as? String
        let effect = raw.flatMap(RecordingClickEffect.init(rawValue:)) ?? .off
        let rightDistinct = preferences[AppConstants.recordingClickRightDistinctKey] as? Bool ?? true
        return (effect, rightDistinct)
    }

    static func shouldRenderOverlay(effect: RecordingClickEffect, isApplicationTarget: Bool) -> Bool {
        !isApplicationTarget && effect != .off && effect != .system
    }

    nonisolated static func shouldAcceptMonitorEvent(_ event: NSEvent) -> Bool {
        !SyntheticEvent.isMarked(event)
    }

    static func localPoint(globalPoint: NSPoint, in windowFrame: NSRect) -> CGPoint? {
        guard !windowFrame.isEmpty, windowFrame.contains(globalPoint) else { return nil }
        return CGPoint(x: globalPoint.x - windowFrame.minX, y: globalPoint.y - windowFrame.minY)
    }

    static func isRightClick(_ type: NSEvent.EventType) -> Bool {
        type == .rightMouseDown || type == .rightMouseDragged || type == .rightMouseUp
    }

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

    private func screenScale(for globalPoint: NSPoint) -> CGFloat {
        let matched = NSScreen.screens.first { $0.frame.contains(globalPoint) }?.backingScaleFactor
        return max(1, matched ?? panel?.backingScaleFactor ?? backingScale)
    }

    private func handleMouse(type: NSEvent.EventType, globalPoint: NSPoint) {
        guard isRunning, let rootLayer = hostLayer else { return }
        backingScale = screenScale(for: globalPoint)
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
            if rightDistinct && !isReduceMotion() {
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

    private func clearPressLayers(for buttonKey: Int) {
        guard let layers = activePressLayers.removeValue(forKey: buttonKey) else { return }
        for layer in layers {
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
    }

    private func colors(isRight: Bool) -> (accent: NSColor, contrastDark: NSColor, contrastLight: NSColor) {
        let accent = isRight ? AppConstants.clickEffectRightColor : AppConstants.clickEffectLeftColor
        return (
            accent,
            NSColor.black.withAlphaComponent(0.55),
            NSColor.white.withAlphaComponent(0.92)
        )
    }

    private func makePressLayers(at point: CGPoint, isRight: Bool, in rootLayer: CALayer) -> [CALayer] {
        let palette = colors(isRight: isRight)
        var created: [CALayer] = []
        let startR = effect == .minimal ? AppConstants.clickEffectMinimalStartRadius : AppConstants.clickEffectPressRadius
        let endR = effect == .prism ? 7.0 : (effect == .minimal ? 10.5 : AppConstants.clickEffectBaseRadius)
        let reduceMotion = isReduceMotion()
        let initialR = reduceMotion ? endR : startR

        let contrastRing = makeCircleShape(at: point, radius: initialR, stroke: palette.contrastDark, lineWidth: 2.6, dashed: isRight && effect == .minimal)
        let mainRing = makeCircleShape(at: point, radius: initialR, stroke: effect == .minimal ? palette.contrastLight : palette.accent, lineWidth: 1.6, dashed: isRight && effect == .minimal)
        if effect == .spotlight || effect == .liquid {
            mainRing.fillColor = palette.accent.withAlphaComponent(effect == .spotlight ? 0.30 : 0.22).cgColor
        }
        rootLayer.addSublayer(contrastRing)
        rootLayer.addSublayer(mainRing)
        created.append(contentsOf: [contrastRing, mainRing])

        guard !reduceMotion else { return created }

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

    private func emitReleaseEffect(at point: CGPoint, isRight: Bool, in rootLayer: CALayer) {
        guard effect != .off, effect != .system else { return }
        if isReduceMotion() {
            emitReducedMotionRelease(at: point, isRight: isRight, in: rootLayer)
            return
        }
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

    private func emitReducedMotionRelease(at point: CGPoint, isRight: Bool, in rootLayer: CALayer) {
        let palette = colors(isRight: isRight)
        let radius: CGFloat = 18
        let outer = makeCircleShape(at: point, radius: radius, stroke: palette.contrastDark, lineWidth: 2.8, dashed: isRight)
        let innerColor = effect == .minimal ? palette.contrastLight : palette.accent
        let inner = makeCircleShape(at: point, radius: radius, stroke: innerColor, lineWidth: 1.8, dashed: isRight)
        if effect == .spotlight || effect == .liquid {
            inner.fillColor = palette.accent.withAlphaComponent(0.18).cgColor
        }
        rootLayer.addSublayer(outer)
        rootLayer.addSublayer(inner)
        for layer in [outer, inner] {
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak layer] in layer?.removeFromSuperlayer() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.9
            fade.toValue = 0.0
            fade.duration = 0.28
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            layer.add(fade, forKey: "reducedFade")
            CATransaction.commit()
        }
    }

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
            stroke: palette.contrastDark, fromWidth: isRight ? 3.0 : 2.5, toWidth: 1.4,
            fromOpacity: 0.42, duration: duration, in: rootLayer
        )
        addExpandingRing(
            at: point, from: 10, to: AppConstants.clickEffectExpandRadius + 6,
            stroke: palette.accent, fromWidth: isRight ? 1.8 : 1.25, toWidth: 0.8,
            fromOpacity: 0.62, duration: duration, in: rootLayer
        )
    }

    private func emitSpotlight(at point: CGPoint, isRight: Bool, in rootLayer: CALayer) {
        let palette = colors(isRight: isRight)
        let duration = AppConstants.clickEffectDuration
        addExpandingRing(
            at: point, from: 9, to: AppConstants.clickEffectExpandRadius,
            stroke: palette.contrastDark, fromWidth: 2.4, toWidth: 1.2,
            fromOpacity: 0.40, duration: duration, in: rootLayer
        )
        let disc = makeCircleShape(at: point, radius: 9, stroke: palette.accent.withAlphaComponent(0.68), lineWidth: 1.4)
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

    private func circlePath(radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
    }
}
