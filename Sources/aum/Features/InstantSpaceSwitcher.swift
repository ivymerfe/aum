import CoreGraphics
import Foundation

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

@_silgen_name("SLSGetActiveSpace")
func SLSGetActiveSpace(_ cid: Int32) -> UInt64

@_silgen_name("SLSCopyManagedDisplaySpaces")
func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?

@MainActor final class InstantSpaceSwitcher {
  static let shared = InstantSpaceSwitcher()

  private static var isNaturalScrollingEnabled: Bool {
    let key = "com.apple.swipescrolldirection" as CFString
    let domain = kCFPreferencesAnyApplication
    var valid: DarwinBoolean = false
    let value = CFPreferencesGetAppBooleanValue(key, domain, &valid)
    return valid.boolValue ? value : true
  }

  var syntheticEventsToPassThrough: Int = 0
  var lastGestureTime: CFAbsoluteTime = 0
  var swipeTracking = false
  var swipeFired = false

  func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    guard Config.shared.instantSpaceSwitcher else { return false }

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
            swipeTracking = true
            swipeFired = false
            return true

          case 2:
            if !swipeTracking { return false }
            if !swipeFired {
              let progress = event.getDoubleValueField(kCGEventGestureSwipeProgress)
              if progress != 0.0 {
                swipeFired = true
                focusSpace(right: progress > 0)
              }
            }
            return true

          case 4:
            if !swipeTracking { return false }
            if !swipeFired {
              let velocity = event.getDoubleValueField(kCGEventGestureSwipeVelocityX)
              if velocity != 0.0 {
                swipeFired = true
                focusSpace(right: velocity > 0)
              }
            }
            swipeTracking = false
            swipeFired = false
            event.setDoubleValueField(kCGEventGestureSwipeProgress, value: 0.0)
            event.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: 0.0)
            event.setDoubleValueField(CGEventField(rawValue: 130)!, value: 0.0)
            return false

          case 8:
            swipeTracking = false
            swipeFired = false
            return true

          default:
            return swipeTracking ? true : false
          }
        }
      }
    }
    if type == kCGSEventGesture && swipeTracking {
      return true
    }
    return false
  }

  @discardableResult
  func focusSpace(right: Bool) -> Bool {
    let cid = CGSMainConnectionID()
    guard cid != 0 else { return false }

    let activeSpace = SLSGetActiveSpace(cid)

    guard let unmanagedDisplays = SLSCopyManagedDisplaySpaces(cid) else { return false }
    let cfDisplays = unmanagedDisplays.takeRetainedValue()
    guard let displays = cfDisplays as? [[String: Any]] else { return false }

    for display in displays {
      guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
      if let currentIndex = spaces.firstIndex(where: {
        ($0["id64"] as? UInt64) == activeSpace
      }) {
        let targetIndex = right ? currentIndex + 1 : currentIndex - 1

        if targetIndex >= 0 && targetIndex < spaces.count {
          lastGestureTime = CFAbsoluteTimeGetCurrent()
          let b = postSwipe(phase: .began, right: right)
          let c = postSwipe(phase: .changed, right: right)
          let e = postSwipe(phase: .ended, right: right)
          return b && c && e
        }
      }
    }
    return false
  }

  func postSwipe(phase: CGSGesturePhase, right: Bool) -> Bool {
    let isNatural = Self.isNaturalScrollingEnabled
    let baseSign: Double = right ? -1.0 : 1.0
    let sign: Double = isNatural ? baseSign : -baseSign

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
