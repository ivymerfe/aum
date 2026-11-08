import AppKit
import ApplicationServices
import CoreGraphics

@_silgen_name("SLSCopySpacesForWindows")
func SLSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?

@MainActor final class AppSwitcher {
    static let shared = AppSwitcher()

    private static let tabKey: Int64 = 48
    private static let repeatInterval: TimeInterval = 0.25

    private var mru: [pid_t] = []
    private var frozen: [NSRunningApplication] = []
    private var index = 0
    private var active = false
    private var tabHeld = false
    private var forward = true
    private var repeatTimer: Timer?
    private var virtualSpace: UInt64 = 0
    private var lastCommit: CFAbsoluteTime = 0
    private var token = 0

    func appActivated(_ app: NSRunningApplication) {
        guard !active, app.activationPolicy == .regular else { return }
        let pid = app.processIdentifier
        if CFAbsoluteTimeGetCurrent() - lastCommit < 0.5 && pid != mru.first { return }
        promote(pid)
    }

    func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard Config.shared.appSwitcher else { return false }
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .keyDown:
            guard code == Self.tabKey,
                event.flags.contains(.maskCommand),
                event.flags.intersection([.maskControl, .maskAlternate]).isEmpty
            else { return false }
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return true }
            if !active { beginSession() }
            tabHeld = true
            forward = !event.flags.contains(.maskShift)
            step()
            armRepeat()
            return true

        case .keyUp:
            guard tabHeld, code == Self.tabKey else { return false }
            endSession()
            return true

        case .flagsChanged:
            if active {
                if event.flags.contains(.maskCommand) {
                    forward = !event.flags.contains(.maskShift)
                } else {
                    endSession()
                }
            }
            return false

        default:
            return false
        }
    }

    private func armRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatInterval, repeats: false) {
            _ in
            Task { @MainActor in AppSwitcher.shared.repeatTick() }
        }
    }

    private func repeatTick() {
        guard active, tabHeld else { return }
        step()
        armRepeat()
    }

    private func promote(_ pid: pid_t) {
        mru.removeAll { $0 == pid }
        mru.insert(pid, at: 0)
    }

    private func beginSession() {
        let recent = CFAbsoluteTimeGetCurrent() - lastCommit < 0.6
        if !recent,
            let front = NSWorkspace.shared.frontmostApplication,
            front.activationPolicy == .regular
        {
            promote(front.processIdentifier)
        }
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !mru.contains(app.processIdentifier) {
            mru.append(app.processIdentifier)
        }
        frozen = mru.compactMap { NSRunningApplication(processIdentifier: $0) }
            .filter { !$0.isTerminated && $0.activationPolicy == .regular }
        mru = frozen.map(\.processIdentifier)
        index = 0
        if !recent { virtualSpace = SLSGetActiveSpace(CGSMainConnectionID()) }
        active = true
    }

    private func endSession() {
        repeatTimer?.invalidate()
        active = false
        tabHeld = false
        if index != 0, frozen.indices.contains(index) {
            promote(frozen[index].processIdentifier)
            lastCommit = CFAbsoluteTimeGetCurrent()
        }
        frozen = []
        index = 0
    }

    private func step() {
        guard frozen.count > 1 else { return }
        index = (index + (forward ? 1 : frozen.count - 1)) % frozen.count
        let app = frozen[index]
        guard !app.isTerminated else { return }
        token &+= 1
        var delay = 0.0
        if let move = spaceMove(for: app), move.delta != 0 {
            virtualSpace = move.target
            _ = SpaceSwitcher.shared.focusRelative(right: move.delta > 0, count: abs(move.delta))
            delay = 0.35
        }
        focus(app, token: token, delay: delay, attempt: 0)
    }

    private func focus(_ app: NSRunningApplication, token t: Int, delay: TimeInterval, attempt: Int)
    {
        Task { @MainActor in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard t == token, !app.isTerminated else { return }
            app.activate()
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            try? await Task.sleep(for: .milliseconds(80))
            guard t == token, attempt < 4 else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                focus(app, token: t, delay: 0, attempt: attempt + 1)
            }
        }
    }

    private func windowIDs(of app: NSRunningApplication) -> [UInt32] {
        guard
            let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var result: [UInt32] = []
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                (w[kCGWindowLayer as String] as? Int) == 0,
                let id = w[kCGWindowNumber as String] as? UInt32,
                let b = w[kCGWindowBounds as String] as? [String: Any],
                let width = b["Width"] as? Double, let height = b["Height"] as? Double,
                width > 100, height > 100
            else { continue }
            result.append(id)
        }
        return result
    }

    private func spaceMove(for app: NSRunningApplication) -> (delta: Int, target: UInt64)? {
        let cid = CGSMainConnectionID()
        let wids = windowIDs(of: app)
        guard !wids.isEmpty else { return nil }
        let arr = wids.map { NSNumber(value: $0) } as CFArray
        guard let raw = SLSCopySpacesForWindows(cid, 0x7, arr)?.takeRetainedValue() else {
            return nil
        }
        let spaces = (raw as NSArray).compactMap { ($0 as? NSNumber)?.uint64Value }
        if spaces.isEmpty || spaces.contains(virtualSpace) { return nil }

        guard
            let displays = SLSCopyManagedDisplaySpaces(cid)?.takeRetainedValue()
                as? [[String: Any]]
        else { return nil }

        for display in displays {
            guard let list = display["Spaces"] as? [[String: Any]] else { continue }
            let ids = list.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
            guard let a = ids.firstIndex(of: virtualSpace) else { continue }
            let options = spaces.compactMap { s in
                ids.firstIndex(of: s).map { (delta: $0 - a, target: s) }
            }
            return options.min { abs($0.delta) < abs($1.delta) }
        }
        return nil
    }
}
