import Foundation
import OSLog

final class LsofService {
    private let logger = Logger(subsystem: "com.localports.app", category: "LsofService")

    func fetchListeningPorts() async -> [ListeningPort] {
        do {
            let output = try await runLsof()
            return parse(output: output)
        } catch {
            logger.error("lsof fetch failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    private func runLsof() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN"]

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

                    if process.terminationStatus != 0 {
                        let errorText = String(decoding: errorData, as: UTF8.self)
                        throw NSError(
                            domain: "LsofService",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: errorText.isEmpty ? "lsof exited with status \(process.terminationStatus)" : errorText]
                        )
                    }

                    let output = String(decoding: outputData, as: UTF8.self)
                    continuation.resume(returning: output)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func parse(output: String) -> [ListeningPort] {
        let lines = output
            .split(whereSeparator: \ .isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !lines.isEmpty else {
            return []
        }

        var dedupedByPidAndPort: [String: ListeningPort] = [:]

        for line in lines {
            if line.hasPrefix("COMMAND") {
                continue
            }

            guard let parsed = parseLine(line) else {
                logger.debug("Skipping unparsable line: \(line, privacy: .public)")
                continue
            }

            guard parsed.hostClassification == .localhost || parsed.hostClassification == .unknown else {
                continue
            }

            let key = "\(parsed.pid)-\(parsed.port)"
            if dedupedByPidAndPort[key] == nil {
                dedupedByPidAndPort[key] = parsed
            }
        }

        return dedupedByPidAndPort.values.sorted {
            if $0.port == $1.port {
                return $0.pid < $1.pid
            }
            return $0.port < $1.port
        }
    }

    private func parseLine(_ line: String) -> ListeningPort? {
        let parts = line.split(maxSplits: 8, omittingEmptySubsequences: true, whereSeparator: \ .isWhitespace)
        guard parts.count >= 9 else {
            return nil
        }

        let process = String(parts[0])
        guard let pid = Int(parts[1]) else {
            return nil
        }
        let user = String(parts[2])
        let nameField = String(parts[8])

        guard let port = extractPort(from: nameField) else {
            return nil
        }

        let hostClassification = classifyHost(from: nameField)

        return ListeningPort(
            port: port,
            pid: pid,
            process: process,
            user: user,
            nameField: nameField,
            rawLine: line,
            hostClassification: hostClassification
        )
    }

    private func extractPort(from nameField: String) -> Int? {
        let withoutListenSuffix = stripListenSuffix(nameField)

        guard let endpoint = withoutListenSuffix.split(separator: "->").first else {
            return nil
        }

        let endpointText = String(endpoint)

        if let bracketRange = endpointText.range(of: #"]:(\d+)$"#, options: .regularExpression) {
            let suffix = String(endpointText[bracketRange])
            let portText = suffix.replacingOccurrences(of: "]:", with: "")
            return Int(portText)
        }

        guard let colon = endpointText.lastIndex(of: ":") else {
            return nil
        }

        let portText = endpointText[endpointText.index(after: colon)...]
        return Int(portText)
    }

    private func classifyHost(from nameField: String) -> HostClassification {
        let withoutListenSuffix = stripListenSuffix(nameField)

        guard let endpoint = withoutListenSuffix.split(separator: "->").first else {
            return .unknown
        }

        let endpointText = String(endpoint)

        if endpointText.hasPrefix("[") {
            guard
                let closeBracket = endpointText.firstIndex(of: "]"),
                closeBracket < endpointText.endIndex
            else {
                return .unknown
            }

            let host = String(endpointText[endpointText.index(after: endpointText.startIndex)..<closeBracket])
            return classifyHostValue(host)
        }

        guard let colon = endpointText.lastIndex(of: ":") else {
            return .unknown
        }

        let host = String(endpointText[..<colon])
        return classifyHostValue(host)
    }

    private func classifyHostValue(_ host: String) -> HostClassification {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let withoutZone = String(normalized.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: true).first ?? Substring(normalized))

        if withoutZone.isEmpty {
            return .unknown
        }

        if withoutZone == "localhost" || withoutZone == "127.0.0.1" || withoutZone == "::1" {
            return .localhost
        }

        if withoutZone == "*" || withoutZone == "0.0.0.0" || withoutZone == "::" {
            return .unknown
        }

        if withoutZone.hasPrefix("127.") {
            return .localhost
        }

        if withoutZone.range(of: #"^[0-9a-f:]+$"#, options: .regularExpression) != nil {
            return .nonLocal
        }

        if withoutZone.range(of: #"^\d+\.\d+\.\d+\.\d+$"#, options: .regularExpression) != nil {
            return .nonLocal
        }

        return .unknown
    }

    private func stripListenSuffix(_ nameField: String) -> String {
        nameField
            .replacingOccurrences(of: " (LISTEN)", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
