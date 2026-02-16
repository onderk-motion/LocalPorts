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
    @Published private(set) var healthStates: [String: ServiceHealthState] = [:]

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
    private var healthCheckTasks: [String: Task<Void, Never>] = [:]
    private var lastHealthCheckAt: [String: Date] = [:]
    private let healthCheckInterval: TimeInterval = 5.0
    private let healthCheckTimeout: TimeInterval = 1.8

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
        ) { [weak self] _ in
            Task { @MainActor in
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
        ActionsService.shared.openInBrowser(urlString: config.urlString)
    }

    func copyServiceURL(_ id: String) {
        guard let config = serviceConfiguration(for: id) else { return }
        ActionsService.shared.copyURL(urlString: config.urlString)
        statusMessage = "\(config.name) URL copied"
    }

    func serviceEditorData(for id: String) -> ServiceEditorData? {
        guard let config = serviceConfiguration(for: id) else { return nil }

        return ServiceEditorData(
            id: config.id,
            name: displayName(for: id),
            address: config.urlString,
            healthCheckURL: config.healthCheckURLString ?? "",
            workingDirectory: config.workingDirectory ?? "",
            startCommand: config.startCommand?.joined(separator: " ") ?? ""
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
            refreshSoon(after: 1_000_000_000)
        } catch {
            let message = error.localizedDescription
            serviceStates[id] = .failed(message: message)
            statusMessage = message
            logger.error("Start failed for \(config.name, privacy: .public): \(message, privacy: .public)")
        }
    }

    func stopService(_ id: String, force: Bool = false) {
        guard let config = serviceConfiguration(for: id) else { return }
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
        startCommand: String
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
            commandParts = trimmedCommand
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
        }

        let updated = ManagedServiceConfiguration(
            id: current.id,
            name: current.name,
            workingDirectory: trimmedDirectory.isEmpty ? nil : trimmedDirectory,
            port: port,
            urlString: normalizedURL,
            healthCheckURLString: normalizedHealthCheckURL,
            startCommand: commandParts,
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
        startCommand: String
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
            commandParts = trimmedCommand
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
        }

        let config = ManagedServiceConfiguration(
            id: "custom-\(UUID().uuidString.lowercased())",
            name: trimmedName,
            workingDirectory: trimmedDirectory.isEmpty ? nil : trimmedDirectory,
            port: port,
            urlString: normalizedURL,
            healthCheckURLString: normalizedHealthCheckURL,
            startCommand: commandParts,
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

    func statusSummary(for service: ServiceSnapshot) -> String {
        var parts: [String] = [service.url, stateText(for: service.state)]
        if isRunning(service.id) {
            parts.append(healthText(for: service.health))
        }
        return parts.joined(separator: " · ")
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

    private func updateServiceStates(with ports: [ListeningPort]) {
        for config in serviceConfigurations {
            if let pid = ports.first(where: { $0.port == config.port })?.pid {
                serviceStates[config.id] = .running(pid: pid)
                continue
            }

            switch serviceStates[config.id] {
            case .failed:
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
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
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

struct AppConfig: Codable {
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

        for profile in sanitized.profiles {
            var profileID = profile.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if profileID.isEmpty || seenProfileIDs.contains(profileID) {
                profileID = "profile-\(UUID().uuidString.lowercased())"
            }
            seenProfileIDs.insert(profileID)

            var seenServiceIDs: Set<String> = []
            var seenPorts: Set<Int> = []
            var services: [ManagedServiceConfiguration] = []

            for service in profile.serviceConfigurations {
                guard !seenServiceIDs.contains(service.id), !seenPorts.contains(service.port) else {
                    continue
                }
                seenServiceIDs.insert(service.id)
                seenPorts.insert(service.port)
                services.append(service)
            }

            for builtIn in defaultBuiltInServices where !seenServiceIDs.contains(builtIn.id) && !seenPorts.contains(builtIn.port) {
                seenServiceIDs.insert(builtIn.id)
                seenPorts.insert(builtIn.port)
                services.append(builtIn)
            }

            let validIDs = Set(services.map(\.id))
            let customNames = profile.customServiceNames.reduce(into: [String: String]()) { result, item in
                guard validIDs.contains(item.key) else { return }
                result[item.key] = item.value
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
        if !sanitized.profiles.contains(where: { $0.id == sanitized.selectedProfileID }) {
            sanitized.selectedProfileID = sanitized.profiles.first?.id ?? "default"
        }

        return sanitized
    }
}

struct AppProfile: Codable, Identifiable {
    let id: String
    var name: String
    var serviceConfigurations: [ManagedServiceConfiguration]
    var customServiceNames: [String: String]
    var createdAt: String
    var updatedAt: String
}

struct PersistedAppSettings: Codable {
    var launchInBackground: Bool
}

struct AppMigrationMetadata: Codable {
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
            cachedConfig = loaded
            return loaded
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
        let sanitized = AppConfig.sanitizeImported(decoded, defaultBuiltInServices: defaultBuiltInServices)

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
}

struct LegacyMigrationService {
    static let legacyCompatibilityUntilVersion = "1.3.0"

    private let fileManager: FileManager

    private let namesStorageKey = "PinnedServiceNames.v1"
    private let customServicesStorageKey = "CustomServices.v1"
    private let builtInOverridesStorageKey = "BuiltInServiceOverrides.v1"
    private let launchInBackgroundKey = "LaunchInBackground.v1"

    private let oldToNewBuiltInID: [String: String] = [
        "watchlist-web": "local-frontend-5173",
        "watchlist-api": "local-api-5175",
        "dailingo": "local-service-5120"
    ]

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

        var builtInServices = defaultBuiltInServices

        if let raw = defaults.data(forKey: builtInOverridesStorageKey),
           let decoded = try? JSONDecoder().decode([ManagedServiceConfiguration].self, from: raw) {
            let overridesByPort = Dictionary(uniqueKeysWithValues: decoded.map { ($0.port, $0) })
            builtInServices = defaultBuiltInServices.map { base in
                guard let override = overridesByPort[base.port] else {
                    return base
                }
                return ManagedServiceConfiguration(
                    id: base.id,
                    name: override.name,
                    workingDirectory: override.workingDirectory,
                    port: base.port,
                    urlString: override.urlString,
                    healthCheckURLString: override.healthCheckURLString,
                    startCommand: override.startCommand,
                    isBuiltIn: true
                )
            }
        }

        let builtInIDs = Set(builtInServices.map(\.id))
        let builtInPorts = Set(builtInServices.map(\.port))

        var customServices: [ManagedServiceConfiguration] = []
        if let raw = defaults.data(forKey: customServicesStorageKey),
           let decoded = try? JSONDecoder().decode([ManagedServiceConfiguration].self, from: raw) {
            customServices = decoded.compactMap { item in
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
                    isBuiltIn: false
                )
            }
        }

        var customNames: [String: String] = [:]
        if let raw = defaults.dictionary(forKey: namesStorageKey) as? [String: String] {
            for (id, name) in raw {
                let resolvedID = oldToNewBuiltInID[id] ?? id
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
}
