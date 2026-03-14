import Darwin
import Foundation
import OSLog

enum ManagedCommandShell {
    static func preferredShellPath() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !shell.isEmpty {
            return shell
        }

        guard let pw = getpwuid(getuid()), let shellPointer = pw.pointee.pw_shell else {
            return "/bin/zsh"
        }

        let shell = String(cString: shellPointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return shell.isEmpty ? "/bin/zsh" : shell
    }
}

struct ManagedServiceConfiguration: Sendable, Codable, Hashable {
    let id: String
    let name: String
    let workingDirectory: String?
    let port: Int
    let urlString: String
    let healthCheckURLString: String?
    let startCommand: [String]?
    let preferredBrowserBundleID: String?
    let isBuiltIn: Bool
    /// Optional group label, e.g. "Frontend", "Backend", "Database". nil = uncategorized.
    let category: String?

    init(
        id: String,
        name: String,
        workingDirectory: String?,
        port: Int,
        urlString: String,
        healthCheckURLString: String?,
        startCommand: [String]?,
        preferredBrowserBundleID: String?,
        isBuiltIn: Bool,
        category: String? = nil
    ) {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
        self.port = port
        self.urlString = urlString
        self.healthCheckURLString = healthCheckURLString
        self.startCommand = startCommand
        self.preferredBrowserBundleID = preferredBrowserBundleID
        self.isBuiltIn = isBuiltIn
        self.category = category
    }

    var canStart: Bool {
        workingDirectory != nil && !(startCommand?.isEmpty ?? true)
    }

    static let localFrontend = ManagedServiceConfiguration(
        id: "local-frontend-5173",
        name: "Local Frontend",
        workingDirectory: nil,
        port: 5173,
        urlString: "http://localhost:5173",
        healthCheckURLString: nil,
        startCommand: nil,
        preferredBrowserBundleID: nil,
        isBuiltIn: true
    )

    static let localAPI = ManagedServiceConfiguration(
        id: "local-api-5175",
        name: "Local API",
        workingDirectory: nil,
        port: 5175,
        urlString: "http://localhost:5175",
        healthCheckURLString: nil,
        startCommand: nil,
        preferredBrowserBundleID: nil,
        isBuiltIn: true
    )

    static let localService = ManagedServiceConfiguration(
        id: "local-service-5120",
        name: "Local Service",
        workingDirectory: nil,
        port: 5120,
        urlString: "http://localhost:5120",
        healthCheckURLString: nil,
        startCommand: nil,
        preferredBrowserBundleID: nil,
        isBuiltIn: true
    )
}

enum ManagedServiceState: Equatable {
    case running(pid: Int)
    case stopped
    case starting
    case stopping
    case failed(message: String)
}

final class ManagedServiceController {
    private struct RunningContext {
        let process: Process
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
    }

    private let logger = Logger(subsystem: "com.localports.app", category: "ManagedServiceController")
    private let configuration: ManagedServiceConfiguration
    private let inheritShellEnvironment: Bool
    private var runningContext: RunningContext?

    /// Called on background thread for each captured log line. Prefix "[err] " = stderr.
    var onLogLine: ((String) -> Void)?

    init(configuration: ManagedServiceConfiguration, inheritShellEnvironment: Bool = false) {
        self.configuration = configuration
        self.inheritShellEnvironment = inheritShellEnvironment
    }

    func findRunningPID(in ports: [ListeningPort]) -> Int? {
        ports.first(where: { $0.port == configuration.port })?.pid
    }

    func start() throws {
        guard configuration.canStart else {
            throw NSError(
                domain: "ManagedServiceController",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: "Start is not configured for \(configuration.name)"]
            )
        }

        if let runningContext, runningContext.process.isRunning {
            logger.debug("Managed process already running from this app")
            return
        }

        guard let workingDirectory = configuration.workingDirectory else {
            throw NSError(
                domain: "ManagedServiceController",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Working directory missing for \(configuration.name)"]
            )
        }

        guard FileManager.default.fileExists(atPath: workingDirectory) else {
            throw NSError(
                domain: "ManagedServiceController",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Project folder not found: \(workingDirectory)"]
            )
        }

