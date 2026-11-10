import AppKit
import CoreGraphics

@MainActor final class MruSwitcher {
    static let shared = MruSwitcher()

    private static let tabKey: Int64 = 48
    private static let tapMax: TimeInterval = 0.2

    private var session = false
    private var forward = true
    private var index = 0
    private var startSpace: UInt64 = 0
    private var frozen: [UInt64] = []
    private var swallowed: Set<Int64> = []

    private var optionDown = false
    private var optionDirty = false
    private var optionTime: CFAbsoluteTime = 0

    var pending: Bool { session }

    func commit() {
        guard session else { return }
        session = false
        let end = frozen.indices.contains(index) ? frozen[index] : startSpace
        frozen = []
        index = 0
        if end != startSpace { SpaceSwitcher.shared.commit(end) }
    }

    private func begin() -> Bool {
        let switcher = SpaceSwitcher.shared
        guard let snap = switcher.snapshot() else { return false }
        let cur = switcher.currentSpace(snap)
        guard snap.spaces.contains(where: { $0.id == cur }) else { return false }
        switcher.promote(cur)
        frozen = switcher.ordered(snap.spaces.map(\.id))
        index = 0
        startSpace = cur
        switcher.virtualSpace = cur
        switcher.expectedFinal = nil
        session = true
        return true
    }

    private func step() {
        let n = frozen.count
        guard n > 1 else { return }
        index = (index + (forward ? 1 : n - 1)) % n
        SpaceSwitcher.shared.navigate(to: frozen[index])
    }

    private func toggle() {
        let switcher = SpaceSwitcher.shared
        switcher.commitAll()
        guard let snap = switcher.snapshot() else { return }
        let cur = switcher.currentSpace(snap)
        switcher.promote(cur)
        guard
            let prev = switcher.allMRU.dropFirst().first(where: { id in
                snap.spaces.contains(where: { $0.id == id })
            })
        else { return }
        switcher.go(from: cur, to: prev)
    }

    private func trackActivity(_ type: CGEventType, _ event: CGEvent) {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        switch type {
        case .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .scrollWheel:
            break
        case .flagsChanged:
            if code == 58 || code == 61 { return }
        default:
            return
        }

        if optionDown { optionDirty = true }
        guard session else { return }

        let own: Bool
        switch type {
        case .keyDown, .keyUp:
            own = code == Self.tabKey && flags.contains(.maskCommand)
        case .flagsChanged:
            own =
                flags.contains(.maskCommand)
                && flags.intersection([.maskControl, .maskAlternate]).isEmpty
        default:
            own = false
        }
        if !own { commit() }
    }

    func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        trackActivity(type, event)
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        switch type {
        case .keyDown:
            guard Config.shared.cmdTabSwitcher else { return false }
            guard code == Self.tabKey,
                flags.contains(.maskCommand),
                flags.intersection([.maskControl, .maskAlternate]).isEmpty
            else { return false }
            swallowed.insert(code)
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return true }
            if !session && !begin() { return true }
            forward = !flags.contains(.maskShift)
            step()
            return true

        case .keyUp:
            return swallowed.remove(code) != nil

        case .flagsChanged:
            if session {
                if flags.contains(.maskCommand) {
                    forward = !flags.contains(.maskShift)
                } else {
                    commit()
                }
            }
            handleOption(flags)
            return false

        default:
            return false
        }
    }

    private func handleOption(_ flags: CGEventFlags) {
        guard Config.shared.altTapSwitcher else { return }
        guard Config.shared.altKeys else { return }

        let alt = flags.contains(.maskAlternate)
        let others = !flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty
        let now = CFAbsoluteTimeGetCurrent()
        if alt {
            if !optionDown {
                optionDown = true
                optionDirty = others
                optionTime = now
            } else if others {
                optionDirty = true
            }
        } else if optionDown {
            optionDown = false
            if !optionDirty && !others && now - optionTime < Self.tapMax { toggle() }
        }
    }
}
