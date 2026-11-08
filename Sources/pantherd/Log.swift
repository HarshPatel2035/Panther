import Foundation
import os

/// Unified logging plus a plain line on stderr (launchd sends it to /Library/Logs/Panther/pantherd.log).
struct Log: Sendable {
    private let logger = Logger(subsystem: "com.panther.daemon", category: "daemon")

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        write("info", message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("error", message)
    }

    private func write(_ level: String, _ message: String) {
        let line = "\(Date().ISO8601Format()) [\(level)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
