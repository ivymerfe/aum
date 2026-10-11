import CoreGraphics
import MultitouchSupport

@_silgen_name("SLSSetDisplayRotation")
private func SLSSetDisplayRotation(_ display: CGDirectDisplayID, _ rotation: Int32) -> Int32

@MainActor final class BetterScreenRotation {
  static let shared = BetterScreenRotation()

  private static let bindings: [Int64: Int32] = [34: 270, 31: 0, 35: 90]
  private static let modifiers: CGEventFlags = [
    .maskAlternate, .maskCommand, .maskControl, .maskShift,
  ]

  private let deadzone: CGFloat = 0.0005
  private let speedMultiplier: CGFloat = 1.4
  private let baseGain: CGFloat = 0.25
  private let speedScale: CGFloat = 120.0
  private let accelCurve: CGFloat = 1.4

  private var currentRotation: Int = 0
  private var screenSize: CGSize = .zero

  private var lastNormalizedPosition: CGPoint?
  private var cursorPosition: CGPoint?

  func updateDisplayConfig(rotation: Int, bounds: CGRect) {
    let rotationChanged = (self.currentRotation != rotation)
    self.currentRotation = rotation
    self.screenSize = bounds.size
    if rotationChanged {
      CGAssociateMouseAndMouseCursorPosition(rotation == 0 ? 1 : 0)
      lastNormalizedPosition = nil
      cursorPosition = nil
    }
  }

  func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    guard Config.shared.betterScreenRotation else { return false }

    if type == .keyDown {
      let keycode = event.getIntegerValueField(.keyboardEventKeycode)
      guard event.flags.intersection(Self.modifiers) == .maskAlternate else { return false }
      guard let degrees = Self.bindings[keycode] else { return false }
      if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
        _ = SLSSetDisplayRotation(CGMainDisplayID(), degrees)
      }
      return true
    }

    if type == .scrollWheel {
      if currentRotation != 0 {
        let dy = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let dx = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        let ptDy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let ptDx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let pointDy = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let pointDx = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)

        let (newDx, newDy) = rotate(x: dx, y: dy)
        let (newPtDx, newPtDy) = rotate(x: ptDx, y: ptDy)
        let (newPointDx, newPointDy) = rotate(x: pointDx, y: pointDy)

        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: newDy)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: newDx)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: newPtDy)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: newPtDx)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: newPointDy)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: newPointDx)
      }
      return false
    }
    if type == kCGSEventGesture {
      // TODO
      return false
    }
    if type == kCGSEventDockControl {
      let gestureType = event.getIntegerValueField(kCGEventGestureHIDType)
      if currentRotation != 0, gestureType == kIOHIDEventTypeDockSwipe {
        let motion = event.getIntegerValueField(kCGEventGestureSwipeMotion)
        if motion == 1 || motion == 2 {
          let horizontal = motion == 1
          let (ux, uy) = rotate(x: horizontal ? 1.0 : 0.0, y: horizontal ? 0.0 : -1.0)
          let newMotion: Int64 = abs(ux) > 0.5 ? 1 : 2
          let sign = newMotion == 1 ? ux : -uy

          let progress = event.getDoubleValueField(kCGEventGestureSwipeProgress)
          let vx = event.getDoubleValueField(kCGEventGestureSwipeVelocityX)
          let vy = event.getDoubleValueField(CGEventField(rawValue: 130)!)
          let (rx, ry) = rotate(x: vx, y: -vy)

          event.setIntegerValueField(kCGEventGestureSwipeMotion, value: newMotion)
          event.setDoubleValueField(kCGEventGestureSwipeProgress, value: progress * sign)
          event.setDoubleValueField(kCGEventGestureSwipeVelocityX, value: rx)
          event.setDoubleValueField(CGEventField(rawValue: 130)!, value: -ry)
        }
      }
    }
    return false
  }

  func handleTouch(touches: UnsafePointer<MTTouch>?, nFingers: Int32) {
    guard Config.shared.betterScreenRotation else { return }
    guard currentRotation != 0 else { return }
    guard nFingers == 1, let touch = touches?.pointee else {
      lastNormalizedPosition = nil
      cursorPosition = nil
      return
    }
    let current = CGPoint(
      x: CGFloat(touch.normalizedVector.position.x),
      y: CGFloat(1.0 - touch.normalizedVector.position.y))

    guard let last = lastNormalizedPosition, var pos = cursorPosition else {
      lastNormalizedPosition = current
      cursorPosition = CGEvent(source: nil)?.location
      return
    }

    let dx = current.x - last.x
    let dy = current.y - last.y
    let distance = sqrt(dx * dx + dy * dy)
    if distance < deadzone { return }
    lastNormalizedPosition = current

    let (rx, ry): (CGFloat, CGFloat) =
      switch currentRotation {
      case 90: (-dy, dx)
      case 180: (-dx, -dy)
      case 270: (dy, -dx)
      default: (dx, dy)
      }

    let gain = speedMultiplier * (baseGain + pow(distance * speedScale, accelCurve))
    pos.x = max(0, min(screenSize.width - 1, pos.x + rx * screenSize.width * gain))
    pos.y = max(0, min(screenSize.height - 1, pos.y + ry * screenSize.height * gain))
    cursorPosition = pos
    CGWarpMouseCursorPosition(pos)
  }

  func rotate(x: Int64, y: Int64) -> (Int64, Int64) {
    switch currentRotation {
    case 90:
      return (-y, x)
    case 180:
      return (-x, -y)
    case 270:
      return (y, -x)
    default:
      return (x, y)
    }
  }

  func rotate(x: Double, y: Double) -> (Double, Double) {
    switch currentRotation {
    case 90:
      return (-y, x)
    case 180:
      return (-x, -y)
    case 270:
      return (y, -x)
    default:
      return (x, y)
    }
  }

  func rotate(x: CGFloat, y: CGFloat) -> (CGFloat, CGFloat) {
    switch currentRotation {
    case 90:
      return (-y, x)
    case 180:
      return (-x, -y)
    case 270:
      return (y, -x)
    default:
      return (x, y)
    }
  }
}
