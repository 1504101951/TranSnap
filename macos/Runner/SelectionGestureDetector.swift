import Foundation


struct MousePointerEvent {
    enum Kind { case down, dragged, up }
    var kind: Kind
    var clickCount: Int
    var x: CGFloat
    var y: CGFloat
}

struct SelectionGestureDetector {
    static let dragThreshold: CGFloat = 4
    private var originX: CGFloat?
    private var originY: CGFloat?
    private var isDrag = false

    mutating func handle(_ event: MousePointerEvent) -> SelectionGesture? {
        switch event.kind {
        case .down:
            originX = event.x
            originY = event.y
            isDrag = false
            return nil
        case .dragged:
            if let originX, let originY {
                if hypot(event.x - originX, event.y - originY) >= Self.dragThreshold {
                    isDrag = true
                }
            }
            return nil
        case .up:
            let dragged = isDrag
            originX = nil
            originY = nil
            isDrag = false
            if dragged { return .drag }
            if event.clickCount == 2 { return .doubleClick }
            if event.clickCount >= 3 { return .tripleClick }
            return nil
        }
    }
}
