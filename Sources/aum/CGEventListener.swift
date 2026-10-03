import CoreFoundation
import CoreGraphics
import Foundation

let kCGSEventTypeField = CGEventField(rawValue: 55)!
let kCGEventGestureHIDType = CGEventField(rawValue: 110)!
let kCGEventGestureSwipeMotion = CGEventField(rawValue: 123)!
let kCGEventGestureSwipeProgress = CGEventField(rawValue: 124)!
let kCGEventGestureSwipePositionX: CGEventField = CGEventField(rawValue: 125)!
let kCGEventGestureSwipeVelocityX = CGEventField(rawValue: 129)!
let kCGEventGesturePhase = CGEventField(rawValue: 132)!
let kCGEventGesturePhaseAlias: CGEventField = CGEventField(rawValue: 134)!
let kCGEventGestureZoomDeltaY: CGEventField = CGEventField(rawValue: 138)!
let kCGEventSourceUnixProcessIDAlias: CGEventField = CGEventField(rawValue: 169)!

let kIOHIDEventTypeDockSwipe: Int64 = 23
let kCGSEventDockControl: CGEventType = CGEventType(rawValue: 30)!
let kCGSEventGesture: CGEventType = CGEventType(rawValue: 29)!
let kCGGestureMotionHorizontal: Int64 = 1
let kCGMouseButtonCenter = Int64(CGMouseButton.center.rawValue)
let kCGMouseButtonRight = Int64(CGMouseButton.right.rawValue)

enum CGSGesturePhase: Int64 {
  case began = 1
  case changed = 2
  case ended = 4
  case cancelled = 8
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

@MainActor class CGEventListener {
  static let shared = CGEventListener()
  static let config = Config.shared

  private var eventTap: CFMachPort?
  private var runLoopSrc: CFRunLoopSource?

  private init() {
  }

  private let eventTapCallback: CGEventTapCallBack = {
    _, type, event, _ in
    
    let returnedEvent = Unmanaged.passUnretained(event)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      InstantSpaceSwitcher.shared.syntheticEventsToPassThrough = 0
      shared.reenable()
      return returnedEvent
    }
    if BetterLayoutSwitcher.shared.handleEvent(type: type, event: event) {
      return nil
    }
    if BetterRightClick.shared.handleEvent(type: type, event: event) {
      return nil
    }
    if BetterScreenRotation.shared.handleEvent(type: type, event: event) {
      return nil
    }
    if FastNavGesture.shared.handleEvent(type: type, event: event) {
      return nil
    }
    if InstantSpaceSwitcher.shared.handleEvent(type: type, event: event) {
      return nil
    }
    if MiddleClickEmu.shared.handleEvent(type: type, event: event) {
      return nil
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
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: .from(
          .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
          .scrollWheel,
          .flagsChanged, .keyDown, .keyUp, kCGSEventDockControl, kCGSEventGesture
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
}
