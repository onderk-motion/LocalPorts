import AppKit
import ServiceManagement
import SwiftUI
import OSLog
import UniformTypeIdentifiers

@MainActor
final class AppSettingsStore: ObservableObject {
    struct DiagnosticsFile: Identifiable {
        let id: String
        let name: String
        let modifiedText: String
        let sizeText: String
        let url: URL
    }

    static let shared = AppSettingsStore()

    @Published var launchInBackground: Bool {
        didSet {
            guard !isSyncingFromConfig else { return }
            persistLaunchPreference()
        }
    }
    @Published var showProcessDetails: Bool {
        didSet {
            guard !isSyncingFromConfig else { return }
            persistProcessDetailsPreference()
        }
    }
    @Published var selectedBrowserBundleID: String? {
        didSet {
            guard !isSyncingFromConfig else { return }
            persistPreferredBrowser()
        }
    }
    @Published private(set) var startOnLoginEnabled: Bool
    @Published private(set) var startOnLoginErrorMessage: String?
    @Published private(set) var hasCompletedOnboarding: Bool
    @Published private(set) var onboardingActionMessage: String?
    @Published private(set) var configActionMessage: String?
    @Published private(set) var diagnosticsActionMessage: String?
    @Published private(set) var diagnosticsFiles: [DiagnosticsFile] = []
    @Published private(set) var availableBrowsers: [ActionsService.BrowserOption] = []

    private let logger = Logger(subsystem: "com.localports.app", category: "AppSettingsStore")
    private let configStore = AppConfigStore.shared
    private let fileManager = FileManager.default
    private var isSyncingFromConfig = false

