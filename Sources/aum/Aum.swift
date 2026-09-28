import AppKit
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
        Config.shared.$ignoredAppBundles.onSet {
            self.ignoredAppBundlesCache = $0
        }
    }

    var threeDown = false
    var wasThreeDown = false
    var naturalMiddleClickLastTime: Date?
    /// stored locally, since accessing the cache is more CPU-expensive than a local variable
    var ignoredAppBundlesCache = Config.shared.ignoredAppBundles
}

@MainActor final class Config: ConfigCore {
    required init() {
        Self.options.cacheAll = true
    }

    @UserDefault("fingers")
    var minimumFingers = 3

    @UserDefault var allowMoreFingers = false

    @UserDefault var maxDistanceDelta: Float = 0.05

    @UserDefault(transformGet: { $0 / 1000 })
    var maxTimeDelta = 300.0

    @UserDefault var tapToClick = SystemPermissions.getIsSystemTapToClickEnabled

    @UserDefault var ignoredAppBundles = Set<String>()
}

@main
@MainActor final class AumApp: PointerableObject, Sendable {
    private static let config = Config.shared
    private static let state = GlobalState.shared
    private static let wakeRestartTimeout: TimeInterval = 10
    private static let kCGMouseButtonCenter = Int64(CGMouseButton.center.rawValue)

    private lazy var multitouchManager = IOMultitouchManager {
        self.scheduleRestart(2, reason: "Multitouch device added")
    }

    private var restartTimer: Timer?

    private(set) var isUserSessionActive = true

    let accessibilityMonitor: AccessibilityMonitor
    let trayMenu: TrayMenu

    static func main() {
        let app = NSApplication.shared

        let accessibilityMonitor = AccessibilityMonitor()
        let trayMenu = TrayMenu(accessibilityMonitor: accessibilityMonitor)
        let controller = AumApp(accessibilityMonitor: accessibilityMonitor, trayMenu: trayMenu)
        controller.start()
        trayMenu.restartListeners = controller.restartListeners

        accessibilityMonitor.start()

        app.delegate = trayMenu
        app.run()
    }

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
        observeSystemNotifications()
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

    func scheduleRestart(_ delay: TimeInterval, reason: String) {
        guard isUserSessionActive else {
            restartLog.info("\(reason), but user session is inactive - skipping restart")
            return
        }
        restartLog.info("\(reason), restarting in \(delay)")
        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            Task { @MainActor in self.restartListeners() }
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
        _ = Self.mouseEventHandler.start()
    }

    private func stopUnstableListeners() {
        TouchHandler.shared.unregisterTouchCallback()
        Self.mouseEventHandler.stop()
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
