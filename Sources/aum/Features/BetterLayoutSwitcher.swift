import Carbon

@MainActor final class BetterLayoutSwitcher {
  static let shared = BetterLayoutSwitcher()

  private static let kCapsLockKeyCode: Int64 = 57

  func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    guard Config.shared.betterLayoutSwitcher else { return false }
    if type == .flagsChanged {
      let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
      if keyCode == Self.kCapsLockKeyCode {
        if event.flags.contains(.maskAlphaShift) {
          Self.switchToNextInputSource()
        }
        return true
      }
    }
    return false
  }

  static func switchToNextInputSource() {
    guard
      let inputSourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue()
        as? [TISInputSource]
    else {
      return
    }
    let currentSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()

    let selectableSources = inputSourceList.filter { source in
      guard let categoryPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory)
      else { return false }
      let category = unsafeBitCast(categoryPtr, to: CFString.self) as String
      guard category == (kTISCategoryKeyboardInputSource as String) else { return false }

      guard let typePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else {
        return false
      }
      let type = unsafeBitCast(typePtr, to: CFString.self) as String
      let isValidType =
        type == (kTISTypeKeyboardLayout as String)
        || type == (kTISTypeKeyboardInputMode as String)
      guard isValidType else { return false }

      guard
        let selectablePtr = TISGetInputSourceProperty(
          source, kTISPropertyInputSourceIsSelectCapable)
      else { return false }
      let isSelectable = unsafeBitCast(selectablePtr, to: CFBoolean.self)

      return CFBooleanGetValue(isSelectable)
    }
    guard selectableSources.count > 1,
      let currentIndex = selectableSources.firstIndex(where: { $0 == currentSource })
    else { return }

    let nextIndex = (currentIndex + 1) % selectableSources.count
    let nextSource = selectableSources[nextIndex]

    TISSelectInputSource(nextSource)
  }
}
