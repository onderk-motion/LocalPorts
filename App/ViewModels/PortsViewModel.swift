import Foundation
import OSLog

@MainActor
final class PortsViewModel: ObservableObject {
    struct ServiceSnapshot: Identifiable {
        let id: String
        let name: String
        let port: Int
        let url: String
        let workingDirectory: String?
        let state: ManagedServiceState
        let health: ServiceHealthState
        let canStart: Bool
        let isBuiltIn: Bool
    }

    struct ServiceEditorData: Identifiable {
        let id: String
        let name: String
        let address: String
        let healthCheckURL: String
        let workingDirectory: String
        let startCommand: String
        let usesGlobalBrowser: Bool
        let browserBundleID: String?
    }

    struct ProfileSummary: Identifiable {
        let id: String
        let name: String
        let serviceCount: Int
    }

    enum ServiceHealthState: Equatable {
        case unavailable
        case checking
        case healthy
        case unhealthy(statusCode: Int?)
        case failed(message: String)
    }

    @Published private(set) var ports: [ListeningPort] = []
    @Published private(set) var serviceStates: [String: ManagedServiceState] = [:]
    @Published private(set) var statusMessage: String?
    @Published private var customServiceNames: [String: String] = [:]
    @Published private(set) var profileSummaries: [ProfileSummary] = []
    @Published private(set) var activeProfileID: String = ""
    @Published private(set) var activeProfileName: String = "Default"
    @Published private(set) var hasCompletedOnboarding: Bool = false
    @Published private(set) var requiresImportedStartApproval: Bool = false
    @Published private(set) var healthStates: [String: ServiceHealthState] = [:]
    @Published private(set) var showProcessDetails: Bool = false
    @Published private(set) var preferredBrowserBundleID: String?

    var serviceSnapshots: [ServiceSnapshot] {
        serviceConfigurations.map { config in
            ServiceSnapshot(
                id: config.id,
                name: displayName(for: config.id),
                port: config.port,
                url: config.urlString,
                workingDirectory: config.workingDirectory,
                state: serviceStates[config.id] ?? .stopped,
                health: healthStates[config.id] ?? .unavailable,
                canStart: config.canStart,
                isBuiltIn: config.isBuiltIn
            )
        }
    }

    var otherPorts: [ListeningPort] {
        let known = Set(serviceConfigurations.map(\.port))
        return ports.filter { !known.contains($0.port) }
    }

    static let defaultBuiltInServices: [ManagedServiceConfiguration] = [
        .localFrontend,
        .localAPI,
        .localService
    ]

    private let logger = Logger(subsystem: "com.localports.app", category: "PortsViewModel")
    private let lsofService: LsofService
    private let configStore: AppConfigStore
    private var configChangeObserver: NSObjectProtocol?
    private var refreshTimer: DispatchSourceTimer?
    private var refreshTask: Task<Void, Never>?
    private var didAttemptLaunchAutoStart = false
    private var startVerificationTasks: [String: Task<Void, Never>] = [:]
    private var healthCheckTasks: [String: Task<Void, Never>] = [:]
    private var lastHealthCheckAt: [String: Date] = [:]
    private let healthCheckInterval: TimeInterval = 5.0
    private let healthCheckTimeout: TimeInterval = 1.8
    private let startVerificationTimeout: TimeInterval = 12.0
    private let startVerificationPollIntervalNanoseconds: UInt64 = 650_000_000

    private var serviceConfigurations: [ManagedServiceConfiguration] = []
    private var controllers: [String: ManagedServiceController] = [:]

    enum ServiceValidationError: LocalizedError {
        case nameRequired
        case invalidAddress
        case localhostOnly
        case missingPort
        case invalidHealthAddress
        case healthLocalhostOnly
        case healthMissingPort
        case duplicatePort(Int)
        case startNeedsDirectory
        case directoryNeedsStartCommand
        case invalidStartCommand
        case profileNameRequired
        case profileDeleteLast

        var errorDescription: String? {
            switch self {
            case .nameRequired:
                return "Service name is required."
            case .invalidAddress:
                return "Address is invalid. Use localhost:PORT or http://localhost:PORT."
            case .localhostOnly:
                return "Only localhost, 127.0.0.1 or ::1 addresses are supported."
            case .missingPort:
                return "Address must include an explicit port."
            case .invalidHealthAddress:
                return "Health check address is invalid. Use localhost:PORT or http://localhost:PORT/health."
            case .healthLocalhostOnly:
                return "Health check address must use localhost, 127.0.0.1 or ::1."
            case .healthMissingPort:
                return "Health check address must include an explicit port."
            case .duplicatePort(let port):
                return "Port \(port) is already pinned."
            case .startNeedsDirectory:
                return "Project folder is required when start command is provided."
            case .directoryNeedsStartCommand:
                return "Start command is required when project folder is provided."
            case .invalidStartCommand:
                return "Start command format is invalid. Check quotes and escapes."
            case .profileNameRequired:
                return "Profile name is required."
            case .profileDeleteLast:
                return "You cannot delete the last profile."
            }
        }
    }

    init(lsofService: LsofService = LsofService()) {
        self.lsofService = lsofService
        self.configStore = .shared

        let config = self.configStore.loadOrCreateConfig(
            defaultBuiltInServices: Self.defaultBuiltInServices,
            legacyCompatibilityUntilVersion: LegacyMigrationService.legacyCompatibilityUntilVersion
        )
        applyActiveProfile(from: config)
        rebuildControllers()

        for config in serviceConfigurations {
            serviceStates[config.id] = .stopped
        }

        startConfigObserver()
        startAutoRefresh()
        refreshNow()
    }

