import AppKit
import ApplicationServices
import CoreGraphics

@MainActor final class WindowControls {
  static let shared = WindowControls()

  private enum Action {
    case fullscreen
    case close
    case minimize
    case maximize
  }

  private static let keys: [Int64: Action] = [
    3: .fullscreen, 12: .close, 1: .minimize, 8: .maximize,
  ]

  private var saved: [Int: CGRect] = [:]
  private var swallowed: Set<Int64> = []

  func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    guard Config.shared.windowControls else { return false }
    guard Config.shared.altKeys else { return false }

    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags

    switch type {
    case .keyDown:
      guard flags.contains(.maskAlternate),
        flags.intersection([.maskCommand, .maskControl, .maskShift]).isEmpty,
        let action = Self.keys[code]
      else { return false }
      swallowed.insert(code)
      if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { run(action) }
      return true

    case .keyUp:
      return swallowed.remove(code) != nil

    default:
      return false
    }
  }

  private func run(_ action: Action) {
    guard let win = focusedWindow() else { return }
    switch action {
    case .fullscreen:
      var cur: CFTypeRef?
      AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &cur)
      let on = (cur as? Bool) ?? false
      AXUIElementSetAttributeValue(
        win, "AXFullScreen" as CFString, on ? kCFBooleanFalse : kCFBooleanTrue)

    case .close:
      var raw: CFTypeRef?
      guard
        AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute as CFString, &raw) == .success,
        let button = raw,
        CFGetTypeID(button) == AXUIElementGetTypeID()
      else { return }
      AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)

    case .minimize:
      AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanTrue)

    case .maximize:
      maximize(win)
    }
  }

  private func focusedWindow() -> AXUIElement? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let el = AXUIElementCreateApplication(app.processIdentifier)
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &raw) == .success,
      let value = raw,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    return (value as! AXUIElement)
  }

  private func frame(of win: AXUIElement) -> CGRect? {
    var p: CFTypeRef?
    var s: CFTypeRef?
    guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &p) == .success,
      AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &s) == .success,
      let pv = p, let sv = s
    else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(pv as! AXValue, .cgPoint, &origin),
      AXValueGetValue(sv as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: origin, size: size)
  }

  private func setFrame(_ win: AXUIElement, _ rect: CGRect) {
    var origin = rect.origin
    var size = rect.size
    guard let pv = AXValueCreate(.cgPoint, &origin), let sv = AXValueCreate(.cgSize, &size)
    else { return }
    AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
    AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
    AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
  }

  private func near(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 4 && abs(a.minY - b.minY) < 4
      && abs(a.width - b.width) < 4 && abs(a.height - b.height) < 4
  }

  private func maximize(_ win: AXUIElement) {
    guard let f = frame(of: win) else { return }
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    let center = CGPoint(x: f.midX, y: primaryH - f.midY)
    let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    guard let vf = screen?.visibleFrame else { return }
    let target = CGRect(x: vf.minX, y: primaryH - vf.maxY, width: vf.width, height: vf.height)
    let key = Int(CFHash(win))
    if near(f, target) {
      if let old = saved[key] {
        setFrame(win, old)
        saved[key] = nil
      }
    } else {
      saved[key] = f
      setFrame(win, target)
    }
  }
}