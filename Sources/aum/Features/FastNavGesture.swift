import AppKit
import CoreGraphics
import Foundation

@MainActor final class FastNavGesture {
  static let shared = FastNavGesture()

  private static let kLeftBracketKeyCode: UInt16 = 33
  private static let kRightBracketKeyCode: UInt16 = 30

  private static let gestureDelta = 0.06
  private static let invert = false

  var tracking = false
  var fired = false
  var startY: CGFloat = 0

  func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    guard Config.shared.fastNavGesture else { return false }
    guard type == kCGSEventGesture else { return false }
    guard event.getIntegerValueField(kCGEventGestureHIDType) == 0 else { return false }
    guard let ns = NSEvent(cgEvent: event) else { return false }

    let touches = Array(ns.touches(matching: .touching, in: nil))
    guard touches.count == 3 else {
      tracking = false
      fired = false
      return false
    }

    let y = touches.reduce(0) { $0 + $1.normalizedPosition.y } / 3

    if !tracking {
      tracking = true
      fired = false
      startY = y
      return false
    }
    if fired { return false }

    let dy = y - startY
    if abs(dy) > Self.gestureDelta {
      fired = true
      fireNav((dy > 0) != Self.invert ? Self.kLeftBracketKeyCode : Self.kRightBracketKeyCode)
    }
    return false
  }

  private func fireNav(_ code: CGKeyCode) {
    for down in [true, false] {
      let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
      e?.flags = .maskCommand
      e?.post(tap: .cgSessionEventTap)
    }
  }
}
