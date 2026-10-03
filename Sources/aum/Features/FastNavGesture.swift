import CoreGraphics
import Foundation
import AppKit

@MainActor final class FastNavGesture {
  static let shared = FastNavGesture()

  var navTracking = false
  var navTouching = false
  var navLocked = false
  var navFired = false
  var navStart = CGPoint.zero

  var navStartTime: TimeInterval = 0
  var navStartDist: CGFloat = 0
  var navLastFire: TimeInterval = 0
  var navCancelled = false

  func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    guard Config.shared.fastNavGesture else { return false }

    if type == .scrollWheel {
      if navLocked
        && (navTouching || event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0)
      {
        return true
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
      navTouching = false
      navTracking = false
      navFired = false
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
      navFired = false
      navCancelled = false
      navStart = c
      navStartDist = dist
      navStartTime = now
      return
    }

    if navFired || navCancelled { return }

    let elapsed = now - navStartTime
    let dx = c.x - navStart.x
    let dy = c.y - navStart.y
    let adx = abs(dx)
    let ady = abs(dy)

    if abs(dist - navStartDist) > 0.05 || ady > 0.04 || elapsed > 0.15 {
      navCancelled = true
      return
    }

    guard adx > 0.05, adx > ady * 3 else { return }

    let velocity = adx / CGFloat(max(elapsed, 0.001))
    guard velocity > 0.3 else {
      navCancelled = true
      return
    }

    guard now - navLastFire > 0.35 else { return }
    navFired = true
    navLastFire = now
    let code: CGKeyCode = dx > 0 ? 33 : 30
    for down in [true, false] {
      let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
      e?.flags = .maskCommand
      e?.post(tap: .cgSessionEventTap)
    }
  }
}
