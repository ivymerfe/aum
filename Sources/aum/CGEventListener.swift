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

  private var eventTap: CFMachPort?
  private var runLoopSrc: CFRunLoopSource?

  private static var swipeTracking = false
  private static var swipeFired = false

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
        let hidType = event.getIntegerValueField(CGEventField(rawValue: 110)!)
        if hidType == 23 {
          let motion = event.getIntegerValueField(CGEventField(rawValue: 123)!)
          if motion == 1 {
            let phaseRaw = event.getIntegerValueField(CGEventField(rawValue: 132)!)

            switch phaseRaw {
            case 1:
              swipeTracking = true
              swipeFired = false
              return nil

            case 2:
              if !swipeTracking { return returnedEvent }
              if !swipeFired {
                let progress = event.getDoubleValueField(
                  CGEventField(rawValue: 124)!)
                if progress != 0.0 {
                  swipeFired = true
                  SpaceSwitcher.focusSpace(right: progress > 0)
                }
              }
              return nil

            case 4:
              if !swipeTracking { return returnedEvent }
              if !swipeFired {
                let velocity = event.getDoubleValueField(
                  CGEventField(rawValue: 129)!)
                if velocity != 0.0 {
                  swipeFired = true
                  SpaceSwitcher.focusSpace(right: velocity > 0)
                }
              }
              swipeTracking = false
              swipeFired = false
              event.setDoubleValueField(CGEventField(rawValue: 124)!, value: 0.0)
              event.setDoubleValueField(CGEventField(rawValue: 129)!, value: 0.0)
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
    // If we already have a valid tap, don’t install another one
    if eventTap != nil && CFMachPortIsValid(eventTap) && runLoopSrc != nil {
      print("Mouse callback already registered.")
      return true
    }

    // Ensure any previous state is cleaned up before creating a new one
    stop()

    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: .from(
          .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
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
      print("Failed to create RunLoop source for event tap.")
      CFMachPortInvalidate(tap)  // Clean up the tap if source creation fails
      return false
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    self.eventTap = tap
    self.runLoopSrc = src

    print("Successfully registered mouse callback.")
    return true
  }

  func stop() {
    // Use guard to safely unwrap and validate the eventTap
    guard let tap = eventTap, CFMachPortIsValid(tap) else {
      // This block executes if eventTap is nil OR if eventTap exists but is invalid.
      // We can add specific logging if needed, but the main goal is cleanup.
      if eventTap != nil {
        // This means eventTap existed but was invalid
        print("Event tap was invalid, cleaning up.")
      } else {
        // This means eventTap was nil
        // print("No event tap found to unregister (was nil).") // Optional logging
      }

      // Ensure state is clean regardless of why the guard failed
      eventTap = nil
      runLoopSrc = nil  // If the tap is gone/invalid, the source is useless
      return  // Exit the function
    }

    // --- If guard passes, 'tap' is guaranteed non-nil and valid ---

    // Disable the tap first
    CGEvent.tapEnable(tap: tap, enable: false)

    // Remove the source from the run loop *if it exists*
    // (It should exist if 'tap' was valid, but check for safety)
    if let src = runLoopSrc {
      CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
      // CFRunLoopRemoveSource handles releasing the source
      self.runLoopSrc = nil  // Clear our reference
    } else {
      print("RunLoop source was unexpectedly nil during unregister for a valid tap.")
    }

    // Invalidate the underlying Mach port
    CFMachPortInvalidate(tap)
    // CFMachPortInvalidate handles releasing the port
    self.eventTap = nil  // Clear our reference

    print("Successfully unregistered mouse callback.")
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
