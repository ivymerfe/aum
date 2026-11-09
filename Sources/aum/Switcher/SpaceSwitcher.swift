import AppKit
import CoreGraphics
import Foundation

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

@_silgen_name("SLSGetActiveSpace")
func SLSGetActiveSpace(_ cid: Int32) -> UInt64

@_silgen_name("SLSCopyManagedDisplaySpaces")
func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?

@_silgen_name("SLSCopySpacesForWindows")
func SLSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?

enum SpaceKind {
    case special
    case full
    case desktop
}

struct SpaceInfo {
    let id: UInt64
    let isFull: Bool
}

struct SpaceSnapshot {
    let spaces: [SpaceInfo]
    let active: UInt64
}

@MainActor final class SpaceSwitcher {
    static let shared = SpaceSwitcher()

    private static let specialBundles: Set<String> = [
        "com.brave.Browser",
        "com.apple.finder",
        "com.googlecode.iterm2",
        "com.apple.Safari",
    ]

    var lastGestureTime: CFAbsoluteTime = 0
    var virtualSpace: UInt64 = 0
    private(set) var knownSpaces: Set<UInt64> = []
    var allMRU: [UInt64] = []
    var expectedFinal: UInt64?

    func startTracking() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in SpaceSwitcher.shared.spaceChanged() }
        }
        spaceChanged()
    }

    func commitAll() {
        TouchSwitcher.shared.commit()
        MruSwitcher.shared.commit()
    }

    private func spaceChanged() {
        let switcher = SpaceSwitcher.shared
        guard let snap = switcher.snapshot() else { return }
        if TouchSwitcher.shared.swipeTracking { return }
        let now = CFAbsoluteTimeGetCurrent()
        if TouchSwitcher.shared.pending || MruSwitcher.shared.pending {
            if now - switcher.lastGestureTime < 1.0 || snap.active == switcher.virtualSpace { return }
            commitAll()
        }
        if let expected = expectedFinal {
            if now - switcher.lastGestureTime > 1.5 {
                expectedFinal = nil
            } else if snap.active == expected {
                expectedFinal = nil
                return
            } else {
                return
            }
        }
        promote(snap.active)
    }

    func promote(_ id: UInt64) {
        let known = SpaceSwitcher.shared.knownSpaces
        allMRU.removeAll { !known.contains($0) }
        allMRU.removeAll { $0 == id }
        allMRU.insert(id, at: 0)
    }

    func ordered(_ ids: [UInt64]) -> [UInt64] {
        var r = allMRU.filter { ids.contains($0) }
        for id in ids where !r.contains(id) { r.append(id) }
        return r
    }

    func commit(_ id: UInt64) {
        promote(id)
        expectedFinal = id
        SpaceSwitcher.shared.lastGestureTime = CFAbsoluteTimeGetCurrent()
    }

    func go(from cur: UInt64, to target: UInt64) {
        guard target != cur else { return }
        let switcher = SpaceSwitcher.shared
        promote(cur)
        switcher.virtualSpace = cur
        switcher.navigate(to: target)
        commit(target)
    }

    func currentSpace(_ snap: SpaceSnapshot) -> UInt64 {
        if CFAbsoluteTimeGetCurrent() - lastGestureTime < 1.5,
            snap.spaces.contains(where: { $0.id == virtualSpace })
        {
            return virtualSpace
        }
        return snap.active
    }

    func snapshot() -> SpaceSnapshot? {
        let cid = CGSMainConnectionID()
        guard cid != 0 else { return nil }
        let active = SLSGetActiveSpace(cid)
        guard let unmanaged = SLSCopyManagedDisplaySpaces(cid) else { return nil }
        guard let displays = unmanaged.takeRetainedValue() as? [[String: Any]] else { return nil }

        var all = Set<UInt64>()
        var result: [SpaceInfo]?
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            let infos = spaces.compactMap { s -> SpaceInfo? in
                guard let id = (s["id64"] as? NSNumber)?.uint64Value else { return nil }
                let type = (s["type"] as? NSNumber)?.intValue ?? 0
                return SpaceInfo(id: id, isFull: type != 0)
            }
            infos.forEach { all.insert($0.id) }
            if infos.contains(where: { $0.id == active }) { result = infos }
        }
        knownSpaces = all
        guard let spaces = result else { return nil }
        return SpaceSnapshot(spaces: spaces, active: active)
    }

    func classify(_ snap: SpaceSnapshot) -> [UInt64: SpaceKind] {
        var kinds: [UInt64: SpaceKind] = [:]
        var fullIds = Set<UInt64>()
        for s in snap.spaces {
            if s.isFull {
                fullIds.insert(s.id)
                kinds[s.id] = .full
            } else {
                kinds[s.id] = .desktop
            }
        }
        guard !fullIds.isEmpty,
            let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return kinds }

        let cid = CGSMainConnectionID()
        var bundles: [pid_t: String?] = [:]
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32,
                (w[kCGWindowLayer as String] as? Int) == 0,
                let id = w[kCGWindowNumber as String] as? UInt32,
                let b = w[kCGWindowBounds as String] as? [String: Any],
                let width = b["Width"] as? Double, let height = b["Height"] as? Double,
                width > 100, height > 100
            else { continue }
            let bundle: String?
            if let cached = bundles[pid] {
                bundle = cached
            } else {
                bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                bundles[pid] = bundle
            }
            guard let name = bundle, Self.specialBundles.contains(name) else { continue }
            let arr = [NSNumber(value: id)] as CFArray
            guard let raw = SLSCopySpacesForWindows(cid, 0x7, arr)?.takeRetainedValue() else {
                continue
            }
            for s in (raw as NSArray).compactMap({ ($0 as? NSNumber)?.uint64Value })
            where fullIds.contains(s) {
                kinds[s] = .special
            }
        }
        return kinds
    }

    func navigate(to target: UInt64) {
        guard let snap = snapshot() else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastGestureTime > 0.6 || !snap.spaces.contains(where: { $0.id == virtualSpace }) {
            virtualSpace = snap.active
        }
        guard let from = snap.spaces.firstIndex(where: { $0.id == virtualSpace }),
            let to = snap.spaces.firstIndex(where: { $0.id == target })
        else { return }
        let delta = to - from
        guard delta != 0 else { return }
        lastGestureTime = now
        virtualSpace = target
        _ = focusRelative(right: delta > 0, count: abs(delta))
    }

    func focusRelative(right: Bool, count: Int) -> Bool {
        for _ in 1...count {
            let b = postSwipe(phase: .began, right: right)
            let c = postSwipe(phase: .changed, right: right)
            let e = postSwipe(phase: .ended, right: right)
            if !b || !c || !e {
                return false
            }
        }
        return true
    }

    func postSwipe(phase: CGSGesturePhase, right: Bool) -> Bool {
        let sign: Double = right ? -1.0 : 1.0

        guard let ev = CGEvent(source: nil) else { return false }

        ev.setIntegerValueField(kCGSEventTypeField, value: Int64(kCGSEventDockControl.rawValue))
        ev.setIntegerValueField(kCGEventGestureHIDType, value: kIOHIDEventTypeDockSwipe)
        ev.setIntegerValueField(kCGEventGesturePhase, value: phase.rawValue)
        ev.setIntegerValueField(kCGEventGestureSwipeMotion, value: kCGGestureMotionHorizontal)

        ev.setDoubleValueField(kCGEventGestureSwipeProgress, value: sign * 0.000016)
        ev.setIntegerValueField(kCGEventGesturePhaseAlias, value: phase.rawValue)
        ev.setDoubleValueField(kCGEventGestureZoomDeltaY, value: 3.0)
        ev.setDoubleValueField(
            kCGEventSourceUnixProcessIDAlias, value: Double(mach_absolute_time()))
        ev.setDoubleValueField(kCGEventGestureSwipePositionX, value: 0.1)

        if phase == .ended {
            ev.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: sign * 9999.0)
        }

        guard let augmented = augmentDockSwipe(ev) else { return false }

        guard let companion = CGEvent(source: nil) else { return false }
        companion.setIntegerValueField(kCGSEventTypeField, value: Int64(kCGSEventGesture.rawValue))

        markSynthetic(augmented)
        markSynthetic(companion)

        augmented.post(tap: .cgSessionEventTap)
        companion.post(tap: .cgSessionEventTap)

        return true
    }
}

