import Cocoa
import FlutterMacOS

/// 原生材料工厂；每个 Flutter 引擎独立注册，不保存业务或窗口生命周期状态。
final class NativeGlassFactory: NSObject, FlutterPlatformViewFactory {
    /// 专用通道只传视觉快照，避免覆盖各窗口已有业务消息处理器。
    private let channel: FlutterMethodChannel
    private weak var controller: FlutterViewController?
    private var appearanceObserver: NSObjectProtocol?
    private var accentObserver: NSObjectProtocol?

    /// controller 绑定当前引擎；监听保存成功广播并更新该引擎和原生窗口。
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
        // 用户在系统设置里改强调色时系统颜色整体刷新；沿用外观广播把新强调色推给本引擎（#142）。
        accentObserver = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.channel.invokeMethod(AppConstants.appearanceChangedMethod, arguments: Self.appearanceSnapshot())
        }
    }

    /// 无参数；返回已提交的视觉字段与当前系统强调色（浅、深外观各一份），不读取凭据或业务草稿。
    static func appearanceSnapshot() -> [String: Any] {
        let preferences = AppPreferences.current
        return [AppConstants.glassAppearanceKey: preferences[AppConstants.glassAppearanceKey] as? String ?? AppConstants.appearanceSystem,
                AppConstants.glassOpacityKey: preferences[AppConstants.glassOpacityKey] as? Double ?? 0.8,
                AppConstants.accentLightKey: accentARGB(.aqua),
                AppConstants.accentDarkKey: accentARGB(.darkAqua)]
    }

    /// name 为浅色或深色外观；在该外观下解析系统强调色，返回 sRGB ARGB 整数（如系统蓝浅色 0xFF007AFF）。
    static func accentARGB(_ name: NSAppearance.Name) -> Int {
        var argb = 0
        // 强调色是动态颜色，必须在目标外观下解析才能得到浅、深两套值。
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let color = NSColor.controlAccentColor.usingColorSpace(.sRGB)!
            let channel = { (value: CGFloat) in Int((value * 255).rounded()) }
            argb = channel(color.alphaComponent) << 24 | channel(color.redComponent) << 16
                | channel(color.greenComponent) << 8 | channel(color.blueComponent)
        }
        return argb
    }

    /// 无参数；解析用户选择的原生窗口外观及系统高对比度配置，跟随系统时返回 nil。
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

    /// window 为实际原生窗口；应用手动明暗或系统继承，不改焦点及层级。
    static func applyAppearance(to window: NSWindow) {
        window.appearance = resolvedAppearance()
        if let content = window.contentViewController as? NativeGlassWindowContent {
            // 标题与正文共用阅读底色；系统负责窗口唯一外轮廓，不制造另一条玻璃标题带。
            content.windowCanvas.updateReadingColor()
        }
    }

    /// alert 为系统弹窗；将当前应用浅色/深色外观同步到弹窗窗口并返回自身，无副作用（#144）。
    @discardableResult
    static func applyAppearance(to alert: NSAlert) -> NSAlert {
        applyAppearance(to: alert.window)
        return alert
    }

    /// content 为原生 AppKit 内容视图，size 为预期尺寸，cornerRadius 为玻璃裁切圆角；
    /// 返回分层承载玻璃背景与不透明前景的容器视图，确保调节玻璃透明度时仅淡化底层材料而不淡化前景文字（#144）。
    static func makeGlassContainer(content: NSView, size: NSSize, cornerRadius: CGFloat) -> NativeGlassContainerView {
        NativeGlassContainerView(content: content, frame: NSRect(origin: .zero, size: size), cornerRadius: cornerRadius)
    }

    /// controller为Flutter内容，window为面板或结果窗口；背景贯穿窗口，交互内容遵守视图安全区域。
    static func installContent(_ controller: FlutterViewController, in window: NSWindow) {
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        let content = NativeGlassWindowContent()
        content.addChild(controller)
        window.contentViewController = content
        let view = controller.view
        view.translatesAutoresizingMaskIntoConstraints = false
        content.view.addSubview(view)
        // 无标题面板也有视图安全区域；系统在标题栏和窗口尺寸改变时维护其边界。
        let guide = content.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.view.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: content.view.bottomAnchor),
            view.topAnchor.constraint(equalTo: guide.topAnchor),
        ])
        applyAppearance(to: window)
    }

    deinit {
        if let appearanceObserver { NotificationCenter.default.removeObserver(appearanceObserver) }
        if let accentObserver { NotificationCenter.default.removeObserver(accentObserver) }
        channel.setMethodCallHandler(nil)
    }

    static let viewType = AppConstants.nativeGlassViewType

    /// controller 为当前窗口的 Flutter 控制器；注册玻璃视图并允许原生材料透出。
    static func register(with controller: FlutterViewController) {
        // FlutterView 默认黑色背景会挡住系统材料；只改承载透明度，不改窗口层级。
        controller.backgroundColor = .clear
        controller.registrar(forPlugin: "NativeGlass")
            .register(NativeGlassFactory(controller: controller), withId: viewType)
    }

    /// 无参数；返回与 Dart creationParams 一致的标准编解码器。
    func createArgsCodec() -> (FlutterMessageCodec & NSObjectProtocol)? {
        FlutterStandardMessageCodec.sharedInstance()
    }

    /// viewId 是引擎分配的视图身份，args 含非负 cornerRadius；返回真正的系统玻璃视图。
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