    deinit {
        refreshTimer?.cancel()
        startVerificationTasks.values.forEach { $0.cancel() }
        healthCheckTasks.values.forEach { $0.cancel() }
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func startConfigObserver() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .localPortsConfigDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                self?.handleExternalConfigUpdate()
            }
        }
    }

    private func handleExternalConfigUpdate() {
        let previousProfileID = activeProfileID

        let config = configStore.loadOrCreateConfig(
            defaultBuiltInServices: Self.defaultBuiltInServices,
            legacyCompatibilityUntilVersion: LegacyMigrationService.legacyCompatibilityUntilVersion
        )
        applyActiveProfile(from: config)
        rebuildControllers()

        let validIDs = Set(serviceConfigurations.map(\.id))
        serviceStates = serviceStates.reduce(into: [:]) { result, item in
            guard validIDs.contains(item.key) else { return }
            result[item.key] = item.value
        }
        for serviceID in validIDs where serviceStates[serviceID] == nil {
            serviceStates[serviceID] = .stopped
        }

        if previousProfileID != activeProfileID {
            didAttemptLaunchAutoStart = false
            resetHealthTracking()
        }

        refreshNow()
    }

    func refreshNow() {
        guard refreshTask == nil else {
            return
        }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            let fetched = await lsofService.fetchListeningPorts()
            await MainActor.run {
                self.ports = fetched
                self.updateServiceStates(with: fetched)
                self.tryLaunchAutoStartIfNeeded()
                self.refreshTask = nil
                self.logger.debug("Updated ports list with \(fetched.count) localhost items")
            }
        }
    }

    func dismissStatusMessage() {
        statusMessage = nil
    }

    func completeOnboarding() {
        guard !hasCompletedOnboarding else { return }

        do {
            let updated = try configStore.update { config in
                config.hasCompletedOnboarding = true
            }
            hasCompletedOnboarding = updated.hasCompletedOnboarding
        } catch {
            logger.error("Failed to complete onboarding: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Failed to save onboarding state"
        }
    }

    func resetOnboarding() {
        do {
            let updated = try configStore.update { config in
                config.hasCompletedOnboarding = false
            }
            hasCompletedOnboarding = updated.hasCompletedOnboarding
            statusMessage = "Onboarding guide is enabled again"
        } catch {
            logger.error("Failed to reset onboarding: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Failed to reset onboarding"
        }
    }

    func openService(_ id: String) {
        guard let config = serviceConfiguration(for: id) else { return }
        ActionsService.shared.openInBrowser(
            urlString: config.urlString,
            browserBundleID: resolvedBrowserBundleID(for: config)
        )
    }

    func copyServiceURL(_ id: String) {
        guard let config = serviceConfiguration(for: id) else { return }
        ActionsService.shared.copyURL(urlString: config.urlString)
        statusMessage = "\(config.name) URL copied"
    }

    func availableBrowsers() -> [ActionsService.BrowserOption] {
        ActionsService.shared.availableBrowsers()
    }

    func serviceEditorData(for id: String) -> ServiceEditorData? {
        guard let config = serviceConfiguration(for: id) else { return nil }

        return ServiceEditorData(
            id: config.id,
            name: displayName(for: id),
            address: config.urlString,
            healthCheckURL: config.healthCheckURLString ?? "",
            workingDirectory: config.workingDirectory ?? "",
            startCommand: commandLineString(from: config.startCommand),
            usesGlobalBrowser: config.preferredBrowserBundleID == nil,
            browserBundleID: config.preferredBrowserBundleID
        )
    }

    func showServiceInFinder(_ id: String) {
        guard let config = serviceConfiguration(for: id) else { return }
        guard let workingDirectory = config.workingDirectory, !workingDirectory.isEmpty else {
            statusMessage = "Project folder is not configured for \(config.name)"
            return
        }

        ActionsService.shared.showInFinder(path: workingDirectory)
        statusMessage = "Opened \(config.name) folder"
    }

    func startService(_ id: String) {
        guard let config = serviceConfiguration(for: id) else { return }
        guard let controller = controllers[id] else {
            statusMessage = "Start is not configured for \(config.name)"
            return
        }

        if isRunning(id) {
            statusMessage = "\(config.name) is already running"
            return
        }

        serviceStates[id] = .starting
        statusMessage = nil

        do {
            try controller.start()
            statusMessage = "Starting \(config.name)..."
            beginStartVerification(for: config)
            refreshSoon(after: 1_000_000_000)
        } catch {
            let message = error.localizedDescription
            startVerificationTasks[id]?.cancel()
            startVerificationTasks.removeValue(forKey: id)
            serviceStates[id] = .failed(message: message)
            statusMessage = message
            logger.error("Start failed for \(config.name, privacy: .public): \(message, privacy: .public)")
        }
    }

    func stopService(_ id: String, force: Bool = false) {
        guard let config = serviceConfiguration(for: id) else { return }
        startVerificationTasks[id]?.cancel()
        startVerificationTasks.removeValue(forKey: id)
        guard let pid = pid(forServiceID: id) else {
            statusMessage = "\(config.name) is not running"
            serviceStates[id] = .stopped
            resetHealthState(for: id)
            return
        }

        serviceStates[id] = .stopping

        let success: Bool
        if let controller = controllers[id] {
            success = controller.stop(using: ports, force: force)
        } else {
            success = force ? ActionsService.shared.forceKill(pid: pid) : ActionsService.shared.terminate(pid: pid)
        }

        if success {
            resetHealthState(for: id)
            statusMessage = force ? "Force stopped \(config.name)" : "Stopped \(config.name)"
            refreshSoon(after: 650_000_000)
        } else {
            serviceStates[id] = .failed(message: "Failed to stop \(config.name)")
            statusMessage = "Failed to stop \(config.name)"
        }
    }

    func restartService(_ id: String) {
        guard let config = serviceConfiguration(for: id) else { return }
        guard controllers[id] != nil else {
            statusMessage = "Restart is not configured for \(config.name)"
            return
        }

        if isRunning(id) {
            serviceStates[id] = .stopping
            let stopped = (controllers[id]?.stop(using: ports, force: false) ?? false)
                || (controllers[id]?.stop(using: ports, force: true) ?? false)

            guard stopped else {
                serviceStates[id] = .failed(message: "Could not stop \(config.name)")
                statusMessage = "Could not stop \(config.name)"
                return
            }
        }

        serviceStates[id] = .starting
        statusMessage = "Restarting \(config.name)..."

        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 900_000_000)
            await MainActor.run {
                self.startService(id)
            }
        }
    }

    func refreshAfterAction() {
        refreshSoon(after: 350_000_000)
    }

    func switchProfile(_ profileID: String) {
        guard profileID != activeProfileID else { return }

        do {
            let updated = try configStore.update { config in
                config.selectedProfileID = profileID
            }
            applyActiveProfile(from: updated)
            didAttemptLaunchAutoStart = false
            resetHealthTracking()
            rebuildControllers()
            serviceStates = serviceConfigurations.reduce(into: [:]) { result, config in
                result[config.id] = .stopped
            }
            statusMessage = "Switched profile to \(activeProfileName)"
            refreshNow()
        } catch {
            logger.error("Failed to switch profile: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Failed to switch profile"
        }
    }

    func createProfile(named name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServiceValidationError.profileNameRequired
        }

        let profileID = "profile-\(UUID().uuidString.lowercased())"

        do {
            let updated = try configStore.update { config in
                let now = ISO8601DateFormatter().string(from: Date())
                let profile = AppProfile(
                    id: profileID,
                    name: trimmed,
                    serviceConfigurations: Self.defaultBuiltInServices,
                    customServiceNames: [:],
                    createdAt: now,
                    updatedAt: now
                )
                config.profiles.append(profile)
                config.selectedProfileID = profileID
            }
            applyActiveProfile(from: updated)
            didAttemptLaunchAutoStart = false
            resetHealthTracking()
            rebuildControllers()
            serviceStates = serviceConfigurations.reduce(into: [:]) { result, config in
                result[config.id] = .stopped
            }
            statusMessage = "Created profile \(trimmed)"
            refreshNow()
        } catch {
            logger.error("Failed to create profile: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Failed to create profile"
        }
    }

    func renameActiveProfile(to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServiceValidationError.profileNameRequired
        }

        do {
            let updated = try configStore.update { config in
                guard let index = config.profiles.firstIndex(where: { $0.id == self.activeProfileID }) else { return }
                config.profiles[index].name = trimmed
                config.profiles[index].updatedAt = ISO8601DateFormatter().string(from: Date())
            }
            applyActiveProfile(from: updated)
            statusMessage = "Renamed profile to \(trimmed)"
        } catch {
            logger.error("Failed to rename profile: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Failed to rename profile"
        }
    }

    func deleteActiveProfile() throws {
        let currentID = activeProfileID

        do {
            let updated = try configStore.update { config in
                guard config.profiles.count > 1 else {
                    return
                }

                config.profiles.removeAll { $0.id == currentID }
                if config.selectedProfileID == currentID {
                    config.selectedProfileID = config.profiles.first?.id ?? ""
                }
            }

            guard updated.profiles.count > 0 else {
                throw ServiceValidationError.profileDeleteLast
            }

            if updated.profiles.contains(where: { $0.id == currentID }) {
                throw ServiceValidationError.profileDeleteLast
            }

            applyActiveProfile(from: updated)
            didAttemptLaunchAutoStart = false
            resetHealthTracking()
            rebuildControllers()
            serviceStates = serviceConfigurations.reduce(into: [:]) { result, config in
                result[config.id] = .stopped
            }
            statusMessage = "Deleted profile"
            refreshNow()
        } catch let error as ServiceValidationError {
            throw error
        } catch {
            logger.error("Failed to delete profile: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Failed to delete profile"
        }
    }

    func updateService(
        id: String,
        address: String,
        healthCheckURL: String,
        workingDirectory: String,
        startCommand: String,
        useGlobalBrowser: Bool,
        selectedBrowserBundleID: String?
    ) throws {
        guard let index = serviceConfigurations.firstIndex(where: { $0.id == id }) else { return }
        let current = serviceConfigurations[index]

        guard let normalizedURL = normalizeURLString(from: address) else {
            throw ServiceValidationError.invalidAddress
        }
        guard isLocalhostURLString(normalizedURL) else {
            throw ServiceValidationError.localhostOnly
        }
        guard let parsedURL = URL(string: normalizedURL), let port = parsedURL.port else {
            throw ServiceValidationError.missingPort
        }
        guard !serviceConfigurations.contains(where: { $0.id != id && $0.port == port }) else {
            throw ServiceValidationError.duplicatePort(port)
        }

        let normalizedHealthCheckURL = try normalizeHealthCheckURL(from: healthCheckURL)

        let trimmedDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = startCommand.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedCommand.isEmpty && trimmedDirectory.isEmpty {
            throw ServiceValidationError.startNeedsDirectory
        }
        if !trimmedDirectory.isEmpty && trimmedCommand.isEmpty {
            throw ServiceValidationError.directoryNeedsStartCommand
        }

        let commandParts: [String]?
        if trimmedCommand.isEmpty {
            commandParts = nil
        } else {
            guard let parsed = parseCommandLine(trimmedCommand), !parsed.isEmpty else {
                throw ServiceValidationError.invalidStartCommand
            }
            commandParts = parsed
        }

        let updated = ManagedServiceConfiguration(
            id: current.id,
            name: current.name,
            workingDirectory: trimmedDirectory.isEmpty ? nil : trimmedDirectory,
            port: port,
            urlString: normalizedURL,
            healthCheckURLString: normalizedHealthCheckURL,
            startCommand: commandParts,
            preferredBrowserBundleID: normalizedBrowserBundleID(
                useGlobalBrowser: useGlobalBrowser,
                selectedBrowserBundleID: selectedBrowserBundleID
            ),
            isBuiltIn: current.isBuiltIn
        )

        serviceConfigurations[index] = updated
        rebuildControllers()
        resetHealthState(for: id)
        persistActiveProfile()

        statusMessage = "Updated \(displayName(for: id))"
        refreshNow()
    }

    func addCustomService(
        name: String,
        address: String,
        healthCheckURL: String,
        workingDirectory: String,
        startCommand: String,
        useGlobalBrowser: Bool,
        selectedBrowserBundleID: String?
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw ServiceValidationError.nameRequired
        }

        guard let normalizedURL = normalizeURLString(from: address) else {
            throw ServiceValidationError.invalidAddress
        }

        guard isLocalhostURLString(normalizedURL) else {
            throw ServiceValidationError.localhostOnly
        }

        guard let url = URL(string: normalizedURL), let port = url.port else {
            throw ServiceValidationError.missingPort
        }

        guard !serviceConfigurations.contains(where: { $0.port == port }) else {
            throw ServiceValidationError.duplicatePort(port)
        }

        let normalizedHealthCheckURL = try normalizeHealthCheckURL(from: healthCheckURL)

        let trimmedDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = startCommand.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedCommand.isEmpty && trimmedDirectory.isEmpty {
            throw ServiceValidationError.startNeedsDirectory
        }
        if !trimmedDirectory.isEmpty && trimmedCommand.isEmpty {
            throw ServiceValidationError.directoryNeedsStartCommand
        }

        let commandParts: [String]?
        if trimmedCommand.isEmpty {
            commandParts = nil
        } else {
            guard let parsed = parseCommandLine(trimmedCommand), !parsed.isEmpty else {
                throw ServiceValidationError.invalidStartCommand
            }
            commandParts = parsed
        }

        let config = ManagedServiceConfiguration(
            id: "custom-\(UUID().uuidString.lowercased())",
            name: trimmedName,
            workingDirectory: trimmedDirectory.isEmpty ? nil : trimmedDirectory,
            port: port,
            urlString: normalizedURL,
            healthCheckURLString: normalizedHealthCheckURL,
            startCommand: commandParts,
            preferredBrowserBundleID: normalizedBrowserBundleID(
                useGlobalBrowser: useGlobalBrowser,
                selectedBrowserBundleID: selectedBrowserBundleID
            ),
            isBuiltIn: false
        )

        serviceConfigurations.append(config)
        serviceStates[config.id] = .stopped
        healthStates[config.id] = .unavailable
        rebuildControllers()
        persistActiveProfile()
        statusMessage = "Added \(trimmedName)"
        refreshNow()
    }

    func removeService(_ id: String) {
        guard let index = serviceConfigurations.firstIndex(where: { $0.id == id }) else { return }
        let config = serviceConfigurations[index]
        guard !config.isBuiltIn else { return }

        startVerificationTasks[id]?.cancel()
        startVerificationTasks.removeValue(forKey: id)
        serviceConfigurations.remove(at: index)
        serviceStates.removeValue(forKey: id)
        customServiceNames.removeValue(forKey: id)
        healthStates.removeValue(forKey: id)
        healthCheckTasks[id]?.cancel()
        healthCheckTasks.removeValue(forKey: id)
        lastHealthCheckAt.removeValue(forKey: id)
        rebuildControllers()
        persistActiveProfile()
        statusMessage = "Removed \(config.name)"
    }

    func displayName(for serviceID: String) -> String {
        if let custom = customServiceNames[serviceID]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }

        return serviceConfiguration(for: serviceID)?.name ?? serviceID
    }

    func hasCustomName(_ serviceID: String) -> Bool {
        customServiceNames[serviceID] != nil
    }

    func isStartBlockedByImportApproval(_ serviceID: String) -> Bool {
        false
    }

    func showImportApprovalRequiredMessage() {
        // Import trust flow was removed in v1.0.4.
    }

    func approveImportedStartCommands() {
        requiresImportedStartApproval = false
    }

    func validateStartConfiguration(workingDirectory: String, startCommand: String) throws -> String {
        let trimmedDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = startCommand.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedCommand.isEmpty && trimmedDirectory.isEmpty {
            throw ServiceValidationError.startNeedsDirectory
        }
        if !trimmedDirectory.isEmpty && trimmedCommand.isEmpty {
            throw ServiceValidationError.directoryNeedsStartCommand
        }
        guard !trimmedDirectory.isEmpty, !trimmedCommand.isEmpty else {
            throw ServiceValidationError.directoryNeedsStartCommand
        }
        guard FileManager.default.fileExists(atPath: trimmedDirectory) else {
            throw NSError(
                domain: "PortsViewModel",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Project folder does not exist: \(trimmedDirectory)"]
            )
        }
        guard let commandParts = parseCommandLine(trimmedCommand), !commandParts.isEmpty else {
            throw ServiceValidationError.invalidStartCommand
        }

        let executable = commandParts[0]
        if executable.contains("/") {
            let resolvedPath = executable.hasPrefix("/")
                ? executable
                : URL(fileURLWithPath: trimmedDirectory).appendingPathComponent(executable).path
            guard FileManager.default.fileExists(atPath: resolvedPath) else {
                throw NSError(
                    domain: "PortsViewModel",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Command not found: \(resolvedPath)"]
                )
            }
        } else {
            let localPath = URL(fileURLWithPath: trimmedDirectory).appendingPathComponent(executable).path
            let localExists = FileManager.default.fileExists(atPath: localPath)
            if !localExists {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                process.arguments = [executable]
                process.standardOutput = Pipe()
                process.standardError = Pipe()

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    throw NSError(
                        domain: "PortsViewModel",
                        code: 500,
                        userInfo: [NSLocalizedDescriptionKey: "Could not validate command \(executable)"]
                    )
                }

                if process.terminationStatus != 0 {
                    throw NSError(
                        domain: "PortsViewModel",
                        code: 404,
                        userInfo: [NSLocalizedDescriptionKey: "Command not found in PATH: \(executable)"]
                    )
                }
            }
        }

        return "Command looks valid for \(trimmedDirectory)"
    }

    func renameService(_ id: String, to newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            customServiceNames.removeValue(forKey: id)
        } else {
            customServiceNames[id] = trimmed
        }
        persistActiveProfile()
    }

    func resetServiceName(_ id: String) {
        customServiceNames.removeValue(forKey: id)
        persistActiveProfile()
    }

    func displayTitle(for port: ListeningPort) -> String {
        if let known = serviceConfigurations.first(where: { $0.port == port.port }) {
            return displayName(for: known.id)
        }
        return port.processDisplayName
    }

    func stateText(for state: ManagedServiceState) -> String {
        switch state {
        case .running(let pid):
            return "Running · pid \(pid)"
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .stopping:
            return "Stopping"
        case .failed(let message):
            return "Error · \(message)"
        }
    }

    func statusTooltip(for service: ServiceSnapshot) -> String {
        var lines: [String] = ["Address: \(service.url)"]

        switch service.state {
        case .running(let pid):
            lines.append("State: Running")
            lines.append("PID: \(pid)")

            if let activePort = ports.first(where: { $0.port == service.port }) {
                lines.append("Process: \(activePort.processDisplayName)")
                lines.append("User: \(activePort.user)")
            }

            lines.append("Health: \(healthText(for: service.health))")
        case .stopped:
            lines.append("State: Stopped")
        case .starting:
            lines.append("State: Starting")
        case .stopping:
            lines.append("State: Stopping")
        case .failed(let message):
            lines.append("State: Error")
            lines.append("Reason: \(message)")
        }

        return lines.joined(separator: "\n")
    }

    func healthText(for state: ServiceHealthState) -> String {
        switch state {
        case .unavailable:
            return "No health check"
        case .checking:
            return "Checking"
        case .healthy:
            return "Healthy"
        case .unhealthy(let statusCode):
            if let statusCode {
                return "Unhealthy · HTTP \(statusCode)"
            }
            return "Unhealthy"
        case .failed:
            return "Health check failed"
        }
    }

    func primaryStatusSummary(for service: ServiceSnapshot) -> String {
        var parts: [String] = [shortAddressText(for: service.url, fallbackPort: service.port)]

        switch service.state {
        case .running(let pid):
            parts.append("Running")
            parts.append("pid \(pid)")
            parts.append(healthText(for: service.health))
        case .stopped:
            parts.append("Stopped")
        case .starting:
            parts.append("Starting")
        case .stopping:
            parts.append("Stopping")
        case .failed:
            parts.append("Error")
        }

        return parts.joined(separator: " · ")
    }

    func secondaryStatusSummary(for service: ServiceSnapshot) -> String? {
        guard showProcessDetails else { return nil }
        guard case .running = service.state else { return nil }
        return processDetailsText(for: service)
    }

    func isRunning(_ serviceID: String) -> Bool {
        if case .running = serviceStates[serviceID] {
            return true
        }
        return false
    }

    private func pid(forServiceID id: String) -> Int? {
        guard let config = serviceConfiguration(for: id) else { return nil }
        return ports.first(where: { $0.port == config.port })?.pid
    }

    private func processDetailsText(for service: ServiceSnapshot) -> String? {
        guard let activePort = ports.first(where: { $0.port == service.port }) else {
            return nil
        }
        return "\(activePort.processDisplayName) · user \(activePort.user)"
    }

    private func shortAddressText(for urlString: String, fallbackPort: Int) -> String {
        guard let url = URL(string: urlString) else {
            return "localhost:\(fallbackPort)"
        }

        if let host = url.host(), let port = url.port {
            return "\(host):\(port)"
        }

        return "localhost:\(fallbackPort)"
    }

    private func normalizedBrowserBundleID(useGlobalBrowser: Bool, selectedBrowserBundleID: String?) -> String? {
        guard !useGlobalBrowser else {
            return nil
        }
        guard let selectedBrowserBundleID else {
            return nil
        }

        let trimmed = selectedBrowserBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolvedBrowserBundleID(for config: ManagedServiceConfiguration) -> String? {
        if let preferred = config.preferredBrowserBundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty {
            return preferred
        }

        if let shared = preferredBrowserBundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !shared.isEmpty {
            return shared
        }

        return nil
    }

    private func serviceConfiguration(for id: String) -> ManagedServiceConfiguration? {
        serviceConfigurations.first(where: { $0.id == id })
    }

    private func rebuildControllers() {
        var rebuilt: [String: ManagedServiceController] = [:]
        for config in serviceConfigurations where config.canStart {
            rebuilt[config.id] = ManagedServiceController(configuration: config)
        }
        controllers = rebuilt
    }

    private func normalizeServices(_ services: [ManagedServiceConfiguration]) -> [ManagedServiceConfiguration] {
        var ordered: [ManagedServiceConfiguration] = []
        var seenIDs: Set<String> = []
        var seenPorts: Set<Int> = []

        for service in services {
            guard !seenIDs.contains(service.id), !seenPorts.contains(service.port) else {
                continue
            }
            seenIDs.insert(service.id)
            seenPorts.insert(service.port)
            ordered.append(service)
        }

        for builtIn in Self.defaultBuiltInServices where !seenIDs.contains(builtIn.id) && !seenPorts.contains(builtIn.port) {
            seenIDs.insert(builtIn.id)
            seenPorts.insert(builtIn.port)
            ordered.append(builtIn)
        }

        return ordered
    }

    private func applyActiveProfile(from config: AppConfig) {
        let selectedID = config.selectedProfileID
        let fallbackProfile = config.profiles.first
        let profile = config.profiles.first(where: { $0.id == selectedID }) ?? fallbackProfile

        activeProfileID = profile?.id ?? "default"
        activeProfileName = profile?.name ?? "Default"
        hasCompletedOnboarding = config.hasCompletedOnboarding
        requiresImportedStartApproval = false
        showProcessDetails = config.appSettings.showProcessDetails
        let sharedBrowser = config.appSettings.preferredBrowserBundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
        preferredBrowserBundleID = (sharedBrowser?.isEmpty == true) ? nil : sharedBrowser

        let services = profile?.serviceConfigurations ?? Self.defaultBuiltInServices
        serviceConfigurations = normalizeServices(services)

        let validServiceIDs = Set(serviceConfigurations.map(\.id))
        let names = profile?.customServiceNames ?? [:]
        customServiceNames = names.reduce(into: [:]) { result, item in
            guard validServiceIDs.contains(item.key) else { return }
            result[item.key] = item.value
        }

        healthStates = healthStates.reduce(into: [:]) { result, item in
            guard validServiceIDs.contains(item.key) else { return }
            result[item.key] = item.value
        }
        for serviceID in validServiceIDs where healthStates[serviceID] == nil {
            healthStates[serviceID] = .unavailable
        }

        profileSummaries = config.profiles.map { profile in
            ProfileSummary(id: profile.id, name: profile.name, serviceCount: profile.serviceConfigurations.count)
        }
    }

    private func persistActiveProfile() {
        do {
            let updated = try configStore.update { config in
                let now = ISO8601DateFormatter().string(from: Date())

                if let index = config.profiles.firstIndex(where: { $0.id == self.activeProfileID }) {
                    config.profiles[index].serviceConfigurations = self.serviceConfigurations
                    config.profiles[index].customServiceNames = self.customServiceNames
                    config.profiles[index].updatedAt = now
                } else {
                    let profile = AppProfile(
                        id: self.activeProfileID,
                        name: self.activeProfileName,
                        serviceConfigurations: self.serviceConfigurations,
                        customServiceNames: self.customServiceNames,
                        createdAt: now,
                        updatedAt: now
                    )
                    config.profiles.append(profile)
                }

                config.selectedProfileID = self.activeProfileID
            }

            profileSummaries = updated.profiles.map { profile in
                ProfileSummary(id: profile.id, name: profile.name, serviceCount: profile.serviceConfigurations.count)
            }
        } catch {
            logger.error("Failed to persist profile \(self.activeProfileID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            statusMessage = "Failed to save profile changes"
        }
    }

    private func commandLineString(from parts: [String]?) -> String {
        guard let parts, !parts.isEmpty else { return "" }
        return parts.map(shellEscapeForDisplay).joined(separator: " ")
    }

    private func shellEscapeForDisplay(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        if value.range(of: #"^[A-Za-z0-9_./:-]+$"#, options: .regularExpression) != nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func parseCommandLine(_ input: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var activeQuote: Character?
        var isEscaping = false

        for char in input {
            if isEscaping {
                current.append(char)
                isEscaping = false
                continue
            }

            if let quote = activeQuote {
                if char == quote {
                    activeQuote = nil
                } else if char == "\\" && quote == "\"" {
                    isEscaping = true
                } else {
                    current.append(char)
                }
                continue
            }

            if char == "\\" {
                isEscaping = true
                continue
            }

            if char == "\"" || char == "'" {
                activeQuote = char
                continue
            }

            if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }

            current.append(char)
        }

        if isEscaping || activeQuote != nil {
            return nil
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    private func normalizeURLString(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: candidate), components.scheme != nil, components.host != nil else {
            return nil
        }

        if components.path == "/" {
            components.path = ""
        }

        return components.string
    }

    private func isLocalhostURLString(_ value: String) -> Bool {
        guard let url = URL(string: value), let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func normalizeHealthCheckURL(from input: String) throws -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let normalized = normalizeURLString(from: trimmed) else {
            throw ServiceValidationError.invalidHealthAddress
        }
        guard isLocalhostURLString(normalized) else {
            throw ServiceValidationError.healthLocalhostOnly
        }
        guard let url = URL(string: normalized), url.port != nil else {
            throw ServiceValidationError.healthMissingPort
        }

        return normalized
    }

    private func resetHealthState(for serviceID: String) {
        healthCheckTasks[serviceID]?.cancel()
        healthCheckTasks.removeValue(forKey: serviceID)
        lastHealthCheckAt.removeValue(forKey: serviceID)
        healthStates[serviceID] = .unavailable
    }

    private func resetHealthTracking() {
        healthCheckTasks.values.forEach { $0.cancel() }
        healthCheckTasks.removeAll()
        lastHealthCheckAt.removeAll()
        healthStates = serviceConfigurations.reduce(into: [:]) { result, config in
            result[config.id] = .unavailable
        }
    }

    private func effectiveHealthURL(for config: ManagedServiceConfiguration) -> String {
        config.healthCheckURLString ?? config.urlString
    }

    private func refreshHealthChecks(with ports: [ListeningPort]) {
        let now = Date()

        for config in serviceConfigurations {
            let serviceID = config.id
            let isRunning = ports.contains(where: { $0.port == config.port })

            guard isRunning else {
                resetHealthState(for: serviceID)
                continue
            }

            if healthCheckTasks[serviceID] != nil {
                continue
            }

            if let lastChecked = lastHealthCheckAt[serviceID],
               now.timeIntervalSince(lastChecked) < healthCheckInterval {
                continue
            }

            healthStates[serviceID] = .checking
            lastHealthCheckAt[serviceID] = now

            let healthURL = effectiveHealthURL(for: config)
            healthCheckTasks[serviceID] = Task { [weak self] in
                guard let self else { return }
                let result = await self.performHealthCheck(urlString: healthURL)

                await MainActor.run {
                    defer { self.healthCheckTasks.removeValue(forKey: serviceID) }

                    guard self.isRunning(serviceID) else {
                        self.healthStates[serviceID] = .unavailable
                        return
                    }

                    self.healthStates[serviceID] = result
                }
            }
        }
    }

    private func performHealthCheck(urlString: String) async -> ServiceHealthState {
        guard let url = URL(string: urlString) else {
            return .failed(message: "Invalid URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = healthCheckTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = "GET"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed(message: "Invalid response")
            }

            if (200...399).contains(httpResponse.statusCode) {
                return .healthy
            }

            return .unhealthy(statusCode: httpResponse.statusCode)
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    private func refreshSoon(after delayNanoseconds: UInt64) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            await MainActor.run {
                self?.refreshNow()
            }
        }
    }

    private func beginStartVerification(for config: ManagedServiceConfiguration) {
        let serviceID = config.id
        let serviceName = config.name
        let servicePort = config.port
        let deadline = Date().addingTimeInterval(startVerificationTimeout)

        startVerificationTasks[serviceID]?.cancel()
        startVerificationTasks[serviceID] = Task { [weak self] in
            guard let self else { return }

            while Date() < deadline {
                if Task.isCancelled {
                    break
                }

                self.refreshNow()

                if let pid = self.ports.first(where: { $0.port == servicePort })?.pid {
                    self.serviceStates[serviceID] = .running(pid: pid)
                    self.statusMessage = "Started \(serviceName)"
                    self.startVerificationTasks[serviceID] = nil
                    return
                }

                if case .failed = self.serviceStates[serviceID] {
                    self.startVerificationTasks[serviceID] = nil
                    return
                }

                try? await Task.sleep(nanoseconds: self.startVerificationPollIntervalNanoseconds)
            }

            if self.isRunning(serviceID) {
                self.startVerificationTasks[serviceID] = nil
                return
            }

            self.serviceStates[serviceID] = .failed(message: "Port \(servicePort) did not open in time")
            self.statusMessage = "Start timed out for \(serviceName). Check the start command and diagnostics logs."
            self.startVerificationTasks[serviceID] = nil
        }
    }

    private func updateServiceStates(with ports: [ListeningPort]) {
        for config in serviceConfigurations {
            if let pid = ports.first(where: { $0.port == config.port })?.pid {
                serviceStates[config.id] = .running(pid: pid)
                startVerificationTasks[config.id]?.cancel()
                startVerificationTasks.removeValue(forKey: config.id)
                continue
            }

            switch serviceStates[config.id] {
            case .failed:
                break
            case .starting where startVerificationTasks[config.id] != nil:
                break
            default:
                serviceStates[config.id] = .stopped
            }
        }

        refreshHealthChecks(with: ports)
        clearCompletedStartMessageIfNeeded()
    }

    private func clearCompletedStartMessageIfNeeded() {
        guard let message = statusMessage else { return }
        guard message.hasPrefix("Starting ") || message.hasPrefix("Restarting ") else { return }

        let hasActiveStart = serviceStates.values.contains { state in
            if case .starting = state {
                return true
            }
            return false
        }

        if !hasActiveStart {
            statusMessage = nil
        }
    }

    private func startAutoRefresh() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler {
            Task { @MainActor [weak self] in
                self?.refreshNow()
            }
        }
        timer.resume()
        refreshTimer = timer
    }

    private func tryLaunchAutoStartIfNeeded() {
        guard !didAttemptLaunchAutoStart else { return }
        didAttemptLaunchAutoStart = true

        let serviceIDsToStart = serviceConfigurations.compactMap { config -> String? in
            guard controllers[config.id] != nil else { return nil }
            let alreadyRunning = ports.contains(where: { $0.port == config.port })
            return alreadyRunning ? nil : config.id
        }

        guard !serviceIDsToStart.isEmpty else {
            logger.debug("Launch auto-start skipped: all pinned startable services are already running")
            return
        }

        logger.info("Launch auto-start for \(serviceIDsToStart.count) pinned services")

        Task { @MainActor [weak self] in
            guard let self else { return }

            for (index, serviceID) in serviceIDsToStart.enumerated() {
                self.startService(serviceID)

                if index < serviceIDsToStart.count - 1 {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                }
            }
        }
    }
}

struct AppConfig: Codable, Equatable {
    var schemaVersion: Int
    var selectedProfileID: String
    var profiles: [AppProfile]
    var appSettings: PersistedAppSettings
    var migrationMetadata: AppMigrationMetadata?
    var hasCompletedOnboarding: Bool

    init(
        schemaVersion: Int,
        selectedProfileID: String,
        profiles: [AppProfile],
        appSettings: PersistedAppSettings,
        migrationMetadata: AppMigrationMetadata?,
        hasCompletedOnboarding: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.selectedProfileID = selectedProfileID
        self.profiles = profiles
        self.appSettings = appSettings
        self.migrationMetadata = migrationMetadata
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case selectedProfileID
        case profiles
        case appSettings
        case migrationMetadata
        case hasCompletedOnboarding
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        selectedProfileID = try container.decodeIfPresent(String.self, forKey: .selectedProfileID) ?? "default"
        profiles = try container.decodeIfPresent([AppProfile].self, forKey: .profiles) ?? []
        appSettings = try container.decodeIfPresent(PersistedAppSettings.self, forKey: .appSettings)
            ?? PersistedAppSettings(launchInBackground: true)
        migrationMetadata = try container.decodeIfPresent(AppMigrationMetadata.self, forKey: .migrationMetadata)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
    }

    static let legacyBuiltInIDAliases: [String: String] = [
        "watchlist-web": "local-frontend-5173",
        "watchlist-api": "local-api-5175",
        "dailingo": "local-service-5120"
    ]

    static func makeDefault(defaultBuiltInServices: [ManagedServiceConfiguration]) -> AppConfig {
        let now = ISO8601DateFormatter().string(from: Date())
        let profile = AppProfile(
            id: "default",
            name: "Default",
            serviceConfigurations: defaultBuiltInServices,
            customServiceNames: [:],
            createdAt: now,
            updatedAt: now
        )

        return AppConfig(
            schemaVersion: 1,
            selectedProfileID: profile.id,
            profiles: [profile],
            appSettings: PersistedAppSettings(launchInBackground: true),
            migrationMetadata: nil,
            hasCompletedOnboarding: false
        )
    }

    static func sanitizeImported(
        _ config: AppConfig,
        defaultBuiltInServices: [ManagedServiceConfiguration]
    ) -> AppConfig {
        var sanitized = config
        sanitized.schemaVersion = max(1, sanitized.schemaVersion)

        let now = ISO8601DateFormatter().string(from: Date())
        if sanitized.profiles.isEmpty {
            let fallback = AppConfig.makeDefault(defaultBuiltInServices: defaultBuiltInServices)
            sanitized.profiles = fallback.profiles
            sanitized.selectedProfileID = fallback.selectedProfileID
            return sanitized
        }

        var seenProfileIDs: Set<String> = []
        var rebuiltProfiles: [AppProfile] = []
        let builtInsByID = Dictionary(uniqueKeysWithValues: defaultBuiltInServices.map { ($0.id, $0) })
        let builtInsByPort = Dictionary(uniqueKeysWithValues: defaultBuiltInServices.map { ($0.port, $0) })

        for profile in sanitized.profiles {
            var profileID = profile.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if profileID.isEmpty || seenProfileIDs.contains(profileID) {
                profileID = "profile-\(UUID().uuidString.lowercased())"
            }
            seenProfileIDs.insert(profileID)

            var builtInOverrides: [String: ManagedServiceConfiguration] = [:]
            var customCandidates: [ManagedServiceConfiguration] = []

            for rawService in profile.serviceConfigurations {
                let normalized = normalizedService(rawService)
                if let resolvedBuiltInID = resolvedBuiltInID(
                    rawID: normalized.id,
                    port: normalized.port,
                    builtInsByID: builtInsByID,
                    builtInsByPort: builtInsByPort
                ), let base = builtInsByID[resolvedBuiltInID] {
                    let candidate = mergedBuiltIn(base: base, overrideValue: normalized)
                    if let existing = builtInOverrides[resolvedBuiltInID] {
                        builtInOverrides[resolvedBuiltInID] = preferredBuiltInOverride(existing: existing, candidate: candidate)
                    } else {
                        builtInOverrides[resolvedBuiltInID] = candidate
                    }
                    continue
                }

                customCandidates.append(
                    ManagedServiceConfiguration(
                        id: normalized.id,
                        name: normalized.name,
                        workingDirectory: normalized.workingDirectory,
                        port: normalized.port,
                        urlString: normalized.urlString,
                        healthCheckURLString: normalized.healthCheckURLString,
                        startCommand: normalized.startCommand,
                        preferredBrowserBundleID: normalized.preferredBrowserBundleID,
                        isBuiltIn: false
                    )
                )
            }

            var seenServiceIDs: Set<String> = []
            var seenPorts: Set<Int> = []
            var services: [ManagedServiceConfiguration] = []

            for builtIn in defaultBuiltInServices {
                let service = builtInOverrides[builtIn.id] ?? builtIn
                guard !seenServiceIDs.contains(service.id), !seenPorts.contains(service.port) else {
                    continue
                }
                seenServiceIDs.insert(service.id)
                seenPorts.insert(service.port)
                services.append(service)
            }

            for rawCustom in customCandidates {
                var customID = rawCustom.id.trimmingCharacters(in: .whitespacesAndNewlines)
                if customID.isEmpty || seenServiceIDs.contains(customID) || builtInsByID[customID] != nil || legacyBuiltInIDAliases[customID] != nil {
                    customID = "custom-\(UUID().uuidString.lowercased())"
                }
                guard !seenServiceIDs.contains(customID), !seenPorts.contains(rawCustom.port) else {
                    continue
                }

                let custom = ManagedServiceConfiguration(
                    id: customID,
                    name: rawCustom.name,
                    workingDirectory: trimToNil(rawCustom.workingDirectory),
                    port: rawCustom.port,
                    urlString: rawCustom.urlString,
                    healthCheckURLString: trimToNil(rawCustom.healthCheckURLString),
                    startCommand: normalizeCommand(rawCustom.startCommand),
                    preferredBrowserBundleID: trimToNil(rawCustom.preferredBrowserBundleID),
                    isBuiltIn: false
                )

                seenServiceIDs.insert(custom.id)
                seenPorts.insert(custom.port)
                services.append(custom)
            }

            let validIDs = Set(services.map(\.id))
            let customNames = profile.customServiceNames.reduce(into: [String: String]()) { result, item in
                let trimmedName = item.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty else { return }

                let rawKey = item.key.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedKey = legacyBuiltInIDAliases[rawKey] ?? rawKey
                if validIDs.contains(resolvedKey) {
                    result[resolvedKey] = trimmedName
                    return
                }

                if let port = Int(rawKey), let serviceID = services.first(where: { $0.port == port })?.id {
                    result[serviceID] = trimmedName
                }
            }

            rebuiltProfiles.append(
                AppProfile(
                    id: profileID,
                    name: profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Profile"
                        : profile.name,
                    serviceConfigurations: services,
                    customServiceNames: customNames,
                    createdAt: profile.createdAt.isEmpty ? now : profile.createdAt,
                    updatedAt: now
                )
            )
        }

        sanitized.profiles = rebuiltProfiles
        sanitized.appSettings.preferredBrowserBundleID = trimToNil(sanitized.appSettings.preferredBrowserBundleID)
        if !sanitized.profiles.contains(where: { $0.id == sanitized.selectedProfileID }) {
            sanitized.selectedProfileID = sanitized.profiles.first?.id ?? "default"
        }

        return sanitized
    }

    private static func resolvedBuiltInID(
        rawID: String,
        port: Int,
        builtInsByID: [String: ManagedServiceConfiguration],
        builtInsByPort: [Int: ManagedServiceConfiguration]
    ) -> String? {
        if let mapped = legacyBuiltInIDAliases[rawID], builtInsByID[mapped] != nil {
            return mapped
        }
        if builtInsByID[rawID] != nil {
            return rawID
        }
        if let byPort = builtInsByPort[port] {
            return byPort.id
        }
        return nil
    }

    private static func mergedBuiltIn(
        base: ManagedServiceConfiguration,
        overrideValue: ManagedServiceConfiguration
    ) -> ManagedServiceConfiguration {
        ManagedServiceConfiguration(
            id: base.id,
            name: overrideValue.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? base.name : overrideValue.name,
            workingDirectory: trimToNil(overrideValue.workingDirectory),
            port: base.port,
            urlString: overrideValue.urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? base.urlString : overrideValue.urlString,
            healthCheckURLString: trimToNil(overrideValue.healthCheckURLString),
            startCommand: normalizeCommand(overrideValue.startCommand),
            preferredBrowserBundleID: trimToNil(overrideValue.preferredBrowserBundleID),
            isBuiltIn: true
        )
    }

    private static func preferredBuiltInOverride(
        existing: ManagedServiceConfiguration,
        candidate: ManagedServiceConfiguration
    ) -> ManagedServiceConfiguration {
        if builtInOverrideScore(candidate) > builtInOverrideScore(existing) {
            return candidate
        }
        return existing
    }

    private static func builtInOverrideScore(_ service: ManagedServiceConfiguration) -> Int {
        var score = 0
        if trimToNil(service.workingDirectory) != nil {
            score += 2
        }
        if !(normalizeCommand(service.startCommand)?.isEmpty ?? true) {
            score += 2
        }
        if trimToNil(service.healthCheckURLString) != nil {
            score += 1
        }
        if !service.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 1
        }
        return score
    }

    private static func normalizedService(_ service: ManagedServiceConfiguration) -> ManagedServiceConfiguration {
        let normalizedID = service.id.trimmingCharacters(in: .whitespacesAndNewlines)
        return ManagedServiceConfiguration(
            id: normalizedID,
            name: service.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Service \(service.port)"
                : service.name,
            workingDirectory: trimToNil(service.workingDirectory),
            port: service.port,
            urlString: service.urlString.trimmingCharacters(in: .whitespacesAndNewlines),
            healthCheckURLString: trimToNil(service.healthCheckURLString),
            startCommand: normalizeCommand(service.startCommand),
            preferredBrowserBundleID: trimToNil(service.preferredBrowserBundleID),
            isBuiltIn: service.isBuiltIn
        )
    }

    private static func trimToNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizeCommand(_ value: [String]?) -> [String]? {
        guard let value else { return nil }
        let normalized = value
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return normalized.isEmpty ? nil : normalized
    }
}

