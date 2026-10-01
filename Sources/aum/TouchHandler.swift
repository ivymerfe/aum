import MultitouchSupport

@MainActor class TouchHandler {
  static let shared = TouchHandler()

  private static var fingersCount: Int = 3
  private static let maxDistanceDelta: Float = 0.05
  private static let maxTimeDelta: Double = 0.3

  private static let config = Config.shared
  private var middleClick = config.middleClick
  private var tapToClick = config.tapToClick

  private init() {
    Self.config.$middleClick.onSet {
      self.middleClick = $0
    }
    Self.config.$tapToClick.onSet {
      self.tapToClick = $0
    }
  }

  private var maybeMiddleClick = false
  private var touchStartTime: Date?
  private static var lastEmulatedMiddleClickTime: Date?
  private var middleClickPos1: SIMD2<Float> = .zero
  private var middleClickPos2: SIMD2<Float> = .zero

  private var lastNormalizedPosition: CGPoint?
  private let deadzone: CGFloat = 0.001
  private let speedMultiplier: CGFloat = 1.4

  private(set) var currentRotation: Int = 0
  private var screenSize: CGSize = .zero

  private var currentDeviceList: [MTDevice] = []
  func registerTouchCallback() {
    currentDeviceList = MTDevice.createList()
    currentDeviceList.forEach { $0.registerAndStart(touchCallback) }
  }
  func unregisterTouchCallback() {
    currentDeviceList.forEach { $0.unregisterAndStop(touchCallback) }
    currentDeviceList.removeAll()
  }

  func updateDisplayConfig(rotation: Int, bounds: CGRect) {
    let rotationChanged = (self.currentRotation != rotation)
    self.currentRotation = rotation
    self.screenSize = bounds.size
    if rotationChanged {
      CGAssociateMouseAndMouseCursorPosition(rotation == 0 ? 1 : 0)
      lastNormalizedPosition = nil
    }
  }

  private let touchCallback: MTFrameCallbackFunction = {
    _, data, nFingers, _, _ in

    let state = GlobalState.shared

    state.nFingers = Int(nFingers)
    state.threeDown = nFingers == TouchHandler.fingersCount

    let handler = TouchHandler.shared
    if handler.currentRotation != 0 {
      if nFingers == 1, let touch = data?.pointee {
        handler.processRelativeRotatedCursor(touch: touch)
      } else {
        handler.lastNormalizedPosition = nil
      }
    }
    guard handler.middleClick && handler.tapToClick else { return }

    guard nFingers != 0 else {
      handler.handleTouchEnd()
      return
    }

    let isTouchStart = nFingers > 0 && handler.touchStartTime == nil
    if isTouchStart {
      handler.touchStartTime = Date()
      handler.maybeMiddleClick = true
      handler.middleClickPos1 = .zero
    } else if handler.maybeMiddleClick, let touchStartTime = handler.touchStartTime {
      // Timeout check for middle click
      let elapsedTime = -touchStartTime.timeIntervalSinceNow
      if elapsedTime > maxTimeDelta {
        handler.maybeMiddleClick = false
      }
    }
    guard nFingers >= TouchHandler.fingersCount else { return }
    if nFingers > TouchHandler.fingersCount {
      handler.resetMiddleClick()
    } else {
      handler.processTouches(data: data, nFingers: nFingers)
    }
    return
  }

  private func processRelativeRotatedCursor(touch: MTTouch) {
    let currentNormX = CGFloat(touch.normalizedVector.position.x)
    let currentNormY = CGFloat(1.0 - touch.normalizedVector.position.y)
    let currentNormPoint = CGPoint(x: currentNormX, y: currentNormY)

    guard let lastNormPoint = lastNormalizedPosition else {
      lastNormalizedPosition = currentNormPoint
      return
    }
    let rawDeltaX = currentNormPoint.x - lastNormPoint.x
    let rawDeltaY = currentNormPoint.y - lastNormPoint.y
    let distance = sqrt(rawDeltaX * rawDeltaX + rawDeltaY * rawDeltaY)
    if distance < deadzone {
      return
    }
    lastNormalizedPosition = currentNormPoint
    let (rotatedDeltaX, rotatedDeltaY): (CGFloat, CGFloat) =
      switch currentRotation {
      case 90: (-rawDeltaY, rawDeltaX)
      case 180: (-rawDeltaX, -rawDeltaY)
      case 270: (rawDeltaY, -rawDeltaX)
      default: (rawDeltaX, rawDeltaY)
      }
    let accel = 1.0 + (distance * 15.0)
    guard let currentCursorPosition = CGEvent(source: nil)?.location else { return }
    let newX =
      currentCursorPosition.x + (rotatedDeltaX * screenSize.width * speedMultiplier * accel)
    let newY =
      currentCursorPosition.y + (rotatedDeltaY * screenSize.height * speedMultiplier * accel)

    let clampedX = max(0, min(screenSize.width - 1, newX))
    let clampedY = max(0, min(screenSize.height - 1, newY))

    CGWarpMouseCursorPosition(CGPoint(x: clampedX, y: clampedY))
  }

  private func processTouches(data: UnsafePointer<MTTouch>?, nFingers: Int32) {
    guard let data = data else { return }

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
      Self.emulateMiddleClick()
    }
  }

  private static func emulateMiddleClick() {
    if let lastTime = lastEmulatedMiddleClickTime,
      -lastTime.timeIntervalSinceNow < maxTimeDelta * 0.3
    {
      return
    }
    lastEmulatedMiddleClickTime = .init()

    // get the current pointer location
    let location = CGEvent(source: nil)?.location ?? .zero
    let buttonType: CGMouseButton = .center

    postMouseEvent(type: .otherMouseDown, button: buttonType, location: location)
    postMouseEvent(type: .otherMouseUp, button: buttonType, location: location)
  }

  private func shouldPreventEmulation() -> Bool {
    guard let naturalLastTime = GlobalState.shared.naturalMiddleClickLastTime else { return false }

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

  static func rotate(x: Int64, y: Int64) -> (Int64, Int64) {
    switch TouchHandler.shared.currentRotation {
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

  static func rotate(x: Double, y: Double) -> (Double, Double) {
    switch TouchHandler.shared.currentRotation {
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

  static func rotate(x: CGFloat, y: CGFloat) -> (CGFloat, CGFloat) {
    switch TouchHandler.shared.currentRotation {
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

extension SIMD2 where Scalar == Float {
  init(_ point: MTPoint) { self.init(point.x, point.y) }
}
extension SIMD2 where Scalar: FloatingPoint {
  func delta(to other: SIMD2) -> Scalar {
    return abs(x - other.x) + abs(y - other.y)
  }

  var isNonZero: Bool { x != 0 || y != 0 }
}
