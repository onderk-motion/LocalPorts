import AppKit
import Foundation
import OSLog

final class ActionsService {
    struct BrowserOption: Identifiable, Hashable {
        let bundleIdentifier: String
        let name: String

        var id: String {
            bundleIdentifier
        }
    }

    static let shared = ActionsService()

    private let logger = Logger(subsystem: "com.localports.app", category: "ActionsService")

    private init() {}

    func openInBrowser(port: Int, browserBundleID: String? = nil) {
        openInBrowser(urlString: "http://localhost:\(port)", browserBundleID: browserBundleID)
    }

    func copyURL(port: Int) {
        copyURL(urlString: "http://localhost:\(port)")
    }

    func availableBrowsers() -> [BrowserOption] {
        guard let probeURL = URL(string: "http://localhost") else {
            return []
        }

        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: probeURL)
        var seenBundleIDs: Set<String> = []
        var browsers: [BrowserOption] = []

        for appURL in appURLs {
            guard let bundle = Bundle(url: appURL), let bundleIdentifier = bundle.bundleIdentifier else {
                continue
            }
            guard !seenBundleIDs.contains(bundleIdentifier) else {
                continue
            }

            seenBundleIDs.insert(bundleIdentifier)

            let displayName =
                (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? appURL.deletingPathExtension().lastPathComponent

            browsers.append(
                BrowserOption(
                    bundleIdentifier: bundleIdentifier,
                    name: displayName
                )
            )
        }

        return browsers.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func openInBrowser(urlString: String, browserBundleID: String? = nil) {
        guard let url = URL(string: urlString) else {
            logger.error("Invalid URL string: \(urlString, privacy: .public)")
            return
        }

        if let browserBundleID = browserBundleID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !browserBundleID.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserBundleID) {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { [logger] _, error in
                if let error {
                    logger.error(
                        "Failed to open URL with \(browserBundleID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    NSWorkspace.shared.open(url)
                }
            }
            logger.info("Opened URL in browser \(browserBundleID, privacy: .public): \(url.absoluteString, privacy: .public)")
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