struct AppProfile: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var serviceConfigurations: [ManagedServiceConfiguration]
    var customServiceNames: [String: String]
    var createdAt: String
    var updatedAt: String
}

struct PersistedAppSettings: Codable, Equatable {
    var launchInBackground: Bool
    var requiresImportedStartApproval: Bool
    var showProcessDetails: Bool
    var preferredBrowserBundleID: String?

    init(
        launchInBackground: Bool,
        requiresImportedStartApproval: Bool = false,
        showProcessDetails: Bool = false,
        preferredBrowserBundleID: String? = nil
    ) {
        self.launchInBackground = launchInBackground
        self.requiresImportedStartApproval = requiresImportedStartApproval
        self.showProcessDetails = showProcessDetails
        self.preferredBrowserBundleID = preferredBrowserBundleID
    }

    enum CodingKeys: String, CodingKey {
        case launchInBackground
        case requiresImportedStartApproval
        case showProcessDetails
        case preferredBrowserBundleID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchInBackground = try container.decodeIfPresent(Bool.self, forKey: .launchInBackground) ?? true
        requiresImportedStartApproval = try container.decodeIfPresent(Bool.self, forKey: .requiresImportedStartApproval) ?? false
        showProcessDetails = try container.decodeIfPresent(Bool.self, forKey: .showProcessDetails) ?? false
        preferredBrowserBundleID = try container.decodeIfPresent(String.self, forKey: .preferredBrowserBundleID)
    }
}

