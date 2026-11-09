import AppKit
import ServiceManagement
import os

@MainActor final class TrayMenu: NSObject, NSMenuDelegate, NSApplicationDelegate {
  private let config = Config.shared
  private lazy var app = AumApp.getInstance()

  static let version =
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?.?.?"

  private var infoItem: NSMenuItem!
  private var accessibilityPermissionStatusItem: NSMenuItem!
  private var accessibilityPermissionActionItem: NSMenuItem!

  private var launchAtLoginItem: NSMenuItem!
  let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

  private var altKeysItem: NSMenuItem!
  private var layoutSwitcherItem: NSMenuItem!
  private var windowControlsItem: NSMenuItem!

  private var betterDisplayRotationItem: NSMenuItem!
  private var inverseScrollingItem: NSMenuItem!

  private var cmdTabSwitcherItem: NSMenuItem!
  private var altTapSwitcherItem: NSMenuItem!
  private var groupSwitcherItem: NSMenuItem!
  private var gestureSwitcherItem: NSMenuItem!

  private var touchMiddleClickItem: NSMenuItem!
  private var tapToClickItem: NSMenuItem!
  private var touchNavigationItem: NSMenuItem!
  private var touchRightClickItem: NSMenuItem!

  private static let shouldDelayInit = terminateExistingInstance(force: false)
  private var timesHandledReopen = 0

