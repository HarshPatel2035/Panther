import Foundation

/// What a client asks the daemon for.
public enum HoldRequest: Codable, Equatable, Sendable {
    case timed(duration: TimeInterval, label: String)
    case untilExit(pid: Int32, cap: TimeInterval?, label: String)
}

public struct PantherEvent: Codable, Equatable, Sendable {
    public let date: Date
    public let message: String

    public init(date: Date, message: String) {
        self.date = date
        self.message = message
    }
}

/// Everything `panther status` / `panther doctor` / the menu bar show.
public struct DaemonStatus: Codable, Equatable, Sendable {
    public let now: Date
    public let holds: [Hold]
    public let environment: Environment
    /// Read back from the system right now, not what we think we set.
    public let sleepDisabled: Bool?
    public let sleepDisabledByPanther: Bool
    public let foreignSleepDisabled: Bool
    public let stuck: String?
    public let limits: Limits
    public let events: [PantherEvent]
    public let lowPowerOn: Bool?
    public let lowPowerByPanther: Bool

    public init(now: Date, holds: [Hold], environment: Environment, sleepDisabled: Bool?,
                sleepDisabledByPanther: Bool, foreignSleepDisabled: Bool, stuck: String?,
                limits: Limits, events: [PantherEvent], lowPowerOn: Bool? = nil, lowPowerByPanther: Bool = false) {
        self.lowPowerOn = lowPowerOn
        self.lowPowerByPanther = lowPowerByPanther
        self.now = now
        self.holds = holds
        self.environment = environment
        self.sleepDisabled = sleepDisabled
        self.sleepDisabledByPanther = sleepDisabledByPanther
        self.foreignSleepDisabled = foreignSleepDisabled
        self.stuck = stuck
        self.limits = limits
        self.events = events
    }

    public var isActive: Bool { !holds.isEmpty }
    public var endsAt: Date? { holds.map(\.endsAt).max() }
}
