import AppKit
import ServiceManagement
import SwiftUI
import OSLog

@MainActor
final class AppSettingsStore: ObservableObject {
    static let shared = AppSettingsStore()

    @Published var launchInBackground: Bool {
        didSet {
            UserDefaults.standard.set(launchInBackground, forKey: Self.launchInBackgroundKey)
        }
    }
    @Published private(set) var startOnLoginEnabled: Bool
    @Published private(set) var startOnLoginErrorMessage: String?

    private static let launchInBackgroundKey = "LaunchInBackground.v1"

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.launchInBackgroundKey) == nil {
            launchInBackground = true
            defaults.set(true, forKey: Self.launchInBackgroundKey)
        } else {
            launchInBackground = defaults.bool(forKey: Self.launchInBackgroundKey)
        }

        if #available(macOS 13.0, *) {
            startOnLoginEnabled = (SMAppService.mainApp.status == .enabled)
        } else {
            startOnLoginEnabled = false
        }
    }

    func setStartOnLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            startOnLoginErrorMessage = "Start on login requires macOS 13 or newer."
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            startOnLoginEnabled = (SMAppService.mainApp.status == .enabled)
            startOnLoginErrorMessage = nil
        } catch {
            startOnLoginEnabled = (SMAppService.mainApp.status == .enabled)
            startOnLoginErrorMessage = "Could not update login item: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let logger = Logger(subsystem: "com.localports.app", category: "StatusBarController")
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let viewModel = PortsViewModel()
    private let eventMonitor: EventMonitor
    private lazy var contextMenu: NSMenu = makeContextMenu()
    private var settingsWindowController: NSWindowController?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        eventMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { _ in }

        super.init()

        configureStatusItem()
        configurePopover()

        eventMonitor.handler = { [weak self] event in
            guard let self, self.popover.isShown else { return }

            if let eventWindow = event?.window {
                if let popoverWindow = self.popover.contentViewController?.view.window {
                    let isPopoverOrSheetWindow =
                        eventWindow === popoverWindow
                        || eventWindow.sheetParent === popoverWindow
                        || popoverWindow.attachedSheet === eventWindow
                    if isPopoverOrSheetWindow {
                        return
                    }
                }
                if let statusWindow = self.statusItem.button?.window, eventWindow === statusWindow {
                    return
                }
            }

            self.closePopover(nil)
        }
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            let icon = loadStatusIcon()
            icon.size = NSSize(width: 17, height: 17)
            icon.isTemplate = true

            button.image = icon
            button.title = ""
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseDown])
        }
    }

    private func configurePopover() {
        // Managed manually with EventMonitor; this keeps SwiftUI sheets usable.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentSize = NSSize(width: 468, height: 620)
        popover.contentViewController = NSHostingController(rootView: PortsPopoverView(viewModel: viewModel))
    }

    @objc
    private func handleStatusItemClick(_ sender: AnyObject?) {
        let event = NSApp.currentEvent
        let isRightClick =
            event?.buttonNumber == 1
            || event?.type == .rightMouseDown
            || event?.type == .rightMouseUp
            || (event?.buttonNumber == 0 && event?.modifierFlags.contains(.control) == true)

        if isRightClick {
            showContextMenu(event: event)
            return
        }

        if popover.isShown {
            closePopover(sender)
        } else {
            showPopover(sender)
        }
    }

    private func showPopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        eventMonitor.start()
        logger.debug("Popover shown")
    }

    func showPopoverOnLaunch() {
        guard !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        showPopover(nil)
    }

    private func closePopover(_ sender: AnyObject?) {
        popover.performClose(sender)
        eventMonitor.stop()
        logger.debug("Popover closed")
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func showContextMenu(event: NSEvent?) {
        closePopover(nil)
        guard let button = statusItem.button else { return }
        if let event {
            NSMenu.popUpContextMenu(contextMenu, with: event, for: button)
        } else {
            statusItem.menu = contextMenu
            button.performClick(nil)
            statusItem.menu = nil
        }
    }

    @objc
    private func openSettings(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        showSettingsWindow()
    }

    @objc
    private func quitApp(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    private func loadStatusIcon() -> NSImage {
        if let symbol = NSImage(
            systemSymbolName: "point.3.filled.connected.trianglepath.dotted",
            accessibilityDescription: "LocalPorts"
        ) {
            return symbol
        }

        if let bundledURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let bundledImage = NSImage(contentsOf: bundledURL) {
            return bundledImage
        }

        return NSImage(systemSymbolName: "network", accessibilityDescription: "LocalPorts")
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    private func showSettingsWindow() {
        if settingsWindowController == nil {
            let content = SettingsPanelView()
            let hostingController = NSHostingController(rootView: content)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]

            hostingController.view.layoutSubtreeIfNeeded()
            let fittingSize = hostingController.view.fittingSize
            let contentSize = NSSize(
                width: max(540, fittingSize.width),
                height: max(520, fittingSize.height)
            )
            window.setContentSize(contentSize)
            window.minSize = contentSize
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }

        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsPanelView: View {
    @ObservedObject private var settings = AppSettingsStore.shared

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LocalPorts Settings")
                .font(.title3.weight(.semibold))

            Text("Configure how LocalPorts starts and what you see at launch.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GroupBox("Startup Options") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "Start LocalPorts app on login",
                        isOn: Binding(
                            get: { settings.startOnLoginEnabled },
                            set: { settings.setStartOnLogin($0) }
                        )
                    )

                    Text("When enabled, LocalPorts starts automatically after you sign in to macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle(
                        "Launch in the background",
                        isOn: $settings.launchInBackground
                    )

                    Text("When enabled, LocalPorts stays in the menu bar only. When disabled, the services panel opens on startup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let errorMessage = settings.startOnLoginErrorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Quick Guide") {
                VStack(alignment: .leading, spacing: 8) {
                    guideLine("Left-click the menu bar icon to open your services.")
                    guideLine("Use the play/stop button to start or stop a service.")
                    guideLine("Use the three-dot menu for Rename, Edit, Show in Finder, and Force Stop.")
                    guideLine("Use the + button to add your own localhost service.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Tips") {
                VStack(alignment: .leading, spacing: 8) {
                    guideLine("Set a Project Folder and Start Command if you want LocalPorts to start the service for you.")
                    guideLine("Show in Finder quickly opens the configured project folder.")
                    guideLine("If a service appears stuck, use Refresh to re-check active ports.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            LabeledContent("Version", value: appVersion)
            LabeledContent("Mode", value: "Menu Bar")
        }
        .padding(20)
        .frame(width: 520, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func guideLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private final class EventMonitor {
    private let mask: NSEvent.EventTypeMask
    var handler: (NSEvent?) -> Void

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent?) -> Void) {
        self.mask = mask
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else {
            return
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handler(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handler(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }
}
