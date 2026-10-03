import AppKit
import CoreGraphics
import Foundation

@MainActor final class FastNavGesture {
  static let shared = FastNavGesture()

  var navTracking = false
  var navTouching = false
  var navCancelled = false
  var navStart = CGPoint.zero
  var navStartTime: TimeInterval = 0
  var navStartDist: CGFloat = 0
  var navLast = CGPoint.zero
  var navLastTime: TimeInterval = 0

  func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    guard Config.shared.fastNavGesture else { return false }

    if type == .scrollWheel {
      if navTouching && !navCancelled {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
      }
    }
    if type == kCGSEventGesture {
      handleNavGesture(event)
      return true
    }
    return false
  }

  private func handleNavGesture(_ event: CGEvent) {
    guard event.getIntegerValueField(kCGEventGestureHIDType) == 0 else { return }
    guard let ns = NSEvent(cgEvent: event) else { return }

    let touches = Array(ns.touches(matching: .touching, in: nil))
    guard touches.count == 2 else {
      if touches.count < 2 && navTracking && !navCancelled {
        let dx = navLast.x - navStart.x
        let dy = navLast.y - navStart.y
        let elapsed = navLastTime - navStartTime
        let adx = abs(dx)
        let ady = abs(dy)
        if adx > ady * 2, ady <= 0.02, elapsed <= 0.2
        {
          fireNav(dx > 0 ? 33 : 30)
        }
      }
      navTouching = false
      navTracking = false
      navCancelled = false
      return
    }
    let a = touches[0].normalizedPosition
    let (ax, ay) = BetterScreenRotation.shared.rotate(x: a.x, y: -a.y)
    let b = touches[1].normalizedPosition
    let (bx, by) = BetterScreenRotation.shared.rotate(x: b.x, y: -b.y)
    let c = CGPoint(x: (ax + bx) / 2, y: (ay + by) / 2)
    let dist = hypot(ax - bx, ay - by)
    let now = ProcessInfo.processInfo.systemUptime
    navTouching = true
    if !navTracking {
      navTracking = true
      navCancelled = false
      navStart = c
      navStartDist = dist
      navStartTime = now
      navLast = c
      navLastTime = now
      return
    }
    if navCancelled { return }

    if abs(dist - navStartDist) > 0.1 || abs(c.y - navStart.y) > 0.02 || now - navStartTime > 0.2 {
      navCancelled = true
      return
    }
    navLast = c
    navLastTime = now
  }

  private func fireNav(_ code: CGKeyCode) {
    for down in [true, false] {
      let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
      e?.flags = .maskCommand
      e?.post(tap: .cgSessionEventTap)
    }
  }
}
