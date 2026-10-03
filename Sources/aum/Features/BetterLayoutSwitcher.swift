import Carbon

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> UnsafeMutableRawPointer?

@_silgen_name("IOHIDEventSystemClientSetProperty")
private func IOHIDEventSystemClientSetProperty(
  _ client: UnsafeMutableRawPointer, _ key: CFString, _ value: CFTypeRef
) -> Bool

@MainActor final class BetterLayoutSwitcher {
  static let shared = BetterLayoutSwitcher()

  private static let kF18KeyCode: Int64 = 79

  func reload() {
    if Config.shared.betterLayoutSwitcher {
      Self.setKeyMapping([
        [
          "HIDKeyboardModifierMappingSrc": 0x7_0000_0039,
          "HIDKeyboardModifierMappingDst": 0x7_0000_006D,
        ]
      ])
    } else {
      Self.setKeyMapping([])
    }
  }
  
  func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    guard Config.shared.betterLayoutSwitcher else { return false }
    guard event.getIntegerValueField(.keyboardEventKeycode) == Self.kF18KeyCode else { return false }
  
    if type == .keyDown {
      if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
        Self.switchToNextInputSource()
      }
      return true
    }
    if type == .keyUp {
      return true
    }
    return false
  }

  private static func setKeyMapping(_ mapping: [[String: Int]]) {
    guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return }
    _ = IOHIDEventSystemClientSetProperty(client, "UserKeyMapping" as CFString, mapping as CFArray)
    Unmanaged<AnyObject>.fromOpaque(client).release()
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