  override init() {
    super.init()

    if Self.shouldDelayInit {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: self.initSequence)
    } else {
      self.initSequence()
    }
  }
  private func initSequence() {
    setupStatusItem()
    app.accessibilityMonitor.addListener(onChange: updateAccessibilityPermissionStatus)
  }

  private func updateAccessibilityPermissionStatus(_ hasAccessibilityPermission: Bool) {
    statusItem.button?.appearsDisabled = !hasAccessibilityPermission
    accessibilityPermissionStatusItem.isHidden = hasAccessibilityPermission
    accessibilityPermissionActionItem.isHidden = hasAccessibilityPermission
  }

  private func createMenu() -> NSMenu {
    let menu = NSMenu()
    menu.delegate = self
    menu.autoenablesItems = false

    infoItem = menu.addItem(withTitle: "Aum v\(Self.version)")

    createMenuAccessibilityPermissionItems(menu)
    menu.addSeparator()

    launchAtLoginItem = menu.addItem(
      withTitle: "Launch at login",
      action: #selector(toggleLoginItem),
      target: self
    )
    updateLaunchAtLoginItem()

    _ = menu.addItem(
      withTitle: "Restart listeners",
      action: #selector(restartNow),
      target: self,
      keyEquivalent: "r"
    )
    menu.addSeparator()

    _ = menu.addItem(
      withTitle: "Quit", action: #selector(actionQuit), target: self, keyEquivalent: "q")

    menu.addSeparator()

    altKeysItem = menu.addItem(
      withTitle: "AltKeys",
      action: #selector(toggleAltKeys),
      target: self
    )

    layoutSwitcherItem = menu.addItem(
      withTitle: "LayoutSwitcher",
      action: #selector(toggleLayoutSwitcher),
      target: self
    )

    windowControlsItem = menu.addItem(
      withTitle: "WindowControls",
      action: #selector(toggleWindowControls),
      target: self
    )

    menu.addSeparator()

    betterDisplayRotationItem = menu.addItem(
      withTitle: "BetterDisplayRotation",
      action: #selector(toggleBetterDisplayRotation),
      target: self
    )
    inverseScrollingItem = menu.addItem(
      withTitle: "InverseScrolling",
      action: #selector(toggleInverseScrolling),
      target: self
    )

    menu.addSeparator()

    cmdTabSwitcherItem = menu.addItem(
      withTitle: "Switcher - CmdTab",
      action: #selector(toggleCmdTabSwitcher),
      target: self
    )
    altTapSwitcherItem = menu.addItem(
      withTitle: "Switcher - Alt tap",
      action: #selector(toggleAltTapSwitcher),
      target: self
    )
    groupSwitcherItem = menu.addItem(
      withTitle: "Switcher - Groups",
      action: #selector(toggleGroupSwitcher),
      target: self
    )
    gestureSwitcherItem = menu.addItem(
      withTitle: "Switcher - Gestures",
      action: #selector(toggleGestureSwitcher),
      target: self
    )

    menu.addSeparator()

    touchMiddleClickItem = menu.addItem(
      withTitle: "TouchMiddleClick",
      action: #selector(toggleTouchMiddleClick),
      target: self
    )
    tapToClickItem = menu.addItem(
      withTitle: "Tap to click", action: #selector(toggleTapToClick), target: self)

    touchNavigationItem = menu.addItem(
      withTitle: "TouchNavigation",
      action: #selector(toggleTouchNavigation),
      target: self
    )
    touchRightClickItem = menu.addItem(
      withTitle: "TouchRightClick",
      action: #selector(toggleTouchRightClick),
      target: self
    )

    altKeysItem.state = config.altKeys ? .on : .off
    layoutSwitcherItem.state = config.layoutSwitcher ? .on : .off
    windowControlsItem.state = config.windowControls ? .on : .off

    betterDisplayRotationItem.state = config.betterDisplayRotation ? .on : .off
    inverseScrollingItem.state = config.inverseScrolling ? .on : .off

    cmdTabSwitcherItem.state = config.cmdTabSwitcher ? .on : .off
    altTapSwitcherItem.state = config.altTapSwitcher ? .on : .off
    groupSwitcherItem.state = config.groupSwitcher ? .on : .off
    gestureSwitcherItem.state = config.gestureSwitcher ? .on : .off

    touchMiddleClickItem.state = config.touchMiddleClick ? .on : .off
    tapToClickItem.state = config.tapToClick ? .on : .off
    touchNavigationItem.state = config.touchNavigation ? .on : .off
    touchRightClickItem.state = config.touchRightClick ? .on : .off

    return menu
  }

  // Keyboard
  @objc private func toggleAltKeys(sender: NSButton) {
    config.altKeys = (altKeysItem.state == .off)
    altKeysItem.state = config.altKeys ? .on : .off
  }

  @objc private func toggleLayoutSwitcher(sender: NSButton) {
    config.layoutSwitcher = (layoutSwitcherItem.state == .off)
    layoutSwitcherItem.state = config.layoutSwitcher ? .on : .off
    LayoutSwitcher.shared.reload()
  }

  @objc private func toggleWindowControls(sender: NSButton) {
    config.windowControls = (windowControlsItem.state == .off)
    windowControlsItem.state = config.windowControls ? .on : .off
  }

  // Other
  @objc private func toggleBetterDisplayRotation(sender: NSButton) {
    config.betterDisplayRotation = (betterDisplayRotationItem.state == .off)
    betterDisplayRotationItem.state = config.betterDisplayRotation ? .on : .off
  }

  @objc private func toggleInverseScrolling(sender: NSButton) {
    config.inverseScrolling = (inverseScrollingItem.state == .off)
    inverseScrollingItem.state = config.inverseScrolling ? .on : .off
  }

  // Switcher
  @objc private func toggleCmdTabSwitcher(sender: NSButton) {
    config.cmdTabSwitcher = (cmdTabSwitcherItem.state == .off)
    cmdTabSwitcherItem.state = config.cmdTabSwitcher ? .on : .off
  }

  @objc private func toggleAltTapSwitcher(sender: NSButton) {
    config.altTapSwitcher = (altTapSwitcherItem.state == .off)
    altTapSwitcherItem.state = config.altTapSwitcher ? .on : .off
  }

  @objc private func toggleGroupSwitcher(sender: NSButton) {
    config.groupSwitcher = (groupSwitcherItem.state == .off)
    groupSwitcherItem.state = config.groupSwitcher ? .on : .off
  }

  @objc private func toggleGestureSwitcher(sender: NSButton) {
    config.gestureSwitcher = (gestureSwitcherItem.state == .off)
    gestureSwitcherItem.state = config.gestureSwitcher ? .on : .off
  }

  // Touch
  @objc private func toggleTouchMiddleClick(sender: NSButton) {
    config.touchMiddleClick = (touchMiddleClickItem.state == .off)
    touchMiddleClickItem.state = config.touchMiddleClick ? .on : .off
  }

  @objc private func toggleTapToClick(sender: NSButton) {
    config.tapToClick = sender.state == .off
    tapToClickItem.state = config.tapToClick ? .on : .off
  }

  @objc private func toggleTouchNavigation(sender: NSButton) {
    config.touchNavigation = (touchNavigationItem.state == .off)
    touchNavigationItem.state = config.touchNavigation ? .on : .off
  }

  @objc private func toggleTouchRightClick(sender: NSButton) {
    config.touchRightClick = (touchRightClickItem.state == .off)
    touchRightClickItem.state = config.touchRightClick ? .on : .off
  }

  @objc private func openAccessibilitySettings() {
    if #available(macOS 10.15, *) {
      if let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
      {
        NSWorkspace.shared.open(url)
      }
    } else {
      let appleScript = """
        tell application "System Preferences"
          activate
          reveal anchor "Privacy_Accessibility" of pane "com.apple.preference.security"
        end tell
        """
      if let script = NSAppleScript(source: appleScript) {
        script.executeAndReturnError(nil)
      }
    }
  }

  @objc private func actionQuit(sender: Any) {
    NSApp.terminate(sender)
  }

  @objc private func restartNow() {
    app.restartListeners()
  }

  private func createMenuAccessibilityPermissionItems(_ menu: NSMenu) {
    accessibilityPermissionStatusItem = menu.addItem(
      withTitle: "Missing Accessibility permission")
    accessibilityPermissionActionItem = menu.addItem(
      withTitle: "Open Privacy Preferences", action: #selector(openAccessibilitySettings),
      target: self,
      keyEquivalent: ",")
    menu.addSeparator()
  }

  private func getAppName() -> String {
    return ProcessInfo.processInfo.processName
  }

  private func setupStatusItem() {
    statusItem.behavior = .removalAllowed
    statusItem.menu = createMenu()
    statusItem.button?.toolTip = getAppName()
    statusItem.button?.image = createStatusIcon()
  }

  private func createStatusIcon() -> NSImage {
    guard let icon = Bundle.module.image(forResource: "StatusIcon") else {
      return NSImage()
    }
    icon.size = CGSize(width: 25, height: 25)
    return icon
  }
}

