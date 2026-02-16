import AppKit
import Foundation
import OSLog

final class ActionsService {
    static let shared = ActionsService()

    private let logger = Logger(subsystem: "com.localports.app", category: "ActionsService")

    private init() {}

    func openInBrowser(port: Int) {
        openInBrowser(urlString: "http://localhost:\(port)")
    }

    func copyURL(port: Int) {
        copyURL(urlString: "http://localhost:\(port)")
    }

    func openInBrowser(urlString: String) {
        guard let url = URL(string: urlString) else {
            logger.error("Invalid URL string: \(urlString, privacy: .public)")
            return
        }

        NSWorkspace.shared.open(url)
        logger.info("Opened URL in browser: \(url.absoluteString, privacy: .public)")
    }

    func copyURL(urlString: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urlString, forType: .string)
        logger.info("Copied URL to clipboard: \(urlString, privacy: .public)")
    }

    func showInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            logger.info("Opened Finder at path: \(path, privacy: .public)")
        } else {
            logger.error("Cannot open Finder, path missing: \(path, privacy: .public)")
        }
    }

    @discardableResult
    func terminate(pid: Int) -> Bool {
        send(signal: SIGTERM, to: pid)
    }

    @discardableResult
    func forceKill(pid: Int) -> Bool {
        send(signal: SIGKILL, to: pid)
    }

    @discardableResult
    private func send(signal: Int32, to pid: Int) -> Bool {
        let result = Darwin.kill(pid_t(pid), signal)
        if result == 0 {
            logger.info("Sent signal \(signal) to pid \(pid)")
            return true
        }

        logger.error("Failed to send signal \(signal) to pid \(pid), errno=\(errno)")
        return false
    }
}
