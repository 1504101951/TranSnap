import AppKit
import ApplicationServices

struct AutoScrollPlan {
    enum Action: Equatable {
        case wait
        case scroll(by: Double)
        case rewind
        case bottom
        case unsupported
    }

    static let settledFrames = 2
    static let maximumWait: Duration = .milliseconds(1000)
    static let bottomWait: Duration = .milliseconds(1500)
    static let initialStep = 0.01
    static let initialKeyPresses = 2.0

    private(set) var target: Int
    private var growth = 4.0
    private var shrinksTarget = false
    private(set) var step: Double
    private var stepped: ContinuousClock.Instant?
    private var moved = 0
    private var still = 0
    private var rewinding = false
    private var everMoved = false

    init(height: Int, step: Double = initialStep) {
        target = max(1, height / 2)
        self.step = step
    }

    static func keys(height: Int) -> AutoScrollPlan {
        var plan = AutoScrollPlan(height: height, step: initialKeyPresses)
        plan.target = max(1, height / 4)
        plan.growth = 1.5
        plan.shrinksTarget = true
        return plan
    }

    mutating func start(now: ContinuousClock.Instant) -> Action {
        rewinding = false
        begin(now)
        return .scroll(by: step)
    }

    mutating func frame(shift: Int, now: ContinuousClock.Instant) -> Action {
        guard let stepped else { return .wait }
        if shift > 0 {
            moved += shift
            still = 0
        } else {
            still += 1
        }
        if rewinding {
            guard still >= Self.settledFrames else { return .wait }
            rewinding = false
            begin(now)
            return .scroll(by: step)
        }
        if moved > 0, still >= Self.settledFrames || now - stepped >= Self.maximumWait {
            everMoved = true
            step = min(step * growth, step * Double(target) / Double(moved))
            begin(now)
            return .scroll(by: step)
        }
        guard moved == 0, now - stepped >= Self.bottomWait else { return .wait }
        self.stepped = nil
        return everMoved ? .bottom : .unsupported
    }

    mutating func mismatch(now: ContinuousClock.Instant) -> Action {
        step /= 2
        if shrinksTarget { target = max(1, target / 2) }
        rewinding = true
        begin(now)
        return .rewind
    }

    private mutating func begin(_ now: ContinuousClock.Instant) {
        stepped = now
        moved = 0
        still = 0
    }
}

struct AutoScrollKeys {
    private static let downKey: CGKeyCode = 125
    private static let upKey: CGKeyCode = 126
    private static let maximumPresses = 40

    let pid: pid_t
    private var last = 0

    init(pid: pid_t) { self.pid = pid }

    mutating func scroll(by step: Double) -> Bool {
        let presses = Self.presses(step)
        guard press(Self.downKey, count: presses) else { return false }
        last = presses
        return true
    }

    func rewind() -> Bool { press(Self.upKey, count: last) }

    static func presses(_ step: Double) -> Int { min(maximumPresses, max(1, Int(step.rounded()))) }

    private func press(_ key: CGKeyCode, count: Int) -> Bool {
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else { return false }
            SyntheticEvent.mark(down)
            SyntheticEvent.mark(up)
            down.postToPid(pid)
            up.postToPid(pid)
        }
        return true
    }
}

final class AutoScrollTarget {
    private let bar: AXUIElement

    static func sourceProcess(at point: CGPoint) -> pid_t? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let own = ProcessInfo.processInfo.processIdentifier
        let owner = windows.first { info in
            guard info[kCGWindowLayer as String] as? Int == 0, info[kCGWindowOwnerPID as String] as? pid_t != own,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return rect.contains(point)
        }
        return owner?[kCGWindowOwnerPID as String] as? pid_t
    }

    init?(point: CGPoint) {
        guard let pid = Self.sourceProcess(at: point) else { return nil }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(pid), Float(point.x), Float(point.y), &hit) == .success,
              var current = hit else { return nil }
        for _ in 0..<30 {
            if Self.attribute(current, kAXRoleAttribute) as? String == kAXScrollAreaRole as String,
               let found = Self.attribute(current, kAXVerticalScrollBarAttribute) {
                let bar = found as! AXUIElement
                var settable = DarwinBoolean(false)
                guard AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success,
                      settable.boolValue else { return nil }
                self.bar = bar
                return
            }
            guard let parent = Self.attribute(current, kAXParentAttribute) else { return nil }
            current = parent as! AXUIElement
        }
        return nil
    }

    var value: Double? { (Self.attribute(bar, kAXValueAttribute) as? NSNumber)?.doubleValue }

    func set(_ value: Double) -> Bool {
        AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: min(1, max(0, value)))) == .success
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
