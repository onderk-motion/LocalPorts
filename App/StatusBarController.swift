import AppKit
import Combine
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
    /// Service IDs whose crash notifications are silenced. Pro feature.
    @Published var disabledCrashNotificationIDs: Set<String> = [] {
        didSet {
            guard !isSyncingFromConfig else { return }
            persistDisabledCrashNotifications()
        }
    }
    /// Hex accent color override. nil = system default. Pro feature.
    @Published var accentColorHex: String? = nil {
        didSet {
            guard !isSyncingFromConfig else { return }
            persistAccentColor()
        }
    }
    /// Named popover background theme. nil = "Graphite" (default). Pro feature.
    @Published var backgroundThemeName: String? = nil {
        didSet {
            guard !isSyncingFromConfig else { return }
            persistBackgroundTheme()
        }
    }
    /// Webhook URL for crash notifications (Pro feature). nil = disabled.
    @Published var webhookURL: String? = nil {
        didSet {
            guard !isSyncingFromConfig else { return }
            persistWebhookURL()
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
        disabledCrashNotificationIDs = config.appSettings.disabledCrashNotificationIDs
        accentColorHex = config.appSettings.accentColorHex
        backgroundThemeName = config.appSettings.backgroundThemeName
        webhookURL = config.appSettings.webhookURL
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
        disabledCrashNotificationIDs = config.appSettings.disabledCrashNotificationIDs
        accentColorHex = config.appSettings.accentColorHex
        backgroundThemeName = config.appSettings.backgroundThemeName
        webhookURL = config.appSettings.webhookURL
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

    private func persistDisabledCrashNotifications() {
        do {
            _ = try configStore.update { config in
                config.appSettings.disabledCrashNotificationIDs = disabledCrashNotificationIDs
            }
        } catch {
            logger.error("Failed to persist notification preferences: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistAccentColor() {
        do {
            _ = try configStore.update { config in
                config.appSettings.accentColorHex = accentColorHex
            }
        } catch {
            logger.error("Failed to persist accent color: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistBackgroundTheme() {
        do {
            _ = try configStore.update { config in
                config.appSettings.backgroundThemeName = backgroundThemeName
            }
        } catch {
            logger.error("Failed to persist background theme: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistWebhookURL() {
        do {
            _ = try configStore.update { config in
                let trimmed = webhookURL?.trimmingCharacters(in: .whitespacesAndNewlines)
                config.appSettings.webhookURL = trimmed.flatMap { $0.isEmpty ? nil : $0 }
            }
        } catch {
            logger.error("Failed to persist webhook URL: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Returns (id, name) pairs from the current active profile for UI display.
    var currentProfileServices: [(id: String, name: String)] {
        guard let config = configStore.currentConfigSnapshot() else { return [] }
        let profile = config.profiles.first(where: { $0.id == config.selectedProfileID })
            ?? config.profiles.first
        guard let profile else { return [] }
        return profile.serviceConfigurations.map { (id: $0.id, name: $0.name) }
    }

    /// The resolved accent Color from the stored hex, or `.accentColor` if unset.
    var accentColor: Color {
        guard let hex = accentColorHex else { return .accentColor }
        return Color(hex: hex) ?? .accentColor
    }

    /// The resolved PopoverTheme (Pro only; falls back to .graphite for free users).
    var backgroundTheme: PopoverTheme {
        guard ProGate.isAllowed(.themes) else { return .graphite }
        return PopoverTheme.named(backgroundThemeName) ?? .graphite
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
    private var upgradeWindowController: NSWindowController?
    private var addEditWindowController: NSWindowController?
    private var openSettingsObserver: NSObjectProtocol?
    private var showUpgradeObserver: NSObjectProtocol?
    private var openAddServiceObserver: NSObjectProtocol?
    private var openEditServiceObserver: NSObjectProtocol?
    private var openServiceLogObserver: NSObjectProtocol?
    private var logWindowController: NSWindowController?
    private var badgeCancellables = Set<AnyCancellable>()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        eventMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { _ in }

        super.init()

        configureStatusItem()
        configurePopover()
        configureOpenSettingsObserver()
        configureShowUpgradeObserver()
        configureAddEditServiceObservers()
        configureServiceLogObserver()
        configureMenuBarBadge()

        eventMonitor.handler = { [weak self] event in
            guard let self, self.popover.isShown else { return }
            guard NSApp.modalWindow == nil else { return }

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
        if let showUpgradeObserver {
            NotificationCenter.default.removeObserver(showUpgradeObserver)
        }
        if let openServiceLogObserver {
            NotificationCenter.default.removeObserver(openServiceLogObserver)
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
        // Force active appearance — LSUIElement apps can't become key window,
        // which causes SwiftUI to render everything dimmed/inactive.
        popover.contentViewController = NSHostingController(
            rootView: PortsPopoverView(viewModel: viewModel)
                .environment(\.controlActiveState, .key)
        )
    }

    private func configureMenuBarBadge() {
        viewModel.$serviceStates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] states in
                self?.updateMenuBarBadge(states: states)
            }
            .store(in: &badgeCancellables)

        LicenseManager.shared.$isProActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuBarBadge(states: self?.viewModel.serviceStates ?? [:])
            }
            .store(in: &badgeCancellables)
    }

    private func updateMenuBarBadge(states: [String: ManagedServiceState]) {
        guard let button = statusItem.button else { return }
        guard ProGate.isAllowed(.menuBarBadge) else {
            button.title = ""
            button.imagePosition = .imageOnly
            return
        }
        let count = states.values.filter { if case .running = $0 { return true }; return false }.count
        if count > 0 {
            button.title = " \(count)"
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
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

    private func configureShowUpgradeObserver() {
        showUpgradeObserver = NotificationCenter.default.addObserver(
            forName: .localPortsShowUpgradeRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.closePopover(nil)
                self.showUpgradeWindow()
            }
        }
    }

    private func showUpgradeWindow() {
        if upgradeWindowController == nil {
            let content = ProUpgradeSheet()
            let hostingController = NSHostingController(rootView: content)
            let window = NSPanel(contentViewController: hostingController)
            window.title = "LocalPorts Pro"
            window.styleMask = [.titled, .closable, .nonactivatingPanel]
            window.titlebarAppearsTransparent = false
            window.hidesOnDeactivate = false
            hostingController.view.layoutSubtreeIfNeeded()
            let size = hostingController.view.fittingSize
            window.setContentSize(NSSize(width: max(380, size.width), height: max(520, size.height)))
            window.isReleasedWhenClosed = false
            window.center()
            upgradeWindowController = NSWindowController(window: window)
        }
        NSApp.activate(ignoringOtherApps: true)
        upgradeWindowController?.showWindow(nil)
        upgradeWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func configureAddEditServiceObservers() {
        openAddServiceObserver = NotificationCenter.default.addObserver(
            forName: .localPortsOpenAddServiceRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.closePopover(nil)
                self.showAddEditServiceWindow(mode: .add)
            }
        }

        openEditServiceObserver = NotificationCenter.default.addObserver(
            forName: .localPortsOpenEditServiceRequested,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let serviceID = notification.userInfo?["serviceID"] as? String,
                      let data = self.viewModel.serviceEditorData(for: serviceID) else { return }
                self.closePopover(nil)
                self.showAddEditServiceWindow(mode: .edit(data: data))
            }
        }
    }

    private func showAddEditServiceWindow(mode: AddEditServiceMode) {
        // Close any existing add/edit window first
        addEditWindowController?.close()
        addEditWindowController = nil

        let content = AddEditServicePanelView(
            viewModel: viewModel,
            mode: mode
        ) { [weak self] in
            self?.addEditWindowController?.close()
            self?.addEditWindowController = nil
        }

        let hostingController = NSHostingController(rootView: content)
        let window = NSPanel(contentViewController: hostingController)

        switch mode {
        case .add:
            window.title = "Add Service"
        case .edit(let data):
            window.title = "Edit — \(data.name)"
        }

        window.styleMask = [.titled, .closable, .nonactivatingPanel]
        window.titlebarAppearsTransparent = false
        window.hidesOnDeactivate = false
        hostingController.view.layoutSubtreeIfNeeded()
        let size = hostingController.view.fittingSize
        window.setContentSize(NSSize(width: max(460, size.width), height: max(480, size.height)))
        window.isReleasedWhenClosed = false
        window.center()

        addEditWindowController = NSWindowController(window: window)
        NSApp.activate(ignoringOtherApps: true)
        addEditWindowController?.showWindow(nil)
        addEditWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    private func configureServiceLogObserver() {
        openServiceLogObserver = NotificationCenter.default.addObserver(
            forName: .localPortsOpenServiceLogRequested,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let serviceID = notification.userInfo?["serviceID"] as? String,
                      let serviceName = notification.userInfo?["serviceName"] as? String else { return }
                self.showServiceLogWindow(serviceID: serviceID, serviceName: serviceName)
            }
        }
    }

    private func showServiceLogWindow(serviceID: String, serviceName: String) {
        logWindowController?.close()
        logWindowController = nil

        let content = ServiceLogPanelView(
            serviceID: serviceID,
            serviceName: serviceName,
            viewModel: viewModel
        ) { [weak self] in
            self?.logWindowController?.close()
            self?.logWindowController = nil
        }

        let hostingController = NSHostingController(rootView: content)
        let window = NSPanel(contentViewController: hostingController)
        window.title = "Logs — \(serviceName)"
        window.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
        window.titlebarAppearsTransparent = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 600, height: 420))
        window.minSize = NSSize(width: 420, height: 280)
        window.center()

        logWindowController = NSWindowController(window: window)
        NSApp.activate(ignoringOtherApps: true)
        logWindowController?.showWindow(nil)
        logWindowController?.window?.makeKeyAndOrderFront(nil)
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

        NSApp.activate(ignoringOtherApps: true)
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
            window.title = "LocalPorts Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 640, height: 460))
            window.minSize = NSSize(width: 580, height: 400)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }

        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, notifications, license, data, guide
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:       return "General"
        case .appearance:    return "Appearance"
        case .notifications: return "Notifications"
        case .license:       return "License"
        case .data:          return "Data"
        case .guide:         return "Guide"
        }
    }

    var icon: String {
        switch self {
        case .general:       return "gearshape"
        case .appearance:    return "paintpalette"
        case .notifications: return "bell"
        case .license:       return "key"
        case .data:          return "externaldrive"
        case .guide:         return "questionmark.circle"
        }
    }
}

struct SettingsPanelView: View {
    @ObservedObject private var settings = AppSettingsStore.shared
    @State private var selectedSection: SettingsSection? = .general

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(v) (\(b))"
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.title, systemImage: section.icon)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            Group {
                switch selectedSection {
                case .general, .none:
                    GeneralTabView(settings: settings)
                case .appearance:
                    AppearanceTabView(settings: settings)
                case .notifications:
                    NotificationsTabView(settings: settings)
                case .license:
                    LicenseSectionView()
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                case .data:
                    DataTabView(settings: settings)
                case .guide:
                    GuideTabView(appVersion: appVersion)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            settings.refreshFromConfig()
            settings.refreshDiagnostics()
        }
    }
}

private struct GeneralTabView: View {
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Startup") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Start on login", isOn: Binding(
                            get: { settings.startOnLoginEnabled },
                            set: { settings.setStartOnLogin($0) }
                        ))
                        Toggle("Launch in the background", isOn: $settings.launchInBackground)
                        Text("When enabled, LocalPorts stays in the menu bar only on startup.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open Login Items Settings") { settings.openLoginItemsSettings() }
                            .buttonStyle(.bordered).controlSize(.small)
                        if let err = settings.startOnLoginErrorMessage {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Browser") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Open button browser", selection: Binding(
                            get: { settings.selectedBrowserBundleID ?? "" },
                            set: { settings.selectedBrowserBundleID = $0.isEmpty ? nil : $0 }
                        )) {
                            Text("System Default").tag("")
                            ForEach(settings.availableBrowsers) { b in
                                Text(b.name).tag(b.bundleIdentifier)
                            }
                        }
                        .pickerStyle(.menu)
                        Button("Refresh browser list") { settings.refreshAvailableBrowsers() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Onboarding") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(settings.hasCompletedOnboarding
                            ? "First-run onboarding is completed."
                            : "Onboarding will be shown in the services panel.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Show onboarding again") { settings.showOnboardingAgain() }
                            .disabled(!settings.hasCompletedOnboarding)
                        if let msg = settings.onboardingActionMessage {
                            Text(msg).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Accent color picker

private struct AccentColorPickerView: View {
    @ObservedObject var settings: AppSettingsStore

    private let presets: [(label: String, hex: String?)] = [
        ("Default", nil),
        ("Blue",   "#1E90FF"),
        ("Purple", "#9B59B6"),
        ("Pink",   "#E91E7A"),
        ("Orange", "#FF6B35"),
        ("Green",  "#27AE60"),
        ("Yellow", "#F1C40F"),
        ("Teal",   "#1ABC9C"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accent color")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 10) {
                ForEach(presets, id: \.label) { preset in
                    let isSelected = settings.accentColorHex == preset.hex
                    let color: Color = preset.hex == nil ? .accentColor : (Color(hex: preset.hex!) ?? .accentColor)
                    ZStack {
                        Circle()
                            .fill(color)
                            .frame(width: 22, height: 22)
                        if isSelected {
                            Circle()
                                .strokeBorder(.white, lineWidth: 2)
                                .frame(width: 22, height: 22)
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .onTapGesture {
                        settings.accentColorHex = preset.hex
                    }
                    .help(preset.label)
                }
            }
            Text("Applied to buttons and badges in the services panel.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Appearance Tab

private struct AppearanceTabView: View {
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Display") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Show process details in service cards", isOn: $settings.showProcessDetails)
                        Text("Adds process name, PID, and user in the running state line.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        if ProGate.isAllowed(.themes) {
                            AccentColorPickerView(settings: settings)
                        } else {
                            proLockedRow("Accent color · Pro feature")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Accent Color", systemImage: "paintpalette")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        if ProGate.isAllowed(.themes) {
                            BackgroundThemePickerView(settings: settings)
                        } else {
                            proLockedRow("Panel theme · Pro feature")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Panel Theme", systemImage: "rectangle.fill")
                }
            }
            .padding(20)
        }
    }

    private func proLockedRow(_ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Button("Upgrade") {
                NotificationCenter.default.post(name: .localPortsShowUpgradeRequested, object: nil)
            }
            .buttonStyle(.bordered).controlSize(.mini)
        }
    }
}

// MARK: - Background theme picker

private struct BackgroundThemePickerView: View {
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Panel background")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 12) {
                ForEach(PopoverTheme.all, id: \.name) { theme in
                    let currentName = settings.backgroundThemeName ?? "Graphite"
                    let isSelected = currentName.lowercased() == theme.name.lowercased()
                    VStack(spacing: 4) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.gradient)
                                .frame(width: 44, height: 32)
                            if isSelected {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(.white.opacity(0.7), lineWidth: 2)
                                    .frame(width: 44, height: 32)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .onTapGesture {
                            settings.backgroundThemeName = theme.name == "Graphite" ? nil : theme.name
                        }
                        .help(theme.name)
                        Text(theme.name)
                            .font(.caption2)
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                }
            }
            Text("Applied to the services panel background.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Notifications Tab

private struct NotificationsTabView: View {
    @ObservedObject var settings: AppSettingsStore
    @State private var webhookDraft: String = ""
    @State private var webhookSaved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // ── Webhook ──
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        if ProGate.isAllowed(.webhookNotifications) {
                            Text("Receive crash alerts via a POST request to any URL.")
                                .font(.caption).foregroundStyle(.secondary)

                            HStack(spacing: 6) {
                                TextField("https://your-webhook-url", text: $webhookDraft)
                                    .textFieldStyle(.roundedBorder)
                                Button("Save") {
                                    settings.webhookURL = webhookDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : webhookDraft
                                    webhookSaved = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { webhookSaved = false }
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                                if !webhookDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Button(role: .destructive) {
                                        webhookDraft = ""
                                        settings.webhookURL = nil
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            if webhookSaved {
                                Label("Saved", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.green)
                            }

                            HStack(spacing: 6) {
                                Text("Presets:")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(["Discord", "Slack", "Teams"], id: \.self) { preset in
                                    Button(preset) {
                                        let placeholder: String
                                        switch preset {
                                        case "Discord": placeholder = "https://discord.com/api/webhooks/…"
                                        case "Slack":   placeholder = "https://hooks.slack.com/services/…"
                                        default:        placeholder = "https://…webhook…"
                                        }
                                        webhookDraft = placeholder
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)
                                }
                            }

                            Text("Payload: {\"event\":\"service_stopped\",\"service\":\"name\",\"serviceUrl\":\"…\",\"timestamp\":\"…\"}  |  Discord URLs get a rich embed.")
                                .font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                                Text("Webhook notifications · Pro feature")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Upgrade") {
                                    NotificationCenter.default.post(name: .localPortsShowUpgradeRequested, object: nil)
                                }
                                .buttonStyle(.bordered).controlSize(.mini)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Webhook", systemImage: "network.badge.shield.half.filled")
                }
                .onAppear { webhookDraft = settings.webhookURL ?? "" }
                .onChange(of: settings.webhookURL) { webhookDraft = $0 ?? "" }

                // ── Per-service crash notifications ──
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        if ProGate.isAllowed(.advancedNotifications) {
                            if settings.currentProfileServices.isEmpty {
                                Text("No services in the current profile.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Disable crash notifications for specific services:")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(settings.currentProfileServices, id: \.id) { svc in
                                    Toggle(svc.name, isOn: Binding(
                                        get: { settings.disabledCrashNotificationIDs.contains(svc.id) },
                                        set: { disabled in
                                            if disabled {
                                                settings.disabledCrashNotificationIDs.insert(svc.id)
                                            } else {
                                                settings.disabledCrashNotificationIDs.remove(svc.id)
                                            }
                                        }
                                    ))
                                }
                            }
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                                Text("Per-service notifications · Pro feature")
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Upgrade") {
                                    NotificationCenter.default.post(
                                        name: .localPortsShowUpgradeRequested, object: nil
                                    )
                                }
                                .buttonStyle(.bordered).controlSize(.mini)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Crash Notifications", systemImage: "bell")
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Data Tab (Backup + Diagnostics)

private struct DataTabView: View {
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Configuration Backup") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Button("Export") { settings.exportConfiguration() }
                            Button("Import") { settings.importConfiguration() }
                            Button("Show Config File") { settings.openConfigDirectory() }
                        }
                        Text(AppConfigStore.shared.configFilePath())
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).lineLimit(3)
                        if let msg = settings.configActionMessage {
                            Text(msg).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Diagnostics Logs") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Button("Refresh") { settings.refreshDiagnostics() }
                            Button("Open Folder") { settings.openDiagnosticsFolder() }
                            Button("Clear") { settings.clearDiagnostics() }
                        }
                        if settings.diagnosticsFiles.isEmpty {
                            Text("No diagnostics logs found yet.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(settings.diagnosticsFiles) { file in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(file.name).font(.caption.weight(.semibold))
                                        Text("\(file.modifiedText) · \(file.sizeText)")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Open") { settings.openDiagnosticsFile(file) }
                                }
                            }
                        }
                        if let msg = settings.diagnosticsActionMessage {
                            Text(msg).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
    }
}

private struct GuideTabView: View {
    let appVersion: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Quick Guide") {
                    VStack(alignment: .leading, spacing: 8) {
                        row("Left-click the menu bar icon to open your services.")
                        row("Use the play/stop button to start or stop a service.")
                        row("Use the ··· menu for Rename, Edit, Show in Finder, Force Stop.")
                        row("Use the + button to add your own localhost service.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Tips") {
                    VStack(alignment: .leading, spacing: 8) {
                        row("Set a Project Folder + Start Command to let LocalPorts launch services for you.")
                        row("Show in Finder quickly opens the configured project folder.")
                        row("If a service looks stuck, use Refresh to re-check active ports.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()
                LabeledContent("Version", value: appVersion)
                LabeledContent("Mode", value: "Menu Bar")
            }
            .padding(20)
        }
    }

    private func row(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - License Section

private struct LicenseSectionView: View {
    @ObservedObject private var license = LicenseManager.shared
    @State private var showActivation = false

    /// Set this to your LemonSqueezy customer portal URL
    private let manageURL = URL(string: "https://app.lemonsqueezy.com/my-orders")!

    var body: some View {
        GroupBox("License") {
            VStack(alignment: .leading, spacing: 10) {
                if license.isProActive {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("LocalPorts Pro · Active")
                            .font(.subheadline.weight(.semibold))
                    }

                    if let key = license.storedLicenseKey() {
                        Text(maskedKey(key))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    HStack(spacing: 8) {
                        Button("Manage License") {
                            NSWorkspace.shared.open(manageURL)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Deactivate") {
                            license.deactivate()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.circle")
                            .foregroundStyle(.secondary)
                        Text("Free version")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Button("Upgrade to Pro") {
                            NotificationCenter.default.post(name: .localPortsShowUpgradeRequested, object: nil)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .tint(.yellow)
                        .foregroundStyle(.black)

                        Button("Activate License") {
                            showActivation = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showActivation) {
            LicenseActivationSheet()
        }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: key.count) }
        let visible = String(key.suffix(8))
        return String(repeating: "•", count: max(0, key.count - 8)) + visible
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

// MARK: - Popover background theme

struct PopoverTheme {
    let name: String
    let topColor: Color
    let bottomColor: Color

    var gradient: LinearGradient {
        LinearGradient(
            colors: [topColor, bottomColor],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static let graphite = PopoverTheme(
        name: "Graphite",
        topColor: Color(red: 0.12, green: 0.14, blue: 0.20),
        bottomColor: Color(red: 0.08, green: 0.10, blue: 0.16)
    )
    static let midnight = PopoverTheme(
        name: "Midnight",
        topColor: Color(red: 0.04, green: 0.06, blue: 0.16),
        bottomColor: Color(red: 0.02, green: 0.03, blue: 0.10)
    )
    static let ocean = PopoverTheme(
        name: "Ocean",
        topColor: Color(red: 0.06, green: 0.16, blue: 0.28),
        bottomColor: Color(red: 0.03, green: 0.10, blue: 0.20)
    )
    static let forest = PopoverTheme(
        name: "Forest",
        topColor: Color(red: 0.05, green: 0.16, blue: 0.09),
        bottomColor: Color(red: 0.03, green: 0.10, blue: 0.05)
    )
    static let slate = PopoverTheme(
        name: "Slate",
        topColor: Color(red: 0.14, green: 0.18, blue: 0.24),
        bottomColor: Color(red: 0.08, green: 0.12, blue: 0.18)
    )
    static let plum = PopoverTheme(
        name: "Plum",
        topColor: Color(red: 0.20, green: 0.07, blue: 0.24),
        bottomColor: Color(red: 0.12, green: 0.04, blue: 0.16)
    )

    static let all: [PopoverTheme] = [.graphite, .midnight, .ocean, .forest, .slate, .plum]

    static func named(_ name: String?) -> PopoverTheme? {
        guard let name else { return nil }
        return all.first { $0.name.lowercased() == name.lowercased() }
    }
}

// MARK: - Color hex extension

extension Color {
    init?(hex: String) {
        var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") { str = String(str.dropFirst()) }
        guard str.count == 6, let value = UInt64(str, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8)  & 0xFF) / 255.0
        let b = Double(value & 0xFF)         / 255.0
        self.init(red: r, green: g, blue: b)
    }

    var hexString: String? {
        guard let components = NSColor(self).usingColorSpace(.sRGB)?.cgColor.components,
              components.count >= 3 else { return nil }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
