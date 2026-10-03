import CoreGraphics
import Foundation
import MultitouchSupport

@MainActor final class MiddleClickEmu {
  static let shared = MiddleClickEmu()

  private static var fingersCount: Int = 3
  private static let maxDistanceDelta: Float = 0.05
  private static let maxTimeDelta: Double = 0.3

  var threeDown = false
  var wasThreeDown = false
  var naturalMiddleClickLastTime: Date?
  var lastEmulatedMiddleClickTime: Date?

  private var maybeMiddleClick = false
  private var touchStartTime: Date?
  private var middleClickPos1: SIMD2<Float> = .zero
  private var middleClickPos2: SIMD2<Float> = .zero

  func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    guard Config.shared.middleClickEmu else { return false }
    if threeDown && (type == .leftMouseDown || type == .rightMouseDown) {
      wasThreeDown = true
      threeDown = false
      naturalMiddleClickLastTime = Date()
      event.type = .otherMouseDown
      event.setIntegerValueField(.mouseEventButtonNumber, value: kCGMouseButtonCenter)
    }
    if wasThreeDown && (type == .leftMouseUp || type == .rightMouseUp) {
      wasThreeDown = false
      event.type = .otherMouseUp
      event.setIntegerValueField(.mouseEventButtonNumber, value: kCGMouseButtonCenter)
    }
    return false
  }

  func handleTouch(touches: UnsafePointer<MTTouch>?, nFingers: Int32) {
    guard Config.shared.middleClickEmu else { return }
    threeDown = nFingers == Self.fingersCount

    guard Config.shared.tapToClick else { return }

    guard nFingers != 0 else {
      handleTouchEnd()
      return
    }
    let isTouchStart = nFingers > 0 && touchStartTime == nil
    if isTouchStart {
      touchStartTime = Date()
      maybeMiddleClick = true
      middleClickPos1 = .zero
    } else if maybeMiddleClick, touchStartTime != nil {
      let elapsedTime = -touchStartTime!.timeIntervalSinceNow
      if elapsedTime > Self.maxTimeDelta {
        maybeMiddleClick = false
      }
    }
    if nFingers > Self.fingersCount {
      resetMiddleClick()
    } else if nFingers == Self.fingersCount {
      processTouches(touches: touches, nFingers: nFingers)
    }
  }

  private func processTouches(touches: UnsafePointer<MTTouch>?, nFingers: Int32) {
    guard let data = touches else { return }
    if maybeMiddleClick {
      middleClickPos1 = .zero
    } else {
      middleClickPos2 = .zero
    }
    for touch in UnsafeBufferPointer(start: data, count: Int(nFingers)) {
      let pos = SIMD2(touch.normalizedVector.position)
      if maybeMiddleClick {
        middleClickPos1 += pos
      } else {
        middleClickPos2 += pos
      }
    }
    if maybeMiddleClick {
      middleClickPos2 = middleClickPos1
      maybeMiddleClick = false
    }
  }

  private func resetMiddleClick() {
    maybeMiddleClick = false
    middleClickPos1 = .zero
  }

  private func handleTouchEnd() {
    guard let startTime = touchStartTime else { return }

    let elapsedTime = -startTime.timeIntervalSinceNow
    touchStartTime = nil

    guard middleClickPos1.isNonZero && elapsedTime <= Self.maxTimeDelta else { return }

    let delta = middleClickPos1.delta(to: middleClickPos2)
    if delta < Self.maxDistanceDelta && !shouldPreventEmulation() {
      emulateMiddleClick()
    }
  }

  private func emulateMiddleClick() {
    if let lastTime = lastEmulatedMiddleClickTime,
      -lastTime.timeIntervalSinceNow < Self.maxTimeDelta * 0.3
    {
      return
    }
    lastEmulatedMiddleClickTime = .init()

    // get the current pointer location
    let location = CGEvent(source: nil)?.location ?? .zero
    let buttonType: CGMouseButton = .center

    Self.postMouseEvent(type: .otherMouseDown, button: buttonType, location: location)
    Self.postMouseEvent(type: .otherMouseUp, button: buttonType, location: location)
  }

  private func shouldPreventEmulation() -> Bool {
    guard let naturalLastTime = naturalMiddleClickLastTime else { return false }

    let elapsedTimeSinceNatural = -naturalLastTime.timeIntervalSinceNow
    return elapsedTimeSinceNatural <= Self.maxTimeDelta * 0.75  // fine-tuned multiplier
  }

  private static func postMouseEvent(
    type: CGEventType, button: CGMouseButton, location: CGPoint
  ) {
    CGEvent(
      mouseEventSource: nil, mouseType: type, mouseCursorPosition: location,
      mouseButton: button
    )?.post(tap: .cghidEventTap)
  }
}

extension SIMD2 where Scalar == Float {
  init(_ point: MTPoint) { self.init(point.x, point.y) }
}

extension SIMD2 where Scalar: FloatingPoint {
  func delta(to other: SIMD2) -> Scalar {
    return abs(x - other.x) + abs(y - other.y)
  }

  var isNonZero: Bool { x != 0 || y != 0 }
}
