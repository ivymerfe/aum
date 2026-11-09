import CoreGraphics

@MainActor final class GroupSwitcher {
    static let shared = GroupSwitcher()

    private static let groupKeys: [Int64: SpaceKind] = [13: .special, 14: .full, 15: .desktop]
    private static let digitKeys: [Int64: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4]

    private var swallowed: Set<Int64> = []

    func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
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
                if !isRepeat { cycle(kind, forward: !flags.contains(.maskShift)) }
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

    private func cycle(_ kind: SpaceKind, forward: Bool) {
        let switcher = SpaceSwitcher.shared
        guard let snap = switcher.snapshot() else { return }
        let kinds = switcher.classify(snap)
        let current = switcher.currentSpace(snap)
        switcher.promote(current)
        let ids = snap.spaces.map(\.id).filter { kinds[$0] == kind }
        let list = switcher.ordered(ids)
        guard !list.isEmpty else { return }
        let inGroup = list.first == current
        let target: UInt64
        if forward {
            target = inGroup ? (list.count > 1 ? list[1] : current) : list[0]
        } else {
            target = list.last!
        }
        switcher.go(from: current, to: target)
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
