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

  private var capsLockSwitcherItem: NSMenuItem!
  private var instantSpaceSwitcher: NSMenuItem!
  private var middleClickItem: NSMenuItem!
  private var tapToClickItem: NSMenuItem!

  private var launchAtLoginItem: NSMenuItem!
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

  var isStatusItemVisible: Bool {
    get { statusItem.isVisible }
    set { statusItem.isVisible = newValue }
  }

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

    capsLockSwitcherItem = menu.addItem(
      withTitle: "Caps layout switcher",
      action: #selector(toggleCapsLockSwitcher),
      target: self
    )

    instantSpaceSwitcher = menu.addItem(
      withTitle: "Instant space switcher",
      action: #selector(toggleInstantSpaces),
      target: self
    )

    menu.addSeparator()

    middleClickItem = menu.addItem(
      withTitle: "Middle click emulation",
      action: #selector(toggleMiddleClick),
      target: self
    )

    tapToClickItem = menu.addItem(
      withTitle: "Tap to click", action: #selector(toggleTapToClick), target: self)

    menu.addSeparator()

    launchAtLoginItem = menu.addItem(
      withTitle: "Launch at login",
      action: #selector(toggleLoginItem),
      target: self
    )
    _ = menu.addItem(
      withTitle: "Restart listeners",
      action: #selector(restartNow),
      target: self,
      keyEquivalent: "r"
    )
    menu.addSeparator()
    _ = menu.addItem(
      withTitle: "Quit", action: #selector(actionQuit), target: self, keyEquivalent: "q")

    updateCapsLockSwitcherItem()
    updateInstantSpacesItem()
    updateMiddleClickItem()
    updateTapToClickItem()
    updateLaunchAtLoginItem()
    return menu
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

// MARK: Actions
extension TrayMenu {
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

  @objc private func toggleCapsLockSwitcher(sender: NSButton) {
    config.capsLockSwitcher = (capsLockSwitcherItem.state == .off)
    updateCapsLockSwitcherItem()
  }

  private func updateCapsLockSwitcherItem() {
    capsLockSwitcherItem.state = config.capsLockSwitcher ? .on : .off
  }

  @objc private func toggleInstantSpaces(sender: NSButton) {
    config.instantSpaces = (instantSpaceSwitcher.state == .off)
    updateInstantSpacesItem()
  }

  private func updateInstantSpacesItem() {
    instantSpaceSwitcher.state = config.instantSpaces ? .on : .off
  }

  @objc private func toggleMiddleClick(sender: NSButton) {
    config.middleClick = (middleClickItem.state == .off)
    updateMiddleClickItem()
  }

  private func updateMiddleClickItem() {
    middleClickItem.state = config.middleClick ? .on : .off
    tapToClickItem.isEnabled = config.middleClick
  }

  @objc private func toggleTapToClick(sender: NSButton) {
    config.tapToClick = sender.state == .off
    updateTapToClickItem()
  }

  private func updateTapToClickItem() {
    tapToClickItem.state = config.tapToClick ? .on : .off
  }

  @objc private func actionQuit(sender: Any) {
    NSApp.terminate(sender)
  }

  @objc private func restartNow() {
    app.restartListeners()
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
