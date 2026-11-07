import AppKit
import ApplicationServices
import CoreGraphics

@_silgen_name("SLSCopySpacesForWindows")
func SLSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>)
  -> AXError

@MainActor final class AppSwitcher {
  static let shared = AppSwitcher()

  private static let tabKey: Int64 = 48
  private static let repeatInterval: TimeInterval = 0.25

  private var mru: [UInt32] = []
  private var frozen: [(id: UInt32, pid: pid_t)] = []
  private var index = 0
  private var sessionActive = false
  private var tabHeld = false
  private var repeatTimer: Timer?
  private var virtualSpace: UInt64 = 0
  private var raiseToken = 0
  private var observer: AXObserver?
  private var observedPid: pid_t = 0
  private var forward = true
  private var lastCommit: CFAbsoluteTime = 0

  func appActivated(_ app: NSRunningApplication) {
    guard app.activationPolicy == .regular else { return }
    observe(app)
    refreshFocus()
  }

  func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
    guard Config.shared.appSwitcher else { return false }

    switch type {
    case .keyDown:
      guard event.getIntegerValueField(.keyboardEventKeycode) == Self.tabKey,
        event.flags.contains(.maskCommand),
        event.flags.intersection([.maskControl, .maskAlternate]).isEmpty
      else { return false }
      if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return true }
      if !sessionActive { beginSession() }
      tabHeld = true
      forward = !event.flags.contains(.maskShift)
      step(forward: forward)
      armRepeat()
      return true

    case .keyUp:
      guard tabHeld, event.getIntegerValueField(.keyboardEventKeycode) == Self.tabKey
      else { return false }
      endSession()
      return true

    case .flagsChanged:
      if sessionActive {
        if event.flags.contains(.maskCommand) {
          forward = !event.flags.contains(.maskShift)
        } else {
          endSession()
        }
      }
      return false

