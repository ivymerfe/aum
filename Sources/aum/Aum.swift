import AppKit
import Carbon
import OSLog

let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "app")
let restartLog = Logger(
    subsystem: Bundle.main.bundleIdentifier!,
    category: "schedule"
)

@MainActor
final class GlobalState {
    static let shared = GlobalState()
    private init() {
    }
    var threeDown = false
    var nFingers = 0
    var wasThreeDown = false
    var naturalMiddleClickLastTime: Date?
    var syntheticEventsToPassThrough: Int = 0
}

@MainActor final class Config: ConfigCore {
    @UserDefault var capsLockSwitch = true

    @UserDefault var instantSpaces = true

    @UserDefault var tapToClick = SystemPermissions.getIsSystemTapToClickEnabled

    @UserDefault("fingers")
    var minimumFingers = 3

    @UserDefault var allowMoreFingers = false

    @UserDefault var maxDistanceDelta: Float = 0.05

    @UserDefault(transformGet: { $0 / 1000 })
    var maxTimeDelta = 300.0
}

@main
@MainActor final class AumApp: PointerableObject {
    private static var instance: AumApp?
    private static let config = Config.shared
    private static let state = GlobalState.shared
    private static let wakeRestartTimeout: TimeInterval = 10

    private lazy var multitouchManager = IOMultitouchManager {
        self.scheduleRestart(2, reason: "Multitouch device added")
    }

    private var restartTimer: Timer?
    private(set) var isUserSessionActive = true

    let accessibilityMonitor: AccessibilityMonitor = AccessibilityMonitor()

    static func getInstance() -> AumApp {
        if let instance = instance {
            return instance
        }
        let newInstance = AumApp()
        instance = newInstance
        return newInstance
    }

    static func main() {
        let app = getInstance()
        app.start()
    }

    func start() {
        log.info("Starting listeners...")

        TouchHandler.shared.registerTouchCallback()
        observeSystemNotifications()
        multitouchManager.setupMultitouchListener()
        setupDisplayReconfigurationCallback()

        let trayMenu = TrayMenu()

        accessibilityMonitor.addListener { becameTrusted in
            if becameTrusted {
                _ = CGEventListener.shared.start()
            } else {
                trayMenu.isStatusItemVisible = true
                CGEventListener.shared.stop()
            }
        }
        checkForConflicts()

        accessibilityMonitor.start()
        let app = NSApplication.shared
        app.delegate = trayMenu
        app.run()
    }

    func scheduleRestart(_ delay: TimeInterval, reason: String) {
        guard isUserSessionActive else {
            restartLog.info("\(reason), but user session is inactive - skipping restart")
            return
        }
        restartLog.info("\(reason), restarting in \(delay)")
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor in AumApp.getInstance().restartListeners() }
        }
    }

    func restartListeners() {
        log.info("Restarting now...")
        stopUnstableListeners()
        guard isUserSessionActive else { return }
        startUnstableListeners()
        log.info("Restart success.")
    }

    private func startUnstableListeners() {
        TouchHandler.shared.registerTouchCallback()
        _ = CGEventListener.shared.start()
    }

    private func stopUnstableListeners() {
        TouchHandler.shared.unregisterTouchCallback()
        CGEventListener.shared.stop()
    }

    private func observeSystemNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(receiveWakeNote),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(receiveSessionResignActiveNote),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(receiveSessionBecomeActiveNote),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func receiveSessionResignActiveNote(_ note: Notification) {
        log.info("User session resigned active, stopping listeners")
        isUserSessionActive = false
        restartTimer?.invalidate()
        restartTimer = nil
        stopUnstableListeners()
    }

    @objc private func receiveSessionBecomeActiveNote(_ note: Notification) {
        log.info("User session became active, restarting listeners")
        isUserSessionActive = true
        restartListeners()
    }

    @objc private func receiveWakeNote(_ note: Notification) {
        scheduleRestart(Self.wakeRestartTimeout, reason: "System woke up")
    }

    static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = {
        _, flags, userData in
        if !flags.isDisjoint(with: [.setModeFlag, .addFlag, .removeFlag, .disabledFlag]) {
            AumApp.from(pointer: userData).scheduleRestart(2, reason: "Display reconfigured")
        }
    }

    private func setupDisplayReconfigurationCallback() {
        CGDisplayRegisterReconfigurationCallback(
            Self.displayReconfigurationCallback,
            rawPointer
        )
    }

    private func checkForConflicts() {
        accessibilityMonitor.addListener { becameTrusted in
            guard becameTrusted, Self.config.minimumFingers == 3 else { return }

            let threeFingerDragConflict = SystemPermissions.getIsSystemThreeFingerDragEnabled()
            let threeFingerTapConflict =
                SystemPermissions.getIsSystemThreeFingerTapEnabled() && Self.config.tapToClick

            var issues: [String] = []
            if threeFingerDragConflict {
                issues.append(
                    """
                    Dragging style: "Three Finger Drag"
                    Issue — won't function, also adds an unintended left click to any middle click.
                    Workarounds — Opt in for another Dragging style, or Choose to 'Ignore Finder' in the status menu of MiddleClick.
                    """)
            }
            if threeFingerTapConflict {
                issues.append(
                    """
                    Look up & data detectors: "Tap with Three Fingers"
                    Issue — will fire simultaneously with MiddleClick.
                    Workarounds — Disable 'Tap to click' in the status menu of MiddleClick.
                    """)
            }
            guard !issues.isEmpty else { return }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.messageText = issues.count > 1 ? "Conflicting gestures" : "Conflicting gesture"
            alert.informativeText = issues.joined(separator: "\n\n")
            alert.runModal()
        }
    }
}