extension Data {
    fileprivate mutating func put<T: FixedWidthInteger>(_ v: T) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
}

private func fixed1616(_ v: Double) -> Int32 {
    let f = Int32(v * 65536.0)
    if f == 0 && v != 0 { return v > 0 ? 1 : -1 }
    return f
}

private func iohidPayload(_ event: CGEvent) -> Data {
    let phase = event.getIntegerValueField(CGEventField(rawValue: 132)!)
    let motion = event.getIntegerValueField(CGEventField(rawValue: 123)!)
    let progress = event.getDoubleValueField(CGEventField(rawValue: 124)!)
    let posX = event.getDoubleValueField(CGEventField(rawValue: 125)!)
    let posY = event.getDoubleValueField(CGEventField(rawValue: 126)!)
    let velX = event.getDoubleValueField(CGEventField(rawValue: 129)!)
    let velY = event.getDoubleValueField(CGEventField(rawValue: 130)!)
    let mask = event.getIntegerValueField(CGEventField(rawValue: 115)!)

    let includeVelocity = velX != 0 || velY != 0 || phase == 4

    var d = Data()
    var ts = event.timestamp
    if ts == 0 { ts = mach_absolute_time() }
    d.put(UInt64(ts))
    d.put(UInt64(0))
    d.put(UInt32(0))
    d.put(UInt32(0))
    d.put(UInt32(includeVelocity ? 2 : 1))

    d.put(UInt32(40))
    d.put(UInt32(23))
    d.put(UInt32(truncatingIfNeeded: (phase & 0xFF) << 24))
    d.put(UInt8(0))
    d.append(contentsOf: [0, 0, 0] as [UInt8])
    d.put(fixed1616(posX))
    d.put(fixed1616(posY))
    d.put(Int32(0))
    d.put(UInt32(truncatingIfNeeded: mask))
    d.put(UInt16(truncatingIfNeeded: motion))
    d.put(UInt16(3))
    d.put(fixed1616(progress))

    if includeVelocity {
        d.put(UInt32(28))
        d.put(UInt32(9))
        d.put(UInt32(0))
        d.put(UInt8(1))
        d.append(contentsOf: [0, 0, 0] as [UInt8])
        d.put(fixed1616(velX))
        d.put(fixed1616(velY))
        d.put(Int32(0))
    }
    return d
}

private func augmentDockSwipe(_ event: CGEvent) -> CGEvent? {
    guard let cfData = event.data else { return nil }
    var bytes = [UInt8](cfData as Data)
    guard bytes.count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 2 else {
        return nil
    }
    let payload = iohidPayload(event)
    let len = payload.count
    bytes.append(UInt8((len >> 8) & 0xFF))
    bytes.append(UInt8(len & 0xFF))
    bytes.append(UInt8((4205 >> 8) & 0xFF))
    bytes.append(UInt8(4205 & 0xFF))
    bytes.append(contentsOf: payload)
    return CGEvent(withDataAllocator: nil, data: Data(bytes) as CFData)
}