struct AppMigrationMetadata: Codable, Equatable {
    var migratedFromLegacyUserDefaultsAt: String
    var legacyCompatibilityUntilVersion: String
}

@MainActor
final class AppConfigStore {
    static let shared = AppConfigStore()

    private let logger = Logger(subsystem: "com.localports.app", category: "AppConfigStore")
    private let fileManager: FileManager
    private var cachedConfig: AppConfig?

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func loadOrCreateConfig(
        defaultBuiltInServices: [ManagedServiceConfiguration],
        legacyCompatibilityUntilVersion: String
    ) -> AppConfig {
        if let cachedConfig {
            return cachedConfig
        }

        if let loaded = loadFromDisk() {
            var sanitized = AppConfig.sanitizeImported(loaded, defaultBuiltInServices: defaultBuiltInServices)
            if sanitized.appSettings.requiresImportedStartApproval {
                sanitized.appSettings.requiresImportedStartApproval = false
            }
            if sanitized != loaded {
                do {
                    try saveToDisk(sanitized)
                } catch {
                    logger.error("Failed to persist sanitized config: \(error.localizedDescription, privacy: .public)")
                }
            }
            cachedConfig = sanitized
            return sanitized
        }

        let migration = LegacyMigrationService(fileManager: fileManager)
        if let migrated = migration.migrateFromUserDefaults(
            defaultBuiltInServices: defaultBuiltInServices,
            legacyCompatibilityUntilVersion: legacyCompatibilityUntilVersion
        ) {
            do {
                try saveToDisk(migrated)
            } catch {
                logger.error("Failed to save migrated config: \(error.localizedDescription, privacy: .public)")
            }
            cachedConfig = migrated
            return migrated
        }

        let fresh = AppConfig.makeDefault(defaultBuiltInServices: defaultBuiltInServices)
        do {
            try saveToDisk(fresh)
        } catch {
            logger.error("Failed to save default config: \(error.localizedDescription, privacy: .public)")
        }
        cachedConfig = fresh
        return fresh
    }