        let command = shellCommandString()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath())
        process.arguments = shellArguments(for: command)
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let context = RunningContext(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

        process.terminationHandler = { [weak self] terminatedProcess in
            guard let self else { return }
            if self.runningContext?.process === terminatedProcess {
                self.runningContext = nil
            }
            self.logger.info("Managed service \(self.configuration.name, privacy: .public) exited with status \(terminatedProcess.terminationStatus)")
        }

        try process.run()
        runningContext = context

        Thread.sleep(forTimeInterval: 0.35)

        if !process.isRunning {
            let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            emitBufferedLogs(stdout: stdout, stderr: stderr)
            let terminationStatus = process.terminationStatus
            let diagnosticsPath = appendStartDiagnostics(
                phase: terminationStatus == 0 ? "start-detached" : "start-failed",
                workingDirectory: workingDirectory,
                command: command,
                terminationStatus: Int(terminationStatus),
                stdout: stdout,
                stderr: stderr
            )

            if terminationStatus == 0 {
                logger.info("Managed service \(self.configuration.name, privacy: .public) start command exited successfully (detached/background launch)")
                return
            }

            var message = [stderr, stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? "Failed to start \(configuration.name) (exit \(terminationStatus))"
            if let diagnosticsPath {
                message += " · Log: \(diagnosticsPath)"
            }

            throw NSError(
                domain: "ManagedServiceController",
                code: Int(terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        logger.info("Started managed service \(self.configuration.name, privacy: .public)")
        attachLogStreaming()
    }

    private func attachLogStreaming() {
        guard let context = runningContext, onLogLine != nil else { return }

        func streamPipe(_ pipe: Pipe, prefix: String) {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                guard let text = String(data: data, encoding: .utf8) else { return }
                let lines = text.components(separatedBy: "\n")
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    self?.onLogLine?(prefix + trimmed)
                }
            }
        }

        streamPipe(context.stdoutPipe, prefix: "")
        streamPipe(context.stderrPipe, prefix: "[err] ")
    }

    private func emitBufferedLogs(stdout: String, stderr: String) {
        guard let onLogLine else { return }

        func emit(_ text: String, prefix: String) {
            let lines = text.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                onLogLine(prefix + trimmed)
            }
        }

        emit(stderr, prefix: "[err] ")
        emit(stdout, prefix: "")
    }

    @discardableResult
    func stop(using ports: [ListeningPort], force: Bool = false) -> Bool {
        guard let pid = findRunningPID(in: ports) else {
            logger.debug("No PID found for managed service port \(self.configuration.port)")
            return false
        }

        if force {
            return ActionsService.shared.forceKill(pid: pid)
        }

        return ActionsService.shared.terminate(pid: pid)
    }

    var serviceName: String {
        configuration.name
    }

    var serviceURL: String {
        configuration.urlString
    }

    var servicePort: Int {
        configuration.port
    }

    var serviceID: String {
        configuration.id
    }

    private func shellCommandString() -> String {
        let commandParts = resolvedCommandParts()
        let escaped = commandParts.map(shellEscape).joined(separator: " ")
        return "export PATH=/usr/local/bin:/opt/homebrew/bin:$PATH:$PWD; \(escaped)"
    }

    private func shellPath() -> String {
        inheritShellEnvironment ? ManagedCommandShell.preferredShellPath() : "/bin/zsh"
    }

    private func shellArguments(for command: String) -> [String] {
        inheritShellEnvironment ? ["-ilc", command] : ["-lc", command]
    }

    private func resolvedCommandParts() -> [String] {
        guard var commandParts = configuration.startCommand, !commandParts.isEmpty else {
            return []
        }

        guard let workingDirectory = configuration.workingDirectory else {
            return commandParts
        }

        let first = commandParts[0]
        guard !first.contains("/") else {
            return commandParts
        }

        let candidate = URL(fileURLWithPath: workingDirectory).appendingPathComponent(first).path
        if FileManager.default.fileExists(atPath: candidate) {
            commandParts[0] = "./\(first)"
        }

        return commandParts
    }

    private func shellEscape(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }

        if value.range(of: #"^[A-Za-z0-9_./:-]+$"#, options: .regularExpression) != nil {
            return value
        }

        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appendStartDiagnostics(
        phase: String,
        workingDirectory: String,
        command: String,
        terminationStatus: Int,
        stdout: String,
        stderr: String
    ) -> String? {
        let fileManager = FileManager.default
        let diagnosticsDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/LocalPorts", isDirectory: true)

        do {
            try fileManager.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
            let diagnosticsFile = diagnosticsDirectory
                .appendingPathComponent("\(configuration.id).log", isDirectory: false)

            let timestamp = ISO8601DateFormatter().string(from: Date())
            let safeCommand = sanitizeDiagnosticsText(command, maxLength: 2_000)
            let safeStdout = sanitizeDiagnosticsText(stdout, maxLength: 6_000)
            let safeStderr = sanitizeDiagnosticsText(stderr, maxLength: 6_000)
            let entry = """

            [\(timestamp)] phase=\(phase)
            service=\(configuration.name) (\(configuration.id))
            cwd=\(workingDirectory)
            command=\(safeCommand)
            exit=\(terminationStatus)
            stdout:
            \(safeStdout.isEmpty ? "<empty>" : safeStdout)
            stderr:
            \(safeStderr.isEmpty ? "<empty>" : safeStderr)
            ---
            """

            if let data = entry.data(using: .utf8) {
                if fileManager.fileExists(atPath: diagnosticsFile.path) {
                    let handle = try FileHandle(forWritingTo: diagnosticsFile)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: diagnosticsFile, options: .atomic)
                }
            }

            return diagnosticsFile.path
        } catch {
            logger.error("Failed to write diagnostics for \(self.configuration.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func sanitizeDiagnosticsText(_ text: String, maxLength: Int) -> String {
        var value = text
        value = redactPattern(
            in: value,
            pattern: #"(?i)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|passwd|authorization)\b\s*[:=]\s*([^\s"']+)"#,
            template: "$1=<redacted>"
        )
        value = redactPattern(
            in: value,
            pattern: #"(?i)\b(authorization:\s*bearer)\s+[A-Za-z0-9._-]+"#,
            template: "$1 <redacted>"
        )
        value = redactPattern(
            in: value,
            pattern: #"://([^:/\s]+):([^@/\s]+)@"#,
            template: "://$1:<redacted>@"
        )

        if value.count > maxLength {
            let prefix = value.prefix(maxLength)
            return "\(prefix)\n<truncated>"
        }
        return value
    }

    private func redactPattern(in value: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(location: 0, length: value.utf16.count)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: template)
    }
}
