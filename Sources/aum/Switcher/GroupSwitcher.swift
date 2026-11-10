import CoreGraphics

@MainActor final class GroupSwitcher {
    static let shared = GroupSwitcher()

    private static let groupKeys: [Int64: SpaceKind] = [13: .special, 14: .full, 2: .desktop]
    private static let digitKeys: [Int64: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4]

    private var swallowed: Set<Int64> = []
    private var session = false
    private var sessionKind: SpaceKind = .desktop
    private var frozen: [UInt64] = []
    private var index = 0
    private var startSpace: UInt64 = 0

    var pending: Bool { session }

    func commit() {
        guard session else { return }
        session = false
        let end = frozen.indices.contains(index) ? frozen[index] : startSpace
        frozen = []
        index = 0
        if end != startSpace { SpaceSwitcher.shared.commit(end) }
    }

    private func begin(_ kind: SpaceKind) -> Bool {
        let switcher = SpaceSwitcher.shared
        guard let snap = switcher.snapshot() else { return false }
        let kinds = switcher.classify(snap)
        let cur = switcher.currentSpace(snap)
        switcher.promote(cur)
        let list = switcher.ordered(snap.spaces.map(\.id).filter { kinds[$0] == kind })
        guard !list.isEmpty else { return false }
        frozen = list
        index = list.first == cur ? 0 : -1
        startSpace = cur
        sessionKind = kind
        switcher.virtualSpace = cur
        switcher.expectedFinal = nil
        session = true
        return true
    }

    private func step(forward: Bool) {
        let n = frozen.count
        if forward {
            index = (index + 1) % n
        } else {
            index = index < 0 ? n - 1 : (index - 1 + n) % n
        }
        SpaceSwitcher.shared.navigate(to: frozen[index])
    }

    private func track(_ type: CGEventType, _ event: CGEvent) {
        guard session else { return }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        switch type {
        case .keyDown, .keyUp:
            if Self.groupKeys[code] == nil { commit() }
        case .flagsChanged:
            let own =
                flags.contains(.maskAlternate)
                && flags.intersection([.maskCommand, .maskControl]).isEmpty
            if !own { commit() }
        case .leftMouseDown, .rightMouseDown, .scrollWheel:
            commit()
        default:
            break
        }
    }

    func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        track(type, event)
        guard Config.shared.groupSwitcher else { return false }
        guard Config.shared.altKeys else { return false }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        switch type {
        case .keyDown:
            guard flags.contains(.maskAlternate),
                flags.intersection([.maskCommand, .maskControl]).isEmpty
            else { return false }
            if let kind = Self.groupKeys[code] {
                swallowed.insert(code)
                if isRepeat { return true }
                if session && sessionKind != kind { commit() }
                if !session && !begin(kind) { return true }
                step(forward: !flags.contains(.maskShift))
                return true
            }
            if !flags.contains(.maskShift), let index = Self.digitKeys[code] {
                swallowed.insert(code)
                if !isRepeat { jump(index: index) }
                return true
            }
            return false

        case .keyUp:
            return swallowed.remove(code) != nil

        default:
            return false
        }
    }

    private func jump(index: Int) {
        let switcher = SpaceSwitcher.shared
        guard let snap = switcher.snapshot() else { return }
        let kinds = switcher.classify(snap)
        let cur = switcher.currentSpace(snap)
        guard let kind = kinds[cur] else { return }
        let list = snap.spaces.map(\.id).filter { kinds[$0] == kind }
        guard list.indices.contains(index) else { return }
        switcher.go(from: cur, to: list[index])
    }
}
