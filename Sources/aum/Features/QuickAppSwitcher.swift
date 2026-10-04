import AppKit
import CoreGraphics

@_silgen_name("SLSCopySpacesForWindows")
func SLSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?

@MainActor final class QuickAppSwitcher {
  static let shared = QuickAppSwitcher()

  private static let tapMaxDuration: TimeInterval = 0.25

  private var current: NSRunningApplication?
  private var previous: NSRunningApplication?
  private var altDown = false
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
      let others = flags.intersection([.maskShift, .maskCommand, .maskControl])
      let now = ProcessInfo.processInfo.systemUptime

      if flags.contains(.maskAlternate) {
        if !altDown {
          altDown = true
          dirty = !others.isEmpty
          downTime = now
        } else if !others.isEmpty {
          dirty = true
        }
      } else if altDown {
        altDown = false
        if !dirty, now - downTime < Self.tapMaxDuration, let app = previous, !app.isTerminated {
          Self.fastActivate(app)
        }
      }

    default:
      break
    }
    return false
  }

  static func fastActivate(_ app: NSRunningApplication) {
    let delta = spaceDelta(for: app)
    if delta < 0 {
      _ = InstantSpaceSwitcher.shared.focusRelative(right: false, count: -delta)
    } else if delta > 0 {
      _ = InstantSpaceSwitcher.shared.focusRelative(right: true, count: delta)
    }
    app.activate()
  }

  static func windowIDs(of app: NSRunningApplication) -> [UInt32] {
    guard
      let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    var result: [UInt32] = []
    for w in list {
      guard (w[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
        (w[kCGWindowLayer as String] as? Int) == 0,
        let id = w[kCGWindowNumber as String] as? UInt32,
        let b = w[kCGWindowBounds as String] as? [String: Any],
        let width = b["Width"] as? Double, let height = b["Height"] as? Double,
        width > 100, height > 100
      else { continue }
      result.append(id)
    }
    return result
  }

  static func spaceDelta(for app: NSRunningApplication) -> Int {
    let cid = CGSMainConnectionID()
    let active = SLSGetActiveSpace(cid)
    let wids = windowIDs(of: app)
    guard !wids.isEmpty else { return 0 }

    let arr = wids.map { NSNumber(value: $0) } as CFArray
    guard let raw = SLSCopySpacesForWindows(cid, 0x7, arr)?.takeRetainedValue() else {
      return 0
    }
    let spaces = (raw as NSArray).compactMap { ($0 as? NSNumber)?.uint64Value }
    if spaces.isEmpty || spaces.contains(active) { return 0 }

    guard
      let displays = SLSCopyManagedDisplaySpaces(cid)?.takeRetainedValue()
        as? [[String: Any]]
    else { return 0 }

    for display in displays {
      guard let list = display["Spaces"] as? [[String: Any]] else { continue }
      let ids = list.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
      guard let a = ids.firstIndex(of: active) else { continue }
      let deltas = spaces.compactMap { ids.firstIndex(of: $0) }.map { $0 - a }
      if let best = deltas.min(by: { abs($0) < abs($1) }) { return best }
    }
    return 0
  }
}
