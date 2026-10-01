import CoreFoundation
import CoreGraphics
import Foundation

@MainActor class CGEventListener {
  static let shared = CGEventListener()

  private static let kCGSEventTypeField = CGEventField(rawValue: 55)!
  private static let kCGEventGestureHIDType = CGEventField(rawValue: 110)!
  private static let kCGEventGestureSwipeMotion = CGEventField(rawValue: 123)!
  private static let kCGEventGestureSwipeProgress = CGEventField(rawValue: 124)!
  private static let kCGEventGestureSwipeVelocityX = CGEventField(rawValue: 129)!
  private static let kCGEventGesturePhase = CGEventField(rawValue: 132)!

  private static let kIOHIDEventTypeDockSwipe: Int64 = 23
  private static let kCGSEventDockControl: CGEventType = CGEventType(rawValue: 30)!
  private static let kCGSEventGesture: CGEventType = CGEventType(rawValue: 29)!
  private static let kCGGestureMotionHorizontal: Int64 = 1

  private static let kCapsLockKeyCode: Int64 = 57
  private static let kCGMouseButtonCenter = Int64(CGMouseButton.center.rawValue)

  enum CGSGesturePhase: Int64 {
    case began = 1
    case changed = 2
    case ended = 4
    case cancelled = 8
  }

  private static let config = Config.shared
  private static let state = GlobalState.shared

  private static var swipeTracking = false
  private static var swipeFired = false

  private var eventTap: CFMachPort?
  private var runLoopSrc: CFRunLoopSource?

  private let eventTapCallback: CGEventTapCallBack = { _, type, event, _ in
    CGEventListener.handle(type: type, event: event)
  }

  static func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    let returnedEvent = Unmanaged.passUnretained(event)

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      state.syntheticEventsToPassThrough = 0
      shared.reenable()
      return returnedEvent
    }
    if type == .keyDown && Hotkeys.handle(event) { return nil }

    if type == .scrollWheel {
      let rotation = TouchHandler.shared.currentRotation
      if rotation != 0 {
        let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let dx = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let ptDy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let ptDx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let pointDy = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let pointDx = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)

        let (newDx, newDy): (Int64, Int64)
        let (newPtDx, newPtDy): (Double, Double)
        let (newPointDx, newPointDy): (Int64, Int64)

        switch rotation {
        case 90:
          newDx = -dy
          newDy = dx
          newPtDx = -ptDy
          newPtDy = ptDx
          newPointDx = -pointDy
          newPointDy = pointDx
        case 180:
          newDx = -dx
          newDy = -dy
          newPtDx = -ptDx
          newPtDy = -ptDy
          newPointDx = -pointDx
          newPointDy = -pointDy
        case 270:
          newDx = dy
          newDy = -dx
          newPtDx = ptDy
          newPtDy = -ptDx
          newPointDx = pointDy
          newPointDy = -pointDx
        default:
          newDx = dx
          newDy = dy
          newPtDx = ptDx
          newPtDy = ptDy
          newPointDx = pointDx
          newPointDy = pointDy
        }
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: newDy)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: newDx)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: newPtDy)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: newPtDx)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: newPointDy)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: newPointDx)
      }
      return returnedEvent
    }

    if state.syntheticEventsToPassThrough > 0
      && CFAbsoluteTimeGetCurrent() - SpaceSwitcher.lastGestureTime >= 1.0
    {
      state.syntheticEventsToPassThrough = 0
    }
    if state.syntheticEventsToPassThrough > 0
      && (type == kCGSEventDockControl || type == kCGSEventGesture)
    {
      state.syntheticEventsToPassThrough -= 1
      return returnedEvent
    }
    if config.middleClick {
      if state.threeDown && (type == .leftMouseDown || type == .rightMouseDown) {
        state.wasThreeDown = true
        state.threeDown = false
        state.naturalMiddleClickLastTime = Date()
        event.type = .otherMouseDown
        event.setIntegerValueField(.mouseEventButtonNumber, value: kCGMouseButtonCenter)
      }
      if state.wasThreeDown && (type == .leftMouseUp || type == .rightMouseUp) {
        state.wasThreeDown = false
        event.type = .otherMouseUp
        event.setIntegerValueField(.mouseEventButtonNumber, value: kCGMouseButtonCenter)
      }
    }
    if config.capsLockSwitcher && type == .flagsChanged {
      let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
      if keyCode == kCapsLockKeyCode {
        if event.flags.contains(.maskAlphaShift) {
          switchToNextInputSource()
        }
        return nil
      }
    }
    if config.instantSpaces {
      if type == kCGSEventDockControl || type == kCGSEventGesture {
        let sourcePid = event.getIntegerValueField(.eventSourceUnixProcessID)
        if sourcePid != 0 {
          return returnedEvent
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
              return nil

            case 2:
              if !swipeTracking { return returnedEvent }
              if !swipeFired {
                let progress = event.getDoubleValueField(kCGEventGestureSwipeProgress)
                if progress != 0.0 {
                  swipeFired = true
                  SpaceSwitcher.focusSpace(right: progress > 0)
                }
              }
              return nil

            case 4:
              if !swipeTracking { return returnedEvent }
              if !swipeFired {
                let velocity = event.getDoubleValueField(kCGEventGestureSwipeVelocityX)
                if velocity != 0.0 {
                  swipeFired = true
                  SpaceSwitcher.focusSpace(right: velocity > 0)
                }
              }
              swipeTracking = false
              swipeFired = false
              event.setDoubleValueField(kCGEventGestureSwipeProgress, value: 0.0)
              event.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: 0.0)
              event.setDoubleValueField(CGEventField(rawValue: 130)!, value: 0.0)
              return returnedEvent

            case 8:
              swipeTracking = false
              swipeFired = false
              return nil

            default:
              return swipeTracking ? nil : returnedEvent
            }
          }
        }
      }
      if type == kCGSEventGesture && swipeTracking {
        return nil
      }
    }
    return returnedEvent
  }

  func start() -> Bool {
    if eventTap != nil && CFMachPortIsValid(eventTap) && runLoopSrc != nil {
      return true
    }

    stop()

    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: .from(
          .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
          .scrollWheel,
          .flagsChanged, .keyDown, .keyUp, Self.kCGSEventDockControl, Self.kCGSEventGesture
        ),
        callback: eventTapCallback,
        userInfo: nil
      )
    else {
      print("Failed to create event tap (check accessibility permission).")
      return false
    }

    guard let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
      CFMachPortInvalidate(tap)
      return false
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    self.eventTap = tap
    self.runLoopSrc = src
    return true
  }

  func stop() {
    if let tap = eventTap {
      CGEvent.tapEnable(tap: tap, enable: false)
      if let src = runLoopSrc {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
      }
      CFMachPortInvalidate(tap)
    }
    eventTap = nil
    runLoopSrc = nil
  }

  func reenable() {
    if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
  }
}

extension CGEventMask {
  fileprivate static func from(_ types: CGEventType...) -> Self {
    var mask: UInt64 = 0

    for type in types {
      mask |= (1 << type.rawValue)
    }

    return Self(mask)
  }
}
