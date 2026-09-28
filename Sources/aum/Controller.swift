import AppKit
import os

extension CGDisplayChangeSummaryFlags {
  fileprivate func containsAny(of flags: CGDisplayChangeSummaryFlags...) -> Bool {
    flags.contains(where: contains)
  }
}

@MainActor final class Controller: PointerableObject, Sendable {
  private static let config = Config.shared
  private static let state = GlobalState.shared

  private lazy var multitouchManager = IOMultitouchManager {
    self.scheduleRestart(2, reason: "Multitouch device added")
  }

  private var restartTimer: Timer?

  private static let fastRestart = false
  private static let wakeRestartTimeout: TimeInterval = fastRestart ? 2 : 10
  private static let immediateRestart = false

  private static let kCGMouseButtonCenter = Int64(CGMouseButton.center.rawValue)

  let accessibilityMonitor: AccessibilityMonitor
  let trayMenu: TrayMenu

  static let mouseEventHandler = CGEventController {
    _, type, event, _ in

    let returnedEvent = Unmanaged.passUnretained(event)

    if state.threeDown && (type == .leftMouseDown || type == .rightMouseDown) {
      state.wasThreeDown = true
      state.threeDown = false
      state.naturalMiddleClickLastTime = Date()
      event.type = .otherMouseDown

      event.setIntegerValueField(.mouseEventButtonNumber, value: kCGMouseButtonCenter)
    }

    if state.wasThreeDown && (type == .leftMouseUp || type == .rightMouseUp) {
      state.wasThreeDown = false
      event.type = .otherMouseUp

      event.setIntegerValueField(.mouseEventButtonNumber, value: kCGMouseButtonCenter)
    }
    return returnedEvent
  }

  init(accessibilityMonitor: AccessibilityMonitor, trayMenu: TrayMenu) {
    self.accessibilityMonitor = accessibilityMonitor
    self.trayMenu = trayMenu
  }

  func start() {
    log.info("Starting listeners...")

    TouchHandler.shared.registerTouchCallback()
    observeWakeNotification()
    setupSessionHandling()
    multitouchManager.setupMultitouchListener()
    setupDisplayReconfigurationCallback()

    accessibilityMonitor.addListener { becameTrusted in
      if becameTrusted {
        _ = Self.mouseEventHandler.start()
      } else {
        self.trayMenu.isStatusItemVisible = true
        Self.mouseEventHandler.stop()
      }
    }

    checkForConflicts()
  }

  /// Schedule listeners to be restarted. If a restart is pending, discard its delay and use the most recently requested delay.
  func scheduleRestart(_ delay: TimeInterval, reason: String) {
    if !isUserSessionActive {
      restartLog.info("\(reason), but user session is inactive - skipping restart")
      return
    }
    restartLog.info("\(reason), restarting in \(delay)")
    restartTimer?.invalidate()
    restartTimer = Timer.scheduledTimer(
      withTimeInterval: Self.immediateRestart ? 0 : delay, repeats: false
    ) { _ in
      DispatchQueue.main.async {
        self.restartListeners()
      }
    }
  }

  func restartListeners() {
    log.info("Restarting now...")
    stopUnstableListeners()
    if isUserSessionActive {
      startUnstableListeners()
      log.info("Restart success.")
    } else {
      //      This logic should never be reached — just a safeguard.
      log.info("Restart completed - listeners remain stopped due to inactive session")
    }
  }

  private func startUnstableListeners() {
    TouchHandler.shared.registerTouchCallback()
    _ = Self.mouseEventHandler.start()
  }

  private func stopUnstableListeners() {
    TouchHandler.shared.unregisterTouchCallback()
    Self.mouseEventHandler.stop()
  }

  private static var _userSessionActive = true

  /// Public accessor for session state (used by scheduleRestart and restartListeners)
  var isUserSessionActive: Bool { Self._userSessionActive }

  /// Initialize session handling - call this from start()
  func setupSessionHandling() {
    Self._userSessionActive = true
    observeSessionNotifications()
  }

  private func observeSessionNotifications() {
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(receiveSessionResignActiveNote),
      name: NSWorkspace.sessionDidResignActiveNotification,
      object: nil
    )
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(receiveSessionBecomeActiveNote),
      name: NSWorkspace.sessionDidBecomeActiveNotification,
      object: nil
    )
  }

  @objc private func receiveSessionResignActiveNote(_ note: Notification) {
    log.info("User session resigned active, stopping listeners")
    Self._userSessionActive = false
    restartTimer?.invalidate()
    restartTimer = nil

    DispatchQueue.main.async {
      self.stopUnstableListeners()
    }
  }

  @objc private func receiveSessionBecomeActiveNote(_ note: Notification) {
    log.info("User session became active, restarting listeners")
    Self._userSessionActive = true

    DispatchQueue.main.async {
      self.restartListeners()
    }
  }

  /// Callback for system wake up.
  /// Can be tested by entering `pmset sleepnow` in the Terminal
  @objc func receiveWakeNote(_ note: Notification) {
    scheduleRestart(Self.wakeRestartTimeout, reason: "System woke up")
  }

  func observeWakeNotification() {
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(receiveWakeNote),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )
  }

  /// TODO:? is this restart necessary? I don't see any changes when it's removed, but keep in mind I've only spent 5 minutes testing different app and system states
  static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = {
    _, flags, userData in
    if flags.containsAny(of: .setModeFlag, .addFlag, .removeFlag, .disabledFlag) {
      Controller.from(pointer: userData).scheduleRestart(2, reason: "Display reconfigured")
    }
  }

  func setupDisplayReconfigurationCallback() {
    CGDisplayRegisterReconfigurationCallback(
      Self.displayReconfigurationCallback,
      rawPointer
    )
  }

  func checkForConflicts() {
    accessibilityMonitor.addListener { becameTrusted in
      guard becameTrusted else { return }

      let mayConflictByFingers = Self.config.minimumFingers == 3
      guard mayConflictByFingers else { return }

      let threeFingerDragConflict = SystemPermissions.getIsSystemThreeFingerDragEnabled()
      let threeFingerTap = SystemPermissions.getIsSystemThreeFingerTapEnabled()
      let threeFingerTapConflict = threeFingerTap && Self.config.tapToClick

      guard threeFingerDragConflict || threeFingerTapConflict else { return }

      let both = threeFingerDragConflict && threeFingerTapConflict

      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.addButton(withTitle: "OK")

      alert.messageText = "Conflicting gesture\(both ? "s" : "")"
      alert.informativeText = """
        \(threeFingerDragConflict ? """
          Dragging style: "Three Finger Drag"
          Issue — won't function, also adds an unintended left click to any middle click.
          Workarounds — Opt in for another Dragging style, or Choose to 'Ignore Finder' in the status menu of MiddleClick.
          """ : "")
        \(threeFingerTapConflict ? """
          Look up & data detectors: "Tap with Three Fingers"
          Issue — will fire simultaneously with MiddleClick.
          Workarounds — Disable 'Tap to click' in the status menu of MiddleClick.
          """ : "")
        """
      alert.runModal()
    }
  }
}
