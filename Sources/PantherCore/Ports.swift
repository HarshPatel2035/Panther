import Foundation

/// The single global switch: `SleepDisabled`. Implemented with IOKit in PantherSystem.
public protocol SleepControl: Sendable {
    func setSleepDisabled(_ disabled: Bool) throws(PantherError)
    /// Read back the real value. `nil` = unreadable.
    func readSleepDisabled() -> Bool?
}

/// Puts the Mac to sleep now (`IOPMSleepSystem`).
public protocol SystemSleeper: Sendable {
    func sleepNow() throws(PantherError)
}

/// Low Power Mode on the battery profile (`pmset -b lowpowermode`).
public protocol LowPowerControl: Sendable {
    func setLowPower(_ enabled: Bool) throws(PantherError)
    /// Whether Low Power Mode is in effect right now. `nil` = unknown.
    func isLowPowerOn() -> Bool?
}

/// For machines or tests where Panther shouldn't touch Low Power Mode.
public struct NoLowPowerControl: LowPowerControl {
    public init() {}
    public func setLowPower(_ enabled: Bool) throws(PantherError) {}
    public func isLowPowerOn() -> Bool? { nil }
}

/// Atomic, root-owned storage for the journal.
public protocol JournalStore: Sendable {
    func load() throws(PantherError) -> Journal?
    func save(_ journal: Journal) throws(PantherError)
}

/// Is this exact process (PID + start time) still alive?
public protocol ProcessInspector: Sendable {
    func identity(of pid: Int32) -> ProcessIdentity?
}

public extension ProcessInspector {
    func isAlive(_ identity: ProcessIdentity) -> Bool {
        self.identity(of: identity.pid) == identity
    }
}

public enum PantherError: Error, Equatable, Codable, CustomStringConvertible, Sendable {
    case notPrivileged
    case ioKit(operation: String, code: Int32)
    case readBackMismatch(expected: Bool, actual: Bool?)
    case journal(String)
    case invalidRequest(String)
    case noSuchHold
    case processNotFound(Int32)
    case daemonUnavailable(String)
    case stuck(String)

    public var description: String {
        switch self {
        case .notPrivileged: "not privileged: pantherd must run as root"
        case let .ioKit(op, code): "\(op) failed with IOKit error 0x\(String(UInt32(bitPattern: code), radix: 16))"
        case let .readBackMismatch(expected, actual):
            "SleepDisabled read back \(actual.map { $0 ? "1" : "0" } ?? "unreadable") after setting \(expected ? "1" : "0"); another tool may be changing it"
        case .journal(let msg): "journal: \(msg)"
        case .invalidRequest(let msg): msg
        case .noSuchHold: "no matching session"
        case .processNotFound(let pid): "process \(pid) is not running"
        case .daemonUnavailable(let msg):
            "can't reach pantherd (\(msg)). Either Panther isn't installed, or this isn't the installed copy " +
            "(after rebuilding, run sudo scripts/install.sh again). `panther doctor` checks which"
        case .stuck(let msg): "could not restore sleep: \(msg). Retrying; run `panther doctor`"
        }
    }
}
