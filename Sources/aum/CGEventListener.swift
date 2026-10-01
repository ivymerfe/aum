import AppKit
import CoreFoundation
import CoreGraphics
import Foundation

extension CGEventMask {
  fileprivate static func from(_ types: CGEventType...) -> Self {
    var mask: UInt64 = 0

    for type in types {
      mask |= (1 << type.rawValue)
    }

    return Self(mask)
  }
}

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
  private static var navTracking = false
  private static var navTouching = false
  private static var navLocked = false
  private static var navFired = false
  private static var navStart = CGPoint.zero

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
      log.info("Failed to create event tap (check accessibility permission).")
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

  private static func handleNavGesture(_ event: CGEvent) {
    guard event.getIntegerValueField(kCGEventGestureHIDType) == 0 else { return }

    guard let ns = NSEvent(cgEvent: event) else { return }

    let touches = Array(ns.touches(matching: .touching, in: nil))
    guard touches.count == 2 else {
      navTouching = false
      navTracking = false
      navFired = false
      return
    }
    let a = touches[0].normalizedPosition
    let (ax, ay) = TouchHandler.rotate(x: a.x, y: -a.y)
    let b = touches[1].normalizedPosition
    let (bx, by) = TouchHandler.rotate(x: b.x, y: -b.y)
    let c = CGPoint(x: (ax + bx) / 2, y: (ay + by) / 2)
    navTouching = true
    if !navTracking {
      navTracking = true
      navFired = false
      navLocked = false
      navStart = c
      return
    }
    let dx = c.x - navStart.x
    let dy = c.y - navStart.y
    if !navLocked && abs(dx) > 0.04 && abs(dx) > abs(dy) * 2 { navLocked = true }
    if navLocked && !navFired && abs(dx) > 0.06 {
      navFired = true
      let code: CGKeyCode = dx > 0 ? 33 : 30
      for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        e?.flags = .maskCommand
        e?.post(tap: .cgSessionEventTap)
      }
    }
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
      if navLocked
        && (navTouching || event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0)
      {
        return nil
      }
      let rotation = TouchHandler.shared.currentRotation
      if rotation != 0 {
        let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let dx = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let ptDy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let ptDx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let pointDy = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let pointDx = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)

        let (newDx, newDy) = TouchHandler.rotate(x: dx, y: dy)
        let (newPtDx, newPtDy) = TouchHandler.rotate(x: ptDx, y: ptDy)
        let (newPointDx, newPointDy) = TouchHandler.rotate(x: pointDx, y: pointDy)

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
    if type == kCGSEventGesture {
      handleNavGesture(event)
      // I dont know how to rotate touches inside gesture event
      return nil
    }
    if type == kCGSEventDockControl {
      let rotation = TouchHandler.shared.currentRotation
      if rotation != 0,
        event.getIntegerValueField(kCGEventGestureHIDType) == kIOHIDEventTypeDockSwipe
      {
        let motion = event.getIntegerValueField(kCGEventGestureSwipeMotion)
        if motion == 1 || motion == 2 {
          let horizontal = motion == 1
          let (ux, uy) = TouchHandler.rotate(x: horizontal ? 1.0 : 0.0, y: horizontal ? 0.0 : -1.0)
          let newMotion: Int64 = abs(ux) > 0.5 ? 1 : 2
          let sign = newMotion == 1 ? ux : -uy

          let progress = event.getDoubleValueField(kCGEventGestureSwipeProgress)
          let vx = event.getDoubleValueField(kCGEventGestureSwipeVelocityX)
          let vy = event.getDoubleValueField(CGEventField(rawValue: 130)!)
          let (rx, ry) = TouchHandler.rotate(x: vx, y: -vy)

          event.setIntegerValueField(kCGEventGestureSwipeMotion, value: newMotion)
          event.setDoubleValueField(kCGEventGestureSwipeProgress, value: progress * sign)
          event.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: rx)
          event.setDoubleValueField(CGEventField(rawValue: 130)!, value: -ry)
        }
      }
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
}
