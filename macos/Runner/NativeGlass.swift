import Cocoa
import FlutterMacOS

final class NativeGlassFactory: NSObject, FlutterPlatformViewFactory {
    private let channel: FlutterMethodChannel
    private weak var controller: FlutterViewController?
    private var appearanceObserver: NSObjectProtocol?
    private var accentObserver: NSObjectProtocol?

    init(controller: FlutterViewController) {
        self.controller = controller
        channel = FlutterMethodChannel(name: AppConstants.appearanceChannel, binaryMessenger: controller.engine.binaryMessenger)
        super.init()
        channel.setMethodCallHandler { call, result in
            guard call.method == AppConstants.getAppearanceMethod else { result(FlutterMethodNotImplemented); return }
            result(Self.appearanceSnapshot())
        }
        appearanceObserver = NotificationCenter.default.addObserver(forName: AppConstants.appearanceChangedNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.channel.invokeMethod(AppConstants.appearanceChangedMethod, arguments: Self.appearanceSnapshot())
            if let window = self.controller?.view.window { Self.applyAppearance(to: window) }
        }
        accentObserver = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.channel.invokeMethod(AppConstants.appearanceChangedMethod, arguments: Self.appearanceSnapshot())
        }
    }

    static var preview: [String: Any] = [:]

    private static var visualPreferences: [String: Any] {
        AppPreferences.current.merging(preview) { _, previewed in previewed }
    }

    static func accentPair(_ mode: String) -> (light: Int, dark: Int)? {
        if let swatch = AppConstants.accentSwatches[mode] { return swatch }
        guard mode.count == 7, mode.hasPrefix("#"), let rgb = Int(mode.dropFirst(), radix: 16) else { return nil }
        let lift = { (channel: Int) in channel + Int((Double(255 - channel) * AppConstants.accentCustomDarkLift).rounded()) }
        let dark = lift((rgb >> 16) & 0xFF) << 16 | lift((rgb >> 8) & 0xFF) << 8 | lift(rgb & 0xFF)
        return (0xFF00_0000 | rgb, 0xFF00_0000 | dark)
    }

    static func appearanceSnapshot() -> [String: Any] {
        let preferences = visualPreferences
        let pair = accentPair(preferences[AppConstants.accentColorKey] as? String ?? AppConstants.accentSystem)
        return [AppConstants.glassAppearanceKey: preferences[AppConstants.glassAppearanceKey] as? String ?? AppConstants.appearanceSystem,
                AppConstants.glassOpacityKey: preferences[AppConstants.glassOpacityKey] as? Double ?? 0.8,
                AppConstants.accentForegroundKey: preferences[AppConstants.accentForegroundKey] as? String ?? "auto",
                AppConstants.accentLightKey: pair?.light ?? accentARGB(.aqua),
                AppConstants.accentDarkKey: pair?.dark ?? accentARGB(.darkAqua)]
    }

    static func resolvedAccentNSColor(for appearance: NSAppearance) -> NSColor {
        let accentMode = visualPreferences[AppConstants.accentColorKey] as? String ?? AppConstants.accentSystem
        guard let swatch = accentPair(accentMode) else {
            return NSColor.controlAccentColor
        }
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let argb = dark ? swatch.dark : swatch.light
        let red = CGFloat((argb >> 16) & 0xFF) / 255
        let green = CGFloat((argb >> 8) & 0xFF) / 255
        let blue = CGFloat(argb & 0xFF) / 255
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    static func accentARGB(_ name: NSAppearance.Name) -> Int {
        var argb = 0
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let color = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
            let channel = { (value: CGFloat) in Int((value * 255).rounded()) }
            argb = channel(color.alphaComponent) << 24 | channel(color.redComponent) << 16
                | channel(color.greenComponent) << 8 | channel(color.blueComponent)
        }
        return argb
    }

    static func resolvedAppearance() -> NSAppearance? {
        let mode = appearanceSnapshot()[AppConstants.glassAppearanceKey] as? String ?? AppConstants.appearanceSystem
        guard mode != AppConstants.appearanceSystem else { return nil }
        let dark = mode == AppConstants.appearanceDark
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let name: NSAppearance.Name = highContrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua)
        return NSAppearance(named: name)
    }

    static func applyAppearance(to window: NSWindow) {
        window.appearance = resolvedAppearance()
        if let content = window.contentViewController as? NativeGlassWindowContent {
            content.windowCanvas.updateReadingColor()
        }
    }

    @discardableResult
    static func applyAppearance(to alert: NSAlert) -> NSAlert {
        applyAppearance(to: alert.window)
        return alert
    }

    static func makeGlassContainer(content: NSView, size: NSSize, cornerRadius: CGFloat) -> NativeGlassContainerView {
        NativeGlassContainerView(content: content, frame: NSRect(origin: .zero, size: size), cornerRadius: cornerRadius)
    }

    static func installContent(_ controller: FlutterViewController, in window: NSWindow, edgeToEdgeTop: Bool = false) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        let content = NativeGlassWindowContent()
        content.addChild(controller)
        window.contentViewController = content
        let view = controller.view
        view.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(view)
        let topAnchor = edgeToEdgeTop ? content.view.topAnchor : content.view.safeAreaLayoutGuide.topAnchor
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: content.view.bottomAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
        ])
        applyAppearance(to: window)
    }

    deinit {
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
        if let accentObserver { NotificationCenter.default.removeObserver(accentObserver) }
        channel.setMethodCallHandler(nil)
    }

    static let viewType = AppConstants.nativeGlassViewType

    static func register(with controller: FlutterViewController) {
        controller.backgroundColor = .clear
        controller.registrar(forPlugin: "NativeGlass")
            .register(NativeGlassFactory(controller: controller), withId: viewType)
    }

    func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withViewIdentifier viewId: Int64, arguments args: Any?) -> NSView {
        guard let parameters = args as? [String: Any],
              let radius = parameters["cornerRadius"] as? NSNumber,
              let brightness = parameters["brightness"] as? String,
              let highContrast = parameters["highContrast"] as? Bool,
              let opacity = parameters["opacity"] as? NSNumber else {
            preconditionFailure("NativeGlass requires cornerRadius, brightness and highContrast")
        }
        precondition(radius.doubleValue.isFinite && radius.doubleValue >= 0)
        let view = NativeGlassView(frame: .zero)
        view.cornerRadius = CGFloat(radius.doubleValue)
        view.style = .regular
        precondition(opacity.doubleValue.isFinite && (0.2...1).contains(opacity.doubleValue))
        view.materialOpacity = opacity.doubleValue
        view.tintColor = brightness == AppConstants.appearanceDark ? NSColor.black.withAlphaComponent(0.16) : NSColor.white.withAlphaComponent(0.16)
        view.updateTransparency()
        precondition(brightness == AppConstants.appearanceDark || brightness == AppConstants.appearanceLight)
        let appearance: NSAppearance.Name = highContrast
            ? (brightness == AppConstants.appearanceDark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (brightness == AppConstants.appearanceDark ? .darkAqua : .aqua)
        view.appearance = NSAppearance(named: appearance)
        view.setAccessibilityElement(false)
        return view
    }
}

