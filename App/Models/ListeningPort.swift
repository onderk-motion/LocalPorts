import Foundation

enum HostClassification: String, Hashable {
    case localhost
    case unknown
    case nonLocal
}

struct ListeningPort: Identifiable, Hashable {
    let port: Int
    let pid: Int
    let process: String
    let user: String
    let nameField: String
    let rawLine: String
    let hostClassification: HostClassification

    var id: String {
        "\(pid)-\(port)"
    }

    var processDisplayName: String {
        process.isEmpty ? "Unknown" : process
    }

    var isCommonDevPort: Bool {
        Self.commonDevPorts.contains(port)
    }

    private static let commonDevPorts: Set<Int> = [3000, 5120, 5173, 8080]
}
