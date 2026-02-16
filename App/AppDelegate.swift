import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.localports.app", category: "AppDelegate")
    private var statusBarController: StatusBarController?
    private let settings = AppSettingsStore.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()
        logger.info("Application launched and status bar initialized")

        if !settings.launchInBackground || !settings.hasCompletedOnboarding {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                self?.statusBarController?.showPopoverOnLaunch()
            }
        }
    }
}
