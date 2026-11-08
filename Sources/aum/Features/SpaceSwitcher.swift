import AppKit
import ApplicationServices
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
  case left
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
  let all: Set<UInt64>
}

@MainActor final class SpaceSwitcher {
  static let shared = SpaceSwitcher()

  private static let tabKey: Int64 = 48
  private static let tabHold: TimeInterval = 0.5
  private static let groupKeys: [Int64: SpaceKind] = [13: .left, 14: .full, 15: .desktop]
  private static let digitKeys: [Int64: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4]
  private static let leftBundles: Set<String> = [
    "com.brave.Browser", "com.apple.finder", "com.googlecode.iterm2",
  ]

  var syntheticEventsToPassThrough: Int = 0
  var lastGestureTime: CFAbsoluteTime = 0
  var swipeTracking = false

  private var stepsApplied = 0
  private var startSpace: UInt64 = 0
  private var frozenLeft: [UInt64] = []
  private var frozenRight: [UInt64] = []
  private var virtualInLeft = false
  private var virtualSpace: UInt64 = 0
  private var expectedFinal: UInt64?
  private var allMRU: [UInt64] = []
  private var knownSpaces: Set<UInt64> = []

  private static let gestureHold: TimeInterval = 0.5
  private static let deadZone = 0.05
  private var gestureSession = false
  private var gestureEnd: CFAbsoluteTime = 0
  private var swipeMoved = false

  private var tabSession = false
  private var tabForward = true
  private var tabIndex = 0
  private var tabStart: UInt64 = 0
  private var expireTimer: Timer?

  private var frozenAll: [UInt64] = []
  private var swallowed: Set<Int64> = []

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