    func update(_ mutator: (inout AppConfig) -> Void) throws -> AppConfig {
        guard var config = cachedConfig else {
            throw NSError(
                domain: "AppConfigStore",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Config is not loaded yet"]
            )
        }

        mutator(&config)
        try saveToDisk(config)
        cachedConfig = config
        postConfigDidChange()
        return config
    }

    func currentConfigSnapshot() -> AppConfig? {
        if let cachedConfig {
            return cachedConfig
        }

        if let loaded = loadFromDisk() {
            cachedConfig = loaded
            return loaded
        }

        return nil
    }

    func configFilePath() -> String {
        configFileURL().path
    }

    func backupFilePath() -> String {
        backupFileURL().path
    }

    func exportConfig(to destinationURL: URL) throws {
        guard let config = currentConfigSnapshot() else {
            throw NSError(
                domain: "AppConfigStore",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No configuration is available to export"]
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: destinationURL, options: .atomic)
    }

    func importConfig(
        from sourceURL: URL,
        defaultBuiltInServices: [ManagedServiceConfiguration]
    ) throws -> AppConfig {
        let data = try Data(contentsOf: sourceURL)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        var sanitized = AppConfig.sanitizeImported(decoded, defaultBuiltInServices: defaultBuiltInServices)
        sanitized.appSettings.requiresImportedStartApproval = false

        try saveToDisk(sanitized)
        cachedConfig = sanitized
        postConfigDidChange()
        return sanitized
    }

    private func postConfigDidChange() {
        NotificationCenter.default.post(name: .localPortsConfigDidChange, object: nil)
    }

    private func loadFromDisk() -> AppConfig? {
        let configURL = configFileURL()
        guard fileManager.fileExists(atPath: configURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: configURL)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            logger.error("Failed to load config from disk: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func saveToDisk(_ config: AppConfig) throws {
        let configURL = configFileURL()
        let backupURL = backupFileURL()

        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: configURL.path) {
            if fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: configURL, to: backupURL)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: .atomic)
    }

