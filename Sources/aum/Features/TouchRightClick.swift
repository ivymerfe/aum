import CoreGraphics
import MultitouchSupport

@MainActor final class TouchRightClick {
  static let shared = TouchRightClick()

  var shouldRightClick: Bool = false
  var wasRightClick: Bool = false

  func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    guard Config.shared.touchRightClick else { return false }
    if shouldRightClick && type == .leftMouseDown {
      wasRightClick = true
      shouldRightClick = false
      event.type = .rightMouseDown
      event.setIntegerValueField(.mouseEventButtonNumber, value: kCGMouseButtonRight)
    }
    if wasRightClick && type == .leftMouseUp {
      wasRightClick = false
      event.type = .rightMouseUp
      event.setIntegerValueField(.mouseEventButtonNumber, value: kCGMouseButtonRight)
    }
    return false
  }

  func handleTouch(touches: UnsafePointer<MTTouch>?, nFingers: Int32) {
    shouldRightClick = nFingers == 2
  }
}
