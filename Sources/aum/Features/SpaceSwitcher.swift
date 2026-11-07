import AppKit
import CoreGraphics
import Foundation

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

@_silgen_name("SLSGetActiveSpace")
func SLSGetActiveSpace(_ cid: Int32) -> UInt64

@_silgen_name("SLSCopyManagedDisplaySpaces")
func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?

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
  private static let backtickKey: Int64 = 50

  private static let repeatInterval: TimeInterval = 0.25
  private static let slotKeys: [Int64: (full: Bool, index: Int)] = [
    12: (false, 0), 13: (false, 1), 14: (false, 2), 2: (false, 3),
    18: (true, 0), 19: (true, 1), 20: (true, 2), 21: (true, 3),
  ]

  var syntheticEventsToPassThrough: Int = 0
  var lastGestureTime: CFAbsoluteTime = 0
  var swipeTracking = false

  private let stepWidth = 0.25
  private var stepsApplied = 0
  private var startSpace: UInt64 = 0
  private var frozenDesktops: [UInt64] = []
  private var frozenFullscreens: [UInt64] = []
  private var virtualFull = false
  private var virtualIndex = 0
  private var virtualSpace: UInt64 = 0
  private var expectedFinal: UInt64?
  private var desktopMRU: [UInt64] = []
  private var fullscreenMRU: [UInt64] = []
  private var knownSpaces: Set<UInt64> = []

  private var tabFull = false
  private var tabCode: Int64 = 0
  private var tabStart: UInt64 = 0
  private var tabSession = false
  private var tabHeld = false
  private var tabForward = true
  private var tabIndex = 0
  private var frozenAll: [SpaceInfo] = []
  private var repeatTimer: Timer?
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
    if let s = snap.spaces.first(where: { $0.id == snap.active }) {
      promote(s.id, isFull: s.isFull)
    }
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

  private func promote(_ id: UInt64, isFull: Bool) {
    desktopMRU.removeAll { !knownSpaces.contains($0) }
    fullscreenMRU.removeAll { !knownSpaces.contains($0) }
    if isFull {
      fullscreenMRU.removeAll { $0 == id }
      fullscreenMRU.insert(id, at: 0)
    } else {
      desktopMRU.removeAll { $0 == id }
      desktopMRU.insert(id, at: 0)
    }
  }

  private func ordered(_ mru: [UInt64], _ ids: [UInt64]) -> [UInt64] {
    var r = mru.filter { ids.contains($0) }
    for id in ids where !r.contains(id) { r.append(id) }
    return r
  }

  private func commit(_ info: SpaceInfo) {
    promote(info.id, isFull: info.isFull)
    expectedFinal = info.id
    lastGestureTime = CFAbsoluteTimeGetCurrent()
  }

  private func beginSwipe() -> Bool {
    guard let snap = snapshot() else { return false }
    let activeId = currentSpace(snap)
    guard let current = snap.spaces.first(where: { $0.id == activeId }) else { return false }

    promote(current.id, isFull: current.isFull)
    frozenDesktops = ordered(desktopMRU, snap.spaces.filter { !$0.isFull }.map(\.id))
    frozenFullscreens = ordered(fullscreenMRU, snap.spaces.filter { $0.isFull }.map(\.id))
    virtualFull = current.isFull
    virtualIndex = 0
    virtualSpace = current.id
    startSpace = current.id
    stepsApplied = 0
    expectedFinal = nil
    return true
  }

  private func endSwipe() {
    swipeTracking = false
    stepsApplied = 0
    guard virtualSpace != startSpace else { return }
    promote(virtualSpace, isFull: virtualFull)
    expectedFinal = virtualSpace
    lastGestureTime = CFAbsoluteTimeGetCurrent()
  }

  private func apply(progress: Double) {
    if progress == 0 { return }
    let n = (progress > 0 ? 1 : -1) * Int((abs(progress) / stepWidth).rounded(.up))
    while stepsApplied < n {
      stepsApplied += 1
      step(right: true)
    }
    while stepsApplied > n {
      stepsApplied -= 1
      step(right: false)
    }
  }

  private func step(right: Bool) {
    if right {
      if virtualFull {
        guard virtualIndex + 1 < frozenFullscreens.count else { return }
        virtualIndex += 1
      } else {
        guard !frozenFullscreens.isEmpty else { return }
        virtualFull = true
        virtualIndex = 0
      }
    } else {
      if !virtualFull {
        guard virtualIndex + 1 < frozenDesktops.count else { return }
        virtualIndex += 1
      } else {
        guard !frozenDesktops.isEmpty else { return }
        virtualFull = false
        virtualIndex = 0
      }
    }
    let list = virtualFull ? frozenFullscreens : frozenDesktops
    navigate(to: list[virtualIndex])
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

  private func beginTab(full: Bool, code: Int64) -> Bool {
    guard let snap = snapshot() else { return false }
    let activeId = currentSpace(snap)
    guard let current = snap.spaces.first(where: { $0.id == activeId }) else { return false }

    promote(current.id, isFull: current.isFull)
    let byId = Dictionary(snap.spaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let ids = snap.spaces.filter { $0.isFull == full }.map(\.id)
    frozenAll = ordered(full ? fullscreenMRU : desktopMRU, ids).compactMap { byId[$0] }
    tabIndex = current.isFull == full ? 0 : -1
    tabFull = full
    tabCode = code
    tabStart = current.id
    virtualSpace = current.id
    expectedFinal = nil
    tabSession = true
    return true
  }

  private func tabStep() {
    let n = frozenAll.count
    guard n > (tabIndex < 0 ? 0 : 1) else { return }
    if tabIndex < 0 {
      tabIndex = tabForward ? 0 : n - 1
    } else {
      tabIndex = (tabIndex + (tabForward ? 1 : n - 1)) % n
    }
    navigate(to: frozenAll[tabIndex].id)
  }

  private func armRepeat() {
    repeatTimer?.invalidate()
    repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatInterval, repeats: false) { _ in
      Task { @MainActor in SpaceSwitcher.shared.repeatTick() }
    }
  }

  private func repeatTick() {
    guard tabSession, tabHeld else { return }
    tabStep()
    armRepeat()
  }

  private func endTab() {
    repeatTimer?.invalidate()
    tabHeld = false
    guard tabSession else { return }
    tabSession = false
    if virtualSpace != tabStart, frozenAll.indices.contains(tabIndex) {
      commit(frozenAll[tabIndex])
    }
    frozenAll = []
    tabIndex = 0
  }

  private func jump(full: Bool, index: Int) {
    guard let snap = snapshot() else { return }
    let list = snap.spaces.filter { $0.isFull == full }
    guard list.indices.contains(index) else { return }
    let target = list[index]
    let current = currentSpace(snap)
    guard target.id != current else { return }
    virtualSpace = current
    navigate(to: target.id)
    commit(target)
  }

  private func handleKey(type: CGEventType, event: CGEvent) -> Bool {
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags

    switch type {
    case .keyDown:
      if code == Self.tabKey || code == Self.backtickKey,
        flags.contains(.maskCommand),
        flags.intersection([.maskControl, .maskAlternate]).isEmpty
      {
        swallowed.insert(code)
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return true }
        let full = code == Self.backtickKey
        if tabSession && (tabFull != full) { endTab() }
        if !tabSession && !beginTab(full: full, code: code) { return true }
        tabHeld = true
        tabForward = !flags.contains(.maskShift)
        tabStep()
        armRepeat()
        return true
      }
      return false

    case .keyUp:
      guard swallowed.remove(code) != nil else { return false }
      if tabSession && code == tabCode { endTab() }
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
            if stepsApplied == 0 {
              let velocity = event.getDoubleValueField(kCGEventGestureSwipeVelocityX)
              if velocity != 0.0 { step(right: velocity > 0) }
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