  private func spaceChanged() {
    guard let snap = snapshot() else { return }
    if swipeTracking || tabSession { return }
    if gestureSession && CFAbsoluteTimeGetCurrent() - gestureEnd < Self.gestureHold { return }
    if let expected = expectedFinal {
      if CFAbsoluteTimeGetCurrent() - lastGestureTime > 1.5 {
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

  private func currentSpace(_ snap: SpaceSnapshot) -> UInt64 {
    if expectedFinal != nil && CFAbsoluteTimeGetCurrent() - lastGestureTime < 1.5 {
      return virtualSpace
    }
    return snap.active
  }

  private func snapshot() -> SpaceSnapshot? {
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
    return SpaceSnapshot(spaces: spaces, active: active, all: all)
  }

  private func classify(_ snap: SpaceSnapshot) -> [UInt64: SpaceKind] {
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
      guard let name = bundle, Self.leftBundles.contains(name) else { continue }
      let arr = [NSNumber(value: id)] as CFArray
      guard let raw = SLSCopySpacesForWindows(cid, 0x7, arr)?.takeRetainedValue() else {
        continue
      }
      for s in (raw as NSArray).compactMap({ ($0 as? NSNumber)?.uint64Value })
      where fullIds.contains(s) {
        kinds[s] = .left
      }
    }
    return kinds
  }

  private func promote(_ id: UInt64) {
    allMRU.removeAll { !knownSpaces.contains($0) }
    allMRU.removeAll { $0 == id }
    allMRU.insert(id, at: 0)
  }

  private func ordered(_ mru: [UInt64], _ ids: [UInt64]) -> [UInt64] {
    var r = mru.filter { ids.contains($0) }
    for id in ids where !r.contains(id) { r.append(id) }
    return r
  }

  private func commit(_ id: UInt64) {
    gestureSession = false
    promote(id)
    expectedFinal = id
    lastGestureTime = CFAbsoluteTimeGetCurrent()
  }

  private func navigate(to target: UInt64) {
    guard let snap = snapshot(),
      let from = snap.spaces.firstIndex(where: { $0.id == virtualSpace }),
      let to = snap.spaces.firstIndex(where: { $0.id == target })
    else { return }
    let delta = to - from
    guard delta != 0 else { return }
    lastGestureTime = CFAbsoluteTimeGetCurrent()
    virtualSpace = target
    _ = focusRelative(right: delta > 0, count: abs(delta))
  }
  private func beginSwipe() -> Bool {
    guard let snap = snapshot() else { return false }
    let now = CFAbsoluteTimeGetCurrent()
    let reuse = gestureSession && now - gestureEnd < Self.gestureHold
    let cur = reuse ? virtualSpace : currentSpace(snap)
    guard snap.spaces.contains(where: { $0.id == cur }) else { return false }

    if !(reuse && (frozenLeft.contains(cur) || frozenRight.contains(cur))) {
      let kinds = classify(snap)
      promote(cur)
      let sorted = ordered(allMRU, snap.spaces.map(\.id))
      frozenLeft = sorted.filter { kinds[$0] == .left }
      frozenRight = sorted.filter { kinds[$0] != .left }
      expectedFinal = nil
      gestureSession = true
      gestureEnd = now
    }
    virtualSpace = cur
    startSpace = cur
    stepsApplied = 0
    swipeMoved = false
    return true
  }

  private func endSwipe() {
    swipeTracking = false
    stepsApplied = 0
    guard virtualSpace != startSpace else { return }
    let now = CFAbsoluteTimeGetCurrent()
    gestureEnd = now
    lastGestureTime = now
    expectedFinal = virtualSpace
  }

  private func apply(progress: Double) {
    let n = abs(progress) < Self.deadZone ? 0 : (progress > 0 ? 1 : -1)
    setSteps(n)
  }

  private func setSteps(_ n: Int) {
    guard n != stepsApplied else { return }
    stepsApplied = n
    if n != 0 { swipeMoved = true }
    navigate(to: target(for: n))
  }

  private func target(for n: Int) -> UInt64 {
    if n == 0 { return startSpace }
    let list = (n > 0 ? frozenRight : frozenLeft).filter { knownSpaces.contains($0) }
    guard !list.isEmpty else { return startSpace }
    if let i = list.firstIndex(of: startSpace) { return list[min(i + 1, list.count - 1)] }
    return list[0]
  }

  private func beginTab() -> Bool {
    guard let snap = snapshot() else { return false }
    let cur = currentSpace(snap)
    guard snap.spaces.contains(where: { $0.id == cur }) else { return false }

    promote(cur)
    frozenAll = ordered(allMRU, snap.spaces.map(\.id))
    tabIndex = 0
    tabStart = cur
    virtualSpace = cur
    expectedFinal = nil
    tabSession = true
    return true
  }

  private func tabStep() {
    let n = frozenAll.count
    guard n > 1 else { return }
    tabIndex = (tabIndex + (tabForward ? 1 : n - 1)) % n
    navigate(to: frozenAll[tabIndex])
  }

  private func armExpire() {
    expireTimer?.invalidate()
    expireTimer = Timer.scheduledTimer(withTimeInterval: Self.tabHold, repeats: false) { _ in
      Task { @MainActor in SpaceSwitcher.shared.endTab() }
    }
  }

  private func endTab() {
    expireTimer?.invalidate()
    guard tabSession else { return }
    tabSession = false
    if virtualSpace != tabStart { commit(virtualSpace) }
    frozenAll = []
    tabIndex = 0
  }

  private func go(from cur: UInt64, to target: UInt64) {
    guard target != cur else { return }
    promote(cur)
    virtualSpace = cur
    navigate(to: target)
    commit(target)
  }

  private func cycle(_ kind: SpaceKind, forward: Bool) {
    guard let snap = snapshot() else { return }
    let kinds = classify(snap)
    let cur = currentSpace(snap)
    promote(cur)
    let ids = snap.spaces.map(\.id).filter { kinds[$0] == kind }
    let list = ordered(allMRU, ids)
    guard !list.isEmpty else { return }
    let inGroup = list.first == cur
    let target: UInt64
    if forward {
      target = inGroup ? (list.count > 1 ? list[1] : cur) : list[0]
    } else {
      target = list.last!
    }
    go(from: cur, to: target)
  }

  private func jump(index: Int) {
    guard let snap = snapshot() else { return }
    let kinds = classify(snap)
    let cur = currentSpace(snap)
    guard let kind = kinds[cur] else { return }
    let list = snap.spaces.map(\.id).filter { kinds[$0] == kind }
    guard list.indices.contains(index) else { return }
    go(from: cur, to: list[index])
  }

  private func toggleFullscreen() {
    guard let app = NSWorkspace.shared.frontmostApplication else { return }
    let el = AXUIElementCreateApplication(app.processIdentifier)
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &raw) == .success,
      let value = raw,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return }
    let win = value as! AXUIElement
    var cur: CFTypeRef?
    AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &cur)
    let on = (cur as? Bool) ?? false
    gestureSession = false
    AXUIElementSetAttributeValue(
      win, "AXFullScreen" as CFString, on ? kCFBooleanFalse : kCFBooleanTrue)
  }

  private func handleKey(type: CGEventType, event: CGEvent) -> Bool {
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

    switch type {
    case .keyDown:
      if code == Self.tabKey,
        flags.contains(.maskCommand),
        flags.intersection([.maskControl, .maskAlternate]).isEmpty
      {
        swallowed.insert(code)
        if isRepeat { return true }
        if !tabSession && !beginTab() { return true }
        tabForward = !flags.contains(.maskShift)
        tabStep()
        armExpire()
        return true
      }
      guard flags.contains(.maskAlternate),
        flags.intersection([.maskCommand, .maskControl]).isEmpty
      else { return false }
      if let kind = Self.groupKeys[code] {
        swallowed.insert(code)
        if !isRepeat { cycle(kind, forward: !flags.contains(.maskShift)) }
        return true
      }
      if code == 3, !flags.contains(.maskShift) {
        swallowed.insert(code)
        if !isRepeat { toggleFullscreen() }
        return true
      }
      if !flags.contains(.maskShift), let index = Self.digitKeys[code] {
        swallowed.insert(code)
        if !isRepeat { jump(index: index) }
        return true
      }
      return false

    case .keyUp:
      guard swallowed.remove(code) != nil else { return false }
      return true

    case .flagsChanged:
      if tabSession {
        if flags.contains(.maskCommand) {
          tabForward = !flags.contains(.maskShift)
        } else {
          endTab()
        }
      }
      return false

    default:
      return false
    }
  }

  func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    guard Config.shared.spaceSwitcher else { return false }

    if type == .keyDown || type == .keyUp || type == .flagsChanged {
      return handleKey(type: type, event: event)
    }

    if syntheticEventsToPassThrough > 0
      && CFAbsoluteTimeGetCurrent() - lastGestureTime >= 1.0
    {
      syntheticEventsToPassThrough = 0
    }
    if syntheticEventsToPassThrough > 0
      && (type == kCGSEventDockControl || type == kCGSEventGesture)
    {
      syntheticEventsToPassThrough -= 1
      return false
    }
    if type == kCGSEventDockControl || type == kCGSEventGesture {
      let sourcePid = event.getIntegerValueField(.eventSourceUnixProcessID)
      if sourcePid != 0 {
        return false
      }
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

    syntheticEventsToPassThrough += 2

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
