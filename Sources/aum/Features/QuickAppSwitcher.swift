import AppKit
import CoreGraphics

@MainActor final class QuickAppSwitcher {
  static let shared = QuickAppSwitcher()

  private static let tapMaxDuration: TimeInterval = 0.25

  private var current: NSRunningApplication?
  private var previous: NSRunningApplication?
  private var cmdDown = false
  private var dirty = false
  private var downTime: TimeInterval = 0

  func appActivated(_ app: NSRunningApplication) {
    guard app.activationPolicy == .regular else { return }
    guard app.processIdentifier != current?.processIdentifier else { return }
    previous = current
    current = app
  }

  func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    guard Config.shared.quickAppSwitcher else { return false }

    switch type {
    case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
      dirty = true

    case .flagsChanged:
      let flags = event.flags
      let others = flags.intersection([.maskShift, .maskAlternate, .maskControl])
      let now = ProcessInfo.processInfo.systemUptime

      if flags.contains(.maskCommand) {
        if !cmdDown {
          cmdDown = true
          dirty = !others.isEmpty
          downTime = now
        } else if !others.isEmpty {
          dirty = true
        }
      } else if cmdDown {
        cmdDown = false
        if !dirty, now - downTime < Self.tapMaxDuration, let app = previous, !app.isTerminated {
          app.activate()
        }
      }

    default:
      break
    }
    return false
  }
}
