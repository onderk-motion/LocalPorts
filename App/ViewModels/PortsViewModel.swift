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
        let canStart: Bool
        let isBuiltIn: Bool
    }

    struct ServiceEditorData: Identifiable {
        let id: String
        let name: String
        let address: String
        let workingDirectory: String
        let startCommand: String
    }

    @Published private(set) var ports: [ListeningPort] = []
    @Published private(set) var serviceStates: [String: ManagedServiceState] = [:]
    @Published private(set) var statusMessage: String?
    @Published private var customServiceNames: [String: String] = [:]

    var serviceSnapshots: [ServiceSnapshot] {
        serviceConfigurations.map { config in
            ServiceSnapshot(
                id: config.id,
                name: displayName(for: config.id),
                port: config.port,
                url: config.urlString,
                workingDirectory: config.workingDirectory,
                state: serviceStates[config.id] ?? .stopped,
                canStart: config.canStart,
                isBuiltIn: config.isBuiltIn
            )
        }
    }

    var otherPorts: [ListeningPort] {
        let known = Set(serviceConfigurations.map(\.port))
        return ports.filter { !known.contains($0.port) }
    }

    private let logger = Logger(subsystem: "com.localports.app", category: "PortsViewModel")
    private let lsofService: LsofService
    private var refreshTimer: DispatchSourceTimer?
    private var refreshTask: Task<Void, Never>?
    private var didAttemptLaunchAutoStart = false
    private let namesStorageKey = "PinnedServiceNames.v1"
    private let customServicesStorageKey = "CustomServices.v1"
    private let builtInOverridesStorageKey = "BuiltInServiceOverrides.v1"

    private var serviceConfigurations: [ManagedServiceConfiguration]
    private var controllers: [String: ManagedServiceController] = [:]

    enum ServiceValidationError: LocalizedError {
        case nameRequired
        case invalidAddress
        case localhostOnly
        case missingPort
        case duplicatePort(Int)
        case startNeedsDirectory
        case directoryNeedsStartCommand

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
            case .duplicatePort(let port):
                return "Port \(port) is already pinned."
            case .startNeedsDirectory:
                return "Project folder is required when start command is provided."
            case .directoryNeedsStartCommand:
                return "Start command is required when project folder is provided."
            }
        }
    }

    init(lsofService: LsofService = LsofService()) {
        self.lsofService = lsofService

        serviceConfigurations = [
            .localFrontend,
            .localAPI,
            .localService
        ]

        loadBuiltInOverrides()
        loadCustomServices()
        rebuildControllers()

        for config in serviceConfigurations {
            serviceStates[config.id] = .stopped
        }

        loadCustomNames()
        startAutoRefresh()
        refreshNow()
    }

    deinit {
        refreshTimer?.cancel()
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

    func updateService(
        id: String,
        address: String,
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
            startCommand: commandParts,
            isBuiltIn: current.isBuiltIn
        )

        serviceConfigurations[index] = updated
        rebuildControllers()

        if current.isBuiltIn {
            saveBuiltInOverrides()
        } else {
            saveCustomServices()
        }

        statusMessage = "Updated \(displayName(for: id))"
        refreshNow()
    }

    func addCustomService(
        name: String,
        address: String,
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
            startCommand: commandParts,
            isBuiltIn: false
        )

        serviceConfigurations.append(config)
        serviceStates[config.id] = .stopped
        rebuildControllers()
        saveCustomServices()
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
        rebuildControllers()
        saveCustomNames()
        saveCustomServices()
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
        saveCustomNames()
    }

    func resetServiceName(_ id: String) {
        customServiceNames.removeValue(forKey: id)
        saveCustomNames()
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

    private func loadCustomServices() {
        guard let raw = UserDefaults.standard.data(forKey: customServicesStorageKey) else {
            return
        }

        do {
            let decoded = try JSONDecoder().decode([ManagedServiceConfiguration].self, from: raw)
            let builtInIDs = Set(serviceConfigurations.map(\.id))
            let builtInPorts = Set(serviceConfigurations.map(\.port))

            let sanitized = decoded.compactMap { item -> ManagedServiceConfiguration? in
                guard !builtInIDs.contains(item.id), !builtInPorts.contains(item.port) else {
                    return nil
                }

                return ManagedServiceConfiguration(
                    id: item.id,
                    name: item.name,
                    workingDirectory: item.workingDirectory,
                    port: item.port,
                    urlString: item.urlString,
                    startCommand: item.startCommand,
                    isBuiltIn: false
                )
            }

            serviceConfigurations.append(contentsOf: sanitized)
        } catch {
            logger.error("Failed to load custom services: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveCustomServices() {
        do {
            let custom = serviceConfigurations.filter { !$0.isBuiltIn }
            let encoded = try JSONEncoder().encode(custom)
            UserDefaults.standard.set(encoded, forKey: customServicesStorageKey)
        } catch {
            logger.error("Failed to save custom services: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadBuiltInOverrides() {
        guard let raw = UserDefaults.standard.data(forKey: builtInOverridesStorageKey) else {
            return
        }

        do {
            let decoded = try JSONDecoder().decode([ManagedServiceConfiguration].self, from: raw)
            let decodedByID = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })

            serviceConfigurations = serviceConfigurations.map { base in
                guard base.isBuiltIn, let override = decodedByID[base.id] else {
                    return base
                }

                return ManagedServiceConfiguration(
                    id: base.id,
                    name: override.name,
                    workingDirectory: override.workingDirectory,
                    port: override.port,
                    urlString: override.urlString,
                    startCommand: override.startCommand,
                    isBuiltIn: true
                )
            }
        } catch {
            logger.error("Failed to load built-in overrides: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveBuiltInOverrides() {
        do {
            let builtIn = serviceConfigurations.filter(\.isBuiltIn)
            let encoded = try JSONEncoder().encode(builtIn)
            UserDefaults.standard.set(encoded, forKey: builtInOverridesStorageKey)
        } catch {
            logger.error("Failed to save built-in overrides: \(error.localizedDescription, privacy: .public)")
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

    private func loadCustomNames() {
        guard
            let raw = UserDefaults.standard.dictionary(forKey: namesStorageKey) as? [String: String]
        else {
            customServiceNames = [:]
            return
        }

        customServiceNames = raw
    }

    private func saveCustomNames() {
        UserDefaults.standard.set(customServiceNames, forKey: namesStorageKey)
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
