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
    if swipeTracking { return }
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

  private func beginSwipe() -> Bool {
    guard let snap = snapshot(),
      let current = snap.spaces.first(where: { $0.id == snap.active })
    else { return false }

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

  func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    guard Config.shared.spaceSwitcher else { return false }

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