final class NativeGlassView: NSGlassEffectView {
    var materialOpacity = 0.8
    private var accessibilityObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateTransparency() }
    }

    required init?(coder: NSCoder) { fatalError("NativeGlassView requires factory initialization") }

    func updateTransparency() {
        alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : materialOpacity
    }

    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var acceptsFirstResponder: Bool { false }
}

final class NativeGlassWindowContent: NSViewController {
    let windowCanvas = NativeReadingCanvas(frame: .zero)

    override func loadView() {
        view = NSView()
        windowCanvas.wantsLayer = true
        windowCanvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(windowCanvas)
        NSLayoutConstraint.activate([
            windowCanvas.topAnchor.constraint(equalTo: view.topAnchor),
            windowCanvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            windowCanvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            windowCanvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

final class NativeReadingCanvas: NSView {
    func updateReadingColor() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let value = dark ? 23.0 / 255.0 : 247.0 / 255.0
        layer?.backgroundColor = NSColor(srgbRed: value, green: value, blue: value, alpha: 1).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateReadingColor()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

final class NativeGlassContainerView: NSView {
    let glassView: NativeGlassView
    let contentHolder: NSView
    let cornerRadius: CGFloat
    private var appearanceObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?

    init(content: NSView, frame: NSRect, cornerRadius: CGFloat) {
        self.glassView = NativeGlassView(frame: .zero)
        self.contentHolder = content
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true

        glassView.style = .regular
        glassView.cornerRadius = cornerRadius
        glassView.translatesAutoresizingMaskIntoConstraints = false
        glassView.setAccessibilityElement(false)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassView)
        addSubview(content)
        NSLayoutConstraint.activate([
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        syncAppearanceAndMaterial()
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.appearanceChangedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncAppearanceAndMaterial()
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncAppearanceAndMaterial()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("NativeGlassContainerView requires programmatic initialization")
    }

    deinit {
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncAppearanceAndMaterial()
    }

    func syncAppearanceAndMaterial() {
        let snapshot = NativeGlassFactory.appearanceSnapshot()
        let mode = snapshot[AppConstants.glassAppearanceKey] as? String ?? AppConstants.appearanceSystem
        let opacity = snapshot[AppConstants.glassOpacityKey] as? Double ?? 0.8
        let clampedOpacity = min(1, max(0.2, opacity))
        let isDark: Bool
        switch mode {
        case AppConstants.appearanceDark:
            isDark = true
        case AppConstants.appearanceLight:
            isDark = false
        default:
            isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        glassView.appearance = NativeGlassFactory.resolvedAppearance()
        glassView.materialOpacity = clampedOpacity
        glassView.tintColor = isDark
            ? NSColor.black.withAlphaComponent(0.16)
            : NSColor.white.withAlphaComponent(0.16)
        glassView.updateTransparency()
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if reduceTransparency {
            let value = isDark ? 23.0 / 255.0 : 247.0 / 255.0
            layer?.backgroundColor = NSColor(srgbRed: value, green: value, blue: value, alpha: 1).cgColor
        } else {
            layer?.backgroundColor = nil
        }
    }
}