    private func configFileURL() -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.localports.app", isDirectory: true)
            .appendingPathComponent("config.v1.json", isDirectory: false)
    }

    private func backupFileURL() -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.localports.app", isDirectory: true)
            .appendingPathComponent("config.v1.json.bak", isDirectory: false)
    }
}

extension Notification.Name {
    static let localPortsConfigDidChange = Notification.Name("localPortsConfigDidChange")
    static let localPortsOpenSettingsRequested = Notification.Name("localPortsOpenSettingsRequested")
}

struct LegacyMigrationService {
    static let legacyCompatibilityUntilVersion = "1.3.0"

    private let fileManager: FileManager

    private let namesStorageKey = "PinnedServiceNames.v1"
    private let customServicesStorageKey = "CustomServices.v1"
    private let builtInOverridesStorageKey = "BuiltInServiceOverrides.v1"
    private let launchInBackgroundKey = "LaunchInBackground.v1"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func migrateFromUserDefaults(
        defaultBuiltInServices: [ManagedServiceConfiguration],
        legacyCompatibilityUntilVersion: String
    ) -> AppConfig? {
        let defaults = UserDefaults.standard
        let hasLegacyData =
            defaults.object(forKey: namesStorageKey) != nil
            || defaults.object(forKey: customServicesStorageKey) != nil
            || defaults.object(forKey: builtInOverridesStorageKey) != nil
            || defaults.object(forKey: launchInBackgroundKey) != nil

        guard hasLegacyData else {
            return nil
        }

        var builtInServicesByID = Dictionary(uniqueKeysWithValues: defaultBuiltInServices.map { ($0.id, $0) })

        if let raw = defaults.data(forKey: builtInOverridesStorageKey),
           let decodedOverrides = Self.decodeLegacyServiceList(from: raw) {
            for override in decodedOverrides {
                guard let targetID = resolveBuiltInID(from: override, builtInServicesByID: builtInServicesByID),
                      let base = builtInServicesByID[targetID] else {
                    continue
                }

                builtInServicesByID[targetID] = ManagedServiceConfiguration(
                    id: base.id,
                    name: override.name,
                    workingDirectory: override.workingDirectory,
                    port: base.port,
                    urlString: override.urlString,
                    healthCheckURLString: override.healthCheckURLString,
                    startCommand: override.startCommand,
                    preferredBrowserBundleID: override.preferredBrowserBundleID,
                    isBuiltIn: true
                )
            }
        }

        var customServices: [ManagedServiceConfiguration] = []
        if let raw = defaults.data(forKey: customServicesStorageKey),
           let decoded = Self.decodeLegacyServiceList(from: raw) {
            for item in decoded {
                if let targetID = resolveBuiltInID(from: item, builtInServicesByID: builtInServicesByID),
                   let base = builtInServicesByID[targetID] {
                    builtInServicesByID[targetID] = ManagedServiceConfiguration(
                        id: base.id,
                        name: item.name,
                        workingDirectory: item.workingDirectory,
                        port: base.port,
                        urlString: item.urlString,
                        healthCheckURLString: item.healthCheckURLString,
                        startCommand: item.startCommand,
                        preferredBrowserBundleID: item.preferredBrowserBundleID,
                        isBuiltIn: true
                    )
                    continue
                }

                customServices.append(
                    ManagedServiceConfiguration(
                        id: item.id,
                        name: item.name,
                        workingDirectory: item.workingDirectory,
                        port: item.port,
                        urlString: item.urlString,
                        healthCheckURLString: item.healthCheckURLString,
                        startCommand: item.startCommand,
                        preferredBrowserBundleID: item.preferredBrowserBundleID,
                        isBuiltIn: false
                    )
                )
            }
        }

        let builtInServices = defaultBuiltInServices.map { builtIn in
            builtInServicesByID[builtIn.id] ?? builtIn
        }
        let builtInIDs = Set(builtInServices.map(\.id))
        let builtInPorts = Set(builtInServices.map(\.port))
        customServices = customServices.compactMap { item in
            guard !builtInIDs.contains(item.id), !builtInPorts.contains(item.port) else {
                return nil
            }
            return ManagedServiceConfiguration(
                id: item.id,
                name: item.name,
                workingDirectory: item.workingDirectory,
                port: item.port,
                urlString: item.urlString,
                healthCheckURLString: item.healthCheckURLString,
                startCommand: item.startCommand,
                preferredBrowserBundleID: item.preferredBrowserBundleID,
                isBuiltIn: false
            )
        }

        var dedupedCustomServices: [ManagedServiceConfiguration] = []
        var seenCustomIDs: Set<String> = []
        var seenCustomPorts = builtInPorts
        for service in customServices {
            guard !seenCustomIDs.contains(service.id), !seenCustomPorts.contains(service.port) else {
                continue
            }
            seenCustomIDs.insert(service.id)
            seenCustomPorts.insert(service.port)
            dedupedCustomServices.append(service)
        }
        customServices = dedupedCustomServices

        var customNames: [String: String] = [:]
        if let raw = defaults.dictionary(forKey: namesStorageKey) as? [String: String] {
            for (id, name) in raw {
                let resolvedID = AppConfig.legacyBuiltInIDAliases[id] ?? id
                customNames[resolvedID] = name
            }
        }

        let launchInBackground: Bool
        if defaults.object(forKey: launchInBackgroundKey) != nil {
            launchInBackground = defaults.bool(forKey: launchInBackgroundKey)
        } else {
            launchInBackground = true
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let profile = AppProfile(
            id: "default",
            name: "Default",
            serviceConfigurations: builtInServices + customServices,
            customServiceNames: customNames,
            createdAt: now,
            updatedAt: now
        )

        return AppConfig(
            schemaVersion: 1,
            selectedProfileID: profile.id,
            profiles: [profile],
            appSettings: PersistedAppSettings(launchInBackground: launchInBackground),
            migrationMetadata: AppMigrationMetadata(
                migratedFromLegacyUserDefaultsAt: now,
                legacyCompatibilityUntilVersion: legacyCompatibilityUntilVersion
            ),
            hasCompletedOnboarding: true
        )
    }

    private func resolveBuiltInID(
        from service: ManagedServiceConfiguration,
        builtInServicesByID: [String: ManagedServiceConfiguration]
    ) -> String? {
        let mappedID = AppConfig.legacyBuiltInIDAliases[service.id] ?? service.id
        if builtInServicesByID[mappedID] != nil {
            return mappedID
        }
        if let matchByPort = builtInServicesByID.values.first(where: { $0.port == service.port }) {
            return matchByPort.id
        }
        return nil
    }

    private static func decodeLegacyServiceList(from raw: Data) -> [ManagedServiceConfiguration]? {
        if let list = try? JSONDecoder().decode([ManagedServiceConfiguration].self, from: raw) {
            return list
        }
        if let dictionary = try? JSONDecoder().decode([String: ManagedServiceConfiguration].self, from: raw) {
            return Array(dictionary.values)
        }
        return nil
    }
}