    private lazy var diagnosticsDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private lazy var byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter
    }()

    private init() {
        let config = configStore.loadOrCreateConfig(
            defaultBuiltInServices: PortsViewModel.defaultBuiltInServices,
            legacyCompatibilityUntilVersion: LegacyMigrationService.legacyCompatibilityUntilVersion
        )

        launchInBackground = config.appSettings.launchInBackground
        showProcessDetails = config.appSettings.showProcessDetails
        selectedBrowserBundleID = Self.trimmedOrNil(config.appSettings.preferredBrowserBundleID)
        hasCompletedOnboarding = config.hasCompletedOnboarding

        if #available(macOS 13.0, *) {
            startOnLoginEnabled = (SMAppService.mainApp.status == .enabled)
        } else {
            startOnLoginEnabled = false
        }

        refreshAvailableBrowsers()
        refreshDiagnostics()
    }

    func refreshFromConfig() {
        let config = configStore.loadOrCreateConfig(
            defaultBuiltInServices: PortsViewModel.defaultBuiltInServices,
            legacyCompatibilityUntilVersion: LegacyMigrationService.legacyCompatibilityUntilVersion
        )
        syncFromConfig(config)
    }

    func exportConfiguration() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "LocalPorts-config.json"
        panel.canCreateDirectories = true
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        do {
            try configStore.exportConfig(to: destinationURL)
            configActionMessage = "Configuration exported to \(destinationURL.lastPathComponent)."
        } catch {
            logger.error("Failed to export config: \(error.localizedDescription, privacy: .public)")
            configActionMessage = "Could not export configuration: \(error.localizedDescription)"
        }
    }

    func importConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import"

        guard panel.runModal() == .OK, let sourceURL = panel.url else {
            return
        }

        do {
            let imported = try configStore.importConfig(
                from: sourceURL,
                defaultBuiltInServices: PortsViewModel.defaultBuiltInServices
            )
            syncFromConfig(imported)
            configActionMessage = "Configuration imported from \(sourceURL.lastPathComponent). Start commands are trusted automatically."
        } catch {
            logger.error("Failed to import config: \(error.localizedDescription, privacy: .public)")
            configActionMessage = "Could not import configuration: \(error.localizedDescription)"
        }
    }

    func openConfigDirectory() {
        let configPath = configStore.configFilePath()
        let configURL = URL(fileURLWithPath: configPath)
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    func setStartOnLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else {
            startOnLoginErrorMessage = "Start on login requires macOS 13 or newer."
            return
        }

        guard !enabled || isInstalledInApplications() else {
            startOnLoginEnabled = currentStartOnLoginStatus()
            startOnLoginErrorMessage = "Move LocalPorts to /Applications first, then try again. If needed, run LocalPorts-Install.command from the release."
            return
        }

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            startOnLoginEnabled = currentStartOnLoginStatus()
            startOnLoginErrorMessage = nil
        } catch {
            startOnLoginEnabled = currentStartOnLoginStatus()
            startOnLoginErrorMessage = "Could not update Start on Login. Make sure LocalPorts is in /Applications, then open Login Items Settings and try again."
            logger.error("Failed to update start on login: \(error.localizedDescription, privacy: .public)")
        }
    }

    func openLoginItemsSettings() {
        guard #available(macOS 13.0, *) else {
            startOnLoginErrorMessage = "Login Items settings require macOS 13 or newer."
            return
        }

        SMAppService.openSystemSettingsLoginItems()
    }

    func showOnboardingAgain() {
        do {
            let updated = try configStore.update { config in
                config.hasCompletedOnboarding = false
            }
            hasCompletedOnboarding = updated.hasCompletedOnboarding
            onboardingActionMessage = "Onboarding guide will appear the next time you open the services panel."
        } catch {
            logger.error("Failed to reset onboarding from settings: \(error.localizedDescription, privacy: .public)")
            onboardingActionMessage = "Could not reset onboarding guide."
        }
    }

    func refreshDiagnostics() {
        let logsURL = diagnosticsDirectoryURL()
        guard let files = try? fileManager.contentsOfDirectory(
            at: logsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            diagnosticsFiles = []
            return
        }

        let rows = files
            .filter { $0.pathExtension.lowercased() == "log" }
            .map { url -> (url: URL, modifiedAt: Date, fileSize: Int64) in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return (
                    url,
                    values?.contentModificationDate ?? .distantPast,
                    Int64(values?.fileSize ?? 0)
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(8)

        diagnosticsFiles = rows.map { item in
            DiagnosticsFile(
                id: item.url.path,
                name: item.url.lastPathComponent,
                modifiedText: diagnosticsDateFormatter.string(from: item.modifiedAt),
                sizeText: byteCountFormatter.string(fromByteCount: item.fileSize),
                url: item.url
            )
        }
    }

    func refreshAvailableBrowsers() {
        let discovered = ActionsService.shared.availableBrowsers()

        isSyncingFromConfig = true
        availableBrowsers = discovered

        if let selected = selectedBrowserBundleID,
           !selected.isEmpty,
           !discovered.contains(where: { $0.bundleIdentifier == selected }) {
            selectedBrowserBundleID = nil
        }
        isSyncingFromConfig = false
    }

    func openDiagnosticsFolder() {
        let logsURL = diagnosticsDirectoryURL()

        do {
            try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create diagnostics directory: \(error.localizedDescription, privacy: .public)")
        }

        NSWorkspace.shared.open(logsURL)
    }

    func openDiagnosticsFile(_ file: DiagnosticsFile) {
        NSWorkspace.shared.open(file.url)
    }

    func clearDiagnostics() {
        let logsURL = diagnosticsDirectoryURL()
        do {
            let files = try fileManager.contentsOfDirectory(at: logsURL, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension.lowercased() == "log" {
                try? fileManager.removeItem(at: file)
            }
            refreshDiagnostics()
            diagnosticsActionMessage = "Diagnostics logs cleared."
        } catch {
            logger.error("Failed to clear diagnostics logs: \(error.localizedDescription, privacy: .public)")
            diagnosticsActionMessage = "Could not clear diagnostics logs."
        }
    }

    private func syncFromConfig(_ config: AppConfig) {
        isSyncingFromConfig = true
        launchInBackground = config.appSettings.launchInBackground
        showProcessDetails = config.appSettings.showProcessDetails
        selectedBrowserBundleID = Self.trimmedOrNil(config.appSettings.preferredBrowserBundleID)
        isSyncingFromConfig = false

        hasCompletedOnboarding = config.hasCompletedOnboarding
        startOnLoginEnabled = currentStartOnLoginStatus()
        refreshAvailableBrowsers()
    }

    private func currentStartOnLoginStatus() -> Bool {
        guard #available(macOS 13.0, *) else {
            return false
        }
        return SMAppService.mainApp.status == .enabled
    }

    private func isInstalledInApplications() -> Bool {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let expectedURL = URL(fileURLWithPath: "/Applications/LocalPorts.app", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return bundleURL.path == expectedURL.path
    }

    private func persistLaunchPreference() {
        do {
            _ = try configStore.update { config in
                config.appSettings.launchInBackground = launchInBackground
            }
        } catch {
            logger.error("Failed to persist launch preference: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistProcessDetailsPreference() {
        do {
            _ = try configStore.update { config in
                config.appSettings.showProcessDetails = showProcessDetails
            }
        } catch {
            logger.error("Failed to persist process details preference: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistPreferredBrowser() {
        do {
            _ = try configStore.update { config in
                config.appSettings.preferredBrowserBundleID = Self.trimmedOrNil(selectedBrowserBundleID)
            }
        } catch {
            logger.error("Failed to persist preferred browser: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func diagnosticsDirectoryURL() -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LocalPorts", isDirectory: true)
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
    private var openSettingsObserver: NSObjectProtocol?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        eventMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { _ in }

        super.init()

        configureStatusItem()
        configurePopover()
        configureOpenSettingsObserver()

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

    deinit {
        if let openSettingsObserver {
            NotificationCenter.default.removeObserver(openSettingsObserver)
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

    private func configureOpenSettingsObserver() {
        openSettingsObserver = NotificationCenter.default.addObserver(
            forName: .localPortsOpenSettingsRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.closePopover(nil)
                self.openSettings(nil)
            }
        }
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
        AppSettingsStore.shared.refreshFromConfig()
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
        return "v\(version)"
    }

    private var configFilePath: String {
        AppConfigStore.shared.configFilePath()
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

                    Button("Open Login Items Settings") {
                        settings.openLoginItemsSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if let errorMessage = settings.startOnLoginErrorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Browser & Display") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "Show process details in service cards",
                        isOn: $settings.showProcessDetails
                    )

                    Text("Adds process name, pid, and user in the running state line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker(
                        "Open button browser",
                        selection: Binding(
                            get: { settings.selectedBrowserBundleID ?? "" },
                            set: { settings.selectedBrowserBundleID = $0.isEmpty ? nil : $0 }
                        )
                    ) {
                        Text("System Default").tag("")
                        ForEach(settings.availableBrowsers) { browser in
                            Text(browser.name).tag(browser.bundleIdentifier)
                        }
                    }
                    .pickerStyle(.menu)

                    Button("Refresh browser list") {
                        settings.refreshAvailableBrowsers()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Onboarding") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(settings.hasCompletedOnboarding
                        ? "The first-run onboarding is currently completed for this Mac user."
                        : "Onboarding is currently enabled and will be shown in the services panel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Show onboarding again") {
                        settings.showOnboardingAgain()
                    }
                    .disabled(!settings.hasCompletedOnboarding)

                    if let onboardingMessage = settings.onboardingActionMessage {
                        Text(onboardingMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Configuration Backup") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Button("Export") {
                            settings.exportConfiguration()
                        }

                        Button("Import") {
                            settings.importConfiguration()
                        }

                        Button("Show Config File") {
                            settings.openConfigDirectory()
                        }
                    }

                    Text(configFilePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)

                    if let configMessage = settings.configActionMessage {
                        Text(configMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Diagnostics Logs") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Button("Refresh") {
                            settings.refreshDiagnostics()
                        }

                        Button("Open Folder") {
                            settings.openDiagnosticsFolder()
                        }

                        Button("Clear") {
                            settings.clearDiagnostics()
                        }
                    }

                    if settings.diagnosticsFiles.isEmpty {
                        Text("No diagnostics logs found yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(settings.diagnosticsFiles) { file in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.name)
                                        .font(.caption.weight(.semibold))
                                    Text("\(file.modifiedText) · \(file.sizeText)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Open") {
                                    settings.openDiagnosticsFile(file)
                                }
                            }
                        }
                    }

                    if let diagnosticsMessage = settings.diagnosticsActionMessage {
                        Text(diagnosticsMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        .frame(width: 560, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            settings.refreshFromConfig()
            settings.refreshDiagnostics()
        }
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