/// 只承载系统 Liquid Glass 材料；Flutter 上层控件负责点击、选字和键盘焦点。
final class NativeGlassView: NSGlassEffectView {
    /// 仅原生材料变淡；Flutter前景不属于此NSView，不受alpha影响。
    var materialOpacity = 0.8
    private var accessibilityObserver: NSObjectProtocol?

    /// frame 是材料初始布局；监听系统减少透明度的即时变化。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateTransparency() }
    }

    /// 本视图仅由平台工厂创建，不支持归档解码。
    required init?(coder: NSCoder) { fatalError("NativeGlassView requires factory initialization") }

    /// 无参数；系统辅助功能优先于用户透明度，返回void。
    func updateTransparency() {
        alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : materialOpacity
    }

    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    /// point 为原生局部坐标；材料不拦截输入，返回 nil 让上层 Flutter 命中测试继续。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 材料本身不取得键盘焦点，避免干扰非激活翻译浮层及截图文字输入。
    override var acceptsFirstResponder: Bool { false }
}

/// 普通窗口共享整窗阅读背景；系统标题安全区只约束交互内容，不划分背景面板。
final class NativeGlassWindowContent: NSViewController {
    /// 整窗底色与Flutter surface相同；不覆盖红绿灯或截获内容事件。
    let windowCanvas = NativeReadingCanvas(frame: .zero)

    /// 无参数；创建连续窗口背景，外轮廓由AppKit负责。
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

/// 整窗阅读底色；跟随系统外观变化，且不接收指针或键盘事件。
final class NativeReadingCanvas: NSView {
    /// 无参数；按当前实际外观同步与Flutter surface一致的背景色。
    func updateReadingColor() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // 使用与Flutter颜色值一致的sRGB，避免calibratedWhite颜色空间造成接缝。
        let value = dark ? 23.0 / 255.0 : 247.0 / 255.0
        layer?.backgroundColor = NSColor(srgbRed: value, green: value, blue: value, alpha: 1).cgColor
    }

    /// 系统明暗变化时更新整窗底色，无参数或返回值。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateReadingColor()
    }

    /// point为本地坐标；背景不命中，返回nil让交互内容处理事件。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

/// 分层承载原生 AppKit 玻璃材料与前景交互控件的通用容器（#144 U-18）。
/// 底层使用 `NativeGlassView` 同步 `glassOpacity` 与系统减少透明度/增强对比度降级；
/// 顶层放置透明前景容器，确保前景文字与按钮始终保持 100% 不透明度。
final class NativeGlassContainerView: NSView {
    let glassView: NativeGlassView
    let contentHolder: NSView
    private let cornerRadius: CGFloat
    private var appearanceObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?

    /// content 为原生交互前景视图，frame 为初始容器边界，cornerRadius 为材质圆角半径。
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

    /// 无参数；系统或窗口外观改变时同步刷新材质色调与无障碍背板。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncAppearanceAndMaterial()
    }

    /// 无参数；按当前偏好（明暗模式、玻璃透明度）与系统无障碍开关同步底层材料与高对比背板。
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
        // 开启「减少透明度」或「增强对比度」时补实底阅读色，避免底层背景花纹降低文字对比度。
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
