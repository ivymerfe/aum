import AppKit
import OSLog

let log = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "app")
let restartLog = Logger(
    subsystem: Bundle.main.bundleIdentifier!,
    category: "schedule"
)

@main
struct AumApp {
    static func main() {
        let app = NSApplication.shared

        let accessibilityMonitor = AccessibilityMonitor()
        let trayMenu = TrayMenu(accessibilityMonitor: accessibilityMonitor)
        let controller = Controller(accessibilityMonitor: accessibilityMonitor, trayMenu: trayMenu)
        controller.start()
        trayMenu.restartListeners = controller.restartListeners

        accessibilityMonitor.start()

        app.delegate = trayMenu
        app.run()
    }
}