    default:
      return false
    }
  }

  private func armRepeat() {
    repeatTimer?.invalidate()
    repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.repeatInterval, repeats: false) { _ in
      Task { @MainActor in AppSwitcher.shared.repeatTick() }
    }
  }

  private func repeatTick() {
    guard sessionActive, tabHeld else { return }
    step(forward: forward)
    armRepeat()
  }

  private func beginSession() {
    let recent = CFAbsoluteTimeGetCurrent() - lastCommit < 0.6
    if !recent {
      if let front = NSWorkspace.shared.frontmostApplication { observe(front) }
      refreshFocus()
    }

    let live = candidateWindows()
    let owners = Dictionary(live.map { ($0.id, $0.pid) }, uniquingKeysWith: { a, _ in a })
    mru.removeAll { owners[$0] == nil }
    for w in live where !mru.contains(w.id) { mru.append(w.id) }
    frozen = mru.compactMap { id in owners[id].map { (id: id, pid: $0) } }
    index = 0
    if !recent { virtualSpace = SLSGetActiveSpace(CGSMainConnectionID()) }
    sessionActive = true
  }

  private func endSession() {
    sessionActive = false
    tabHeld = false
    repeatTimer?.invalidate()
    if index > 0, frozen.indices.contains(index) {
      promote(frozen[index].id)
      lastCommit = CFAbsoluteTimeGetCurrent()
    }
    frozen = []
    index = 0
  }

  private func step(forward: Bool) {
    guard frozen.count > 1 else { return }
    index = (index + (forward ? 1 : frozen.count - 1)) % frozen.count
    let target = frozen[index]
    activate(window: target.id, pid: target.pid)
  }

  private func promote(_ id: UInt32) {
    mru.removeAll { $0 == id }
    mru.insert(id, at: 0)
  }

  private func refreshFocus() {
    guard !sessionActive,
      let app = NSWorkspace.shared.frontmostApplication,
      app.activationPolicy == .regular,
      let id = focusedWindowID(of: app.processIdentifier)
    else { return }
    promote(id)
  }

  private func focusedWindowID(of pid: pid_t) -> UInt32? {
    let el = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(el, 0.2)
    var raw: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &raw) == .success,
      let value = raw,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(value as! AXUIElement, &wid) == .success, wid != 0 else {
      return nil
    }
    return wid
  }

  private func observe(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    guard pid != observedPid else { return }
    stopObserving()

    var created: AXObserver?
    let callback: AXObserverCallback = { _, _, _, _ in
      Task { @MainActor in AppSwitcher.shared.refreshFocus() }
    }
    guard AXObserverCreate(pid, callback, &created) == .success, let obs = created else { return }
    let el = AXUIElementCreateApplication(pid)
    guard
      AXObserverAddNotification(obs, el, kAXFocusedWindowChangedNotification as CFString, nil)
        == .success
    else { return }
    _ = AXObserverAddNotification(obs, el, kAXMainWindowChangedNotification as CFString, nil)
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
    observer = obs
    observedPid = pid
  }

  private func stopObserving() {
    if let obs = observer {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
    }
    observer = nil
    observedPid = 0
  }

  private func spaces(of id: UInt32) -> [UInt64] {
    let cid = CGSMainConnectionID()
    let arr = [NSNumber(value: id)] as CFArray
    guard let raw = SLSCopySpacesForWindows(cid, 0x7, arr)?.takeRetainedValue() else {
      return []
    }
    return (raw as NSArray).compactMap { ($0 as? NSNumber)?.uint64Value }
  }

  private func candidateWindows() -> [(id: UInt32, pid: pid_t)] {
    guard
      let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
    else { return [] }
    var regular: [pid_t: Bool] = [:]
    var result: [(id: UInt32, pid: pid_t)] = []
    for w in list {
      guard let pid = w[kCGWindowOwnerPID as String] as? Int32,
        (w[kCGWindowLayer as String] as? Int) == 0,
        let id = w[kCGWindowNumber as String] as? UInt32,
        let b = w[kCGWindowBounds as String] as? [String: Any],
        let width = b["Width"] as? Double, let height = b["Height"] as? Double,
        width > 100, height > 100
      else { continue }
      let isRegular =
        regular[pid]
        ?? (NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular)
      regular[pid] = isRegular
      guard isRegular, !spaces(of: id).isEmpty else { continue }
      result.append((id: id, pid: pid))
    }
    return result
  }

  private func spaceMove(of id: UInt32) -> (delta: Int, target: UInt64)? {
    let windowSpaces = spaces(of: id)
    guard !windowSpaces.isEmpty, !windowSpaces.contains(virtualSpace) else { return nil }
    let cid = CGSMainConnectionID()
    guard
      let displays = SLSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]]
    else { return nil }
    for display in displays {
      guard let list = display["Spaces"] as? [[String: Any]] else { continue }
      let ids = list.compactMap { ($0["id64"] as? NSNumber)?.uint64Value }
      guard let a = ids.firstIndex(of: virtualSpace) else { continue }
      let options = windowSpaces.compactMap { s in
        ids.firstIndex(of: s).map { (delta: $0 - a, target: s) }
      }
      return options.min { abs($0.delta) < abs($1.delta) }
    }
    return nil
  }

  private func activate(window id: UInt32, pid: pid_t) {
    raiseToken &+= 1
    let token = raiseToken
    if let move = spaceMove(of: id), move.delta != 0 {
      virtualSpace = move.target
      _ = SpaceSwitcher.shared.focusRelative(right: move.delta > 0, count: abs(move.delta))
    }
    NSRunningApplication(processIdentifier: pid)?.activate()
    raise(id, pid: pid, token: token, attempt: 0)
  }

  private func raise(_ id: UInt32, pid: pid_t, token: Int, attempt: Int) {
    guard token == raiseToken else { return }
    if let win = axWindow(id, pid: pid) {
      let app = AXUIElementCreateApplication(pid)
      AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
      AXUIElementPerformAction(win, kAXRaiseAction as CFString)
      AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
      AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
      return
    }
    guard attempt < 10 else { return }
    Task {
      try? await Task.sleep(for: .milliseconds(50))
      raise(id, pid: pid, token: token, attempt: attempt + 1)
    }
  }

  private func axWindow(_ id: UInt32, pid: pid_t) -> AXUIElement? {
    let el = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(el, 0.2)
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXWindowsAttribute as CFString, &raw) == .success,
      let list = raw as? [AXUIElement]
    else { return nil }
    return list.first { win in
      var wid: CGWindowID = 0
      return _AXUIElementGetWindow(win, &wid) == .success && wid == id
    }
  }
}