extension TrayMenu {
  private static func terminateExistingInstance(force: Bool = true) -> Bool {
    let runningApps = NSRunningApplication.runningApplications(
      withBundleIdentifier: Bundle.main.bundleIdentifier!
    ).filter {
      $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
    }

    for app in runningApps {
      log.info("Terminating existing instance (PID: \(app.processIdentifier))")
      if force { return app.forceTerminate() } else { return app.terminate() }
    }

    return runningApps.count > 0
  }
}

// Launch at login:
extension TrayMenu {
  @objc private func toggleLoginItem() {
    modifyLoginItem(add: launchAtLoginItem.state == .off)
    updateLaunchAtLoginItem()
  }

  private func updateLaunchAtLoginItem() {
    launchAtLoginItem.state = isLoginItemEnabled() ? .on : .off
  }

  private func isLoginItemEnabled() -> Bool {
    if #available(macOS 13.0, *) {
      return SMAppService.mainApp.status == .enabled
    } else {
      let appName = getAppName()
      let script = """
        tell application "System Events" to get name of login item "\(appName)"
        """

      if let appleScript = NSAppleScript(source: script) {
        var errorDict: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorDict)

        if errorDict != nil {
          return false
        }

        return result.stringValue == appName
      }

      return false
    }
  }

  private func modifyLoginItem(add: Bool) {
    if #available(macOS 13.0, *) {
      do {
        if add {
          try SMAppService.mainApp.register()
        } else {
          try SMAppService.mainApp.unregister()
        }
      } catch {
        log.error("Failed to \(add ? "add" : "remove") to login items: \(error)")
      }
    } else {
      let appName = getAppName()
      let script =
        add
        ? """
        tell application "System Events" to make login item at end with properties {path:"/Applications/\(appName).app", hidden:true}
        """
        : """
        tell application "System Events" to delete login item "\(appName)"
        """

      if let appleScript = NSAppleScript(source: script) {
        var errorDict: NSDictionary?
        appleScript.executeAndReturnError(&errorDict)

        if let error = errorDict {
          log.error("Failed to \(add ? "add" : "remove") \(appName) from login items: \(error)")
        }
      }
    }
  }
}

extension NSMenu {
  func addItem(
    withTitle string: String, action selector: Selector, target: AnyObject,
    keyEquivalent charCode: String = ""
  ) -> NSMenuItem {
    let menuItem = NSMenuItem(title: string, action: selector, keyEquivalent: charCode)
    menuItem.target = target
    self.addItem(menuItem)
    return menuItem
  }
  func addItem(withTitle string: String) -> NSMenuItem {
    return self.addItem(withTitle: string, action: nil, keyEquivalent: "")
  }

  func addSeparator() {
    self.addItem(.separator())
  }
}
