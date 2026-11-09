import CoreGraphics

@MainActor final class TouchSwitcher {
    static let shared = TouchSwitcher()

    private static let deadZone = 0.05

    private(set) var swipeTracking = false
    private var session = false
    private var line: [UInt64] = []
    private var startIndex = 0
    private var cursor = 0
    private var baseCursor = 0
    private var stepsApplied = 0
    private var swipeMoved = false

    var pending: Bool { session }

    func userAction() {
        commit()
    }

    func commit() {
        guard session, !swipeTracking else { return }
        session = false
        let end = line.indices.contains(cursor) ? line[cursor] : nil
        let moved = cursor != startIndex
        line = []
        if moved, let id = end { SpaceSwitcher.shared.commit(id) }
    }

    private func beginSession() -> Bool {
        let switcher = SpaceSwitcher.shared
        guard let snap = switcher.snapshot() else { return false }
        let cur = switcher.currentSpace(snap)
        guard snap.spaces.contains(where: { $0.id == cur }) else { return false }

        let kinds = switcher.classify(snap)
        switcher.promote(cur)
        let sorted = switcher.ordered(snap.spaces.map(\.id))
        let left = sorted.filter { kinds[$0] == .special }
        let right = sorted.filter { kinds[$0] != .special }
        line = left.reversed() + right
        startIndex = kinds[cur] == .special ? left.count - 1 : left.count
        cursor = startIndex
        switcher.virtualSpace = cur
        switcher.expectedFinal = nil
        session = true
        return true
    }

    private func beginSwipe() -> Bool {
        if session && !line.contains(SpaceSwitcher.shared.virtualSpace) { commit() }
        if !session && !beginSession() { return false }
        baseCursor = cursor
        stepsApplied = 0
        swipeMoved = false
        return true
    }

    private func endSwipe() {
        swipeTracking = false
        stepsApplied = 0
    }

    private func apply(progress: Double) {
        let n = abs(progress) < Self.deadZone ? 0 : (progress > 0 ? 1 : -1)
        setSteps(n)
    }

    private func setSteps(_ n: Int) {
        guard n != stepsApplied else { return }
        stepsApplied = n
        if n != 0 { swipeMoved = true }
        let new = min(max(baseCursor + n, 0), line.count - 1)
        guard new != cursor else { return }
        cursor = new
        SpaceSwitcher.shared.navigate(to: line[cursor])
    }

    func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard Config.shared.gestureSwitcher else { return false }

        if type == kCGSEventDockControl || type == kCGSEventGesture {
            if event.getIntegerValueField(.eventSourceUnixProcessID) != 0 { return false }
        }
        if type == kCGSEventDockControl {
            let hidType = event.getIntegerValueField(kCGEventGestureHIDType)
            if hidType == kIOHIDEventTypeDockSwipe {
                let motion = event.getIntegerValueField(kCGEventGestureSwipeMotion)
                if motion == kCGGestureMotionHorizontal {
                    let phaseRaw = event.getIntegerValueField(kCGEventGesturePhase)

                    switch phaseRaw {
                    case 1:
                        swipeTracking = beginSwipe()
                        return swipeTracking

                    case 2:
                        if !swipeTracking { return false }
                        apply(progress: event.getDoubleValueField(kCGEventGestureSwipeProgress))
                        return true

                    case 4:
                        if !swipeTracking { return false }
                        apply(progress: event.getDoubleValueField(kCGEventGestureSwipeProgress))
                        if !swipeMoved {
                            let velocity = event.getDoubleValueField(kCGEventGestureSwipeVelocityX)
                            if velocity != 0.0 { setSteps(velocity > 0 ? 1 : -1) }
                        }
                        endSwipe()
                        event.setDoubleValueField(kCGEventGestureSwipeProgress, value: 0.0)
                        event.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: 0.0)
                        event.setDoubleValueField(CGEventField(rawValue: 130)!, value: 0.0)
                        return false

                    case 8:
                        if !swipeTracking { return false }
                        endSwipe()
                        return true

                    default:
                        return swipeTracking
                    }
                }
            }
        }
        if type == kCGSEventGesture && swipeTracking {
            return true
        }
        return false
    }
}
