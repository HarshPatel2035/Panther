import Foundation

/// A process, identified so that a reused PID can't fool us: same PID *and* same start time.
public struct ProcessIdentity: Codable, Equatable, Hashable, Sendable {
    public let pid: Int32
    public let startMicros: UInt64

    public init(pid: Int32, startMicros: UInt64) {
        self.pid = pid
        self.startMicros = startMicros
    }
}

/// Why the Mac is being kept awake.
public enum HoldKind: Codable, Equatable, Sendable {
    /// `panther start 2h`: ends at a fixed time.
    case timed
    /// `panther run -- cmd`: ends when the process exits, or at the cap.
    case untilExit(ProcessIdentity)
}

/// One reason to keep the Mac awake. Sleep is disabled while at least one hold exists.
public struct Hold: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: HoldKind
    public let label: String
    public let startedAt: Date
    /// The hard end: the deadline for a timed hold, the cap for a process hold.
    public let endsAt: Date
    /// Unix user who started it. Only that user (or root) may extend or end it. `nil` = root/internal.
    public let ownerUID: UInt32?

    public init(id: UUID = UUID(), kind: HoldKind, label: String, startedAt: Date, endsAt: Date,
                ownerUID: UInt32? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.ownerUID = ownerUID
    }

    public func extended(to newEnd: Date) -> Hold {
        Hold(id: id, kind: kind, label: label, startedAt: startedAt, endsAt: newEnd, ownerUID: ownerUID)
    }

    /// `caller` nil or 0 is root: may touch any hold.
    public func isControllable(by caller: UInt32?) -> Bool {
        guard let caller, caller != 0 else { return true }
        return ownerUID == caller
    }

    /// Labels come from clients and end up in logs: printable characters only, bounded length.
    public static func sanitizedLabel(_ raw: String) -> String {
        let printable = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "session" : String(text.prefix(maxLabelLength))
    }

    public static let maxLabelLength = 80

    public var process: ProcessIdentity? {
        if case .untilExit(let identity) = kind { return identity }
        return nil
    }
}

public enum EndReason: String, Codable, Equatable, Sendable {
    case deadline
    case processExited
    case userEnded
    case batteryFloor
    case criticalHeat
    case bagHeat
    case daemonStopped
    case reconcileExpired
}

/// Thermal pressure, as published by `com.apple.system.thermalpressurelevel` (OSThermalNotification.h).
public enum ThermalLevel: Int, Codable, Comparable, Sendable {
    case nominal = 0, moderate, heavy, trapping, sleeping

    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PowerSnapshot: Codable, Equatable, Sendable {
    public let onBattery: Bool
    public let percent: Int?

    public init(onBattery: Bool, percent: Int?) {
        self.onBattery = onBattery
        self.percent = percent
    }
}

/// What the daemon currently knows about the machine.
public struct Environment: Codable, Equatable, Sendable {
    public let lidClosed: Bool
    /// `nil` = unknown (no client has reported recently). Treated as "no external display".
    public let externalDisplay: Bool?
    public let power: PowerSnapshot?
    public let thermal: ThermalLevel

    public init(lidClosed: Bool, externalDisplay: Bool?, power: PowerSnapshot?, thermal: ThermalLevel) {
        self.lidClosed = lidClosed
        self.externalDisplay = externalDisplay
        self.power = power
        self.thermal = thermal
    }

    public static let unknown = Environment(lidClosed: false, externalDisplay: nil, power: nil, thermal: .nominal)

    /// Lid closed with no display in use: nobody can see or use the Mac.
    public var isHeadlessClosed: Bool { lidClosed && externalDisplay != true }

    public func with(lidClosed: Bool? = nil, externalDisplay: Bool?? = nil,
                     power: PowerSnapshot?? = nil, thermal: ThermalLevel? = nil) -> Environment {
        Environment(lidClosed: lidClosed ?? self.lidClosed,
                    externalDisplay: externalDisplay ?? self.externalDisplay,
                    power: power ?? self.power,
                    thermal: thermal ?? self.thermal)
    }
}

/// Fixed safety limits. Raising the cap is allowed; removing it is not.
public struct Limits: Codable, Equatable, Sendable {
    /// Hard ceiling no configuration can exceed. Long sessions stay safe because the battery and
    /// heat rules keep running the whole time.
    public static let absoluteMaxHold: TimeInterval = 7 * 86_400
    public static let minimumBatteryFloor = 5

    public let maxHold: TimeInterval
    public let defaultRunCap: TimeInterval
    public let batteryFloorPercent: Int
    public let bagHeatGrace: TimeInterval
    /// During a session on battery, Low Power Mode also turns on below this, lid open or not.
    public let lowPowerBelowPercent: Int

    public init(maxHold: TimeInterval = 3 * 86_400, defaultRunCap: TimeInterval = 8 * 3600,
                batteryFloorPercent: Int = 10, bagHeatGrace: TimeInterval = 10 * 60,
                lowPowerBelowPercent: Int = 30) {
        self.lowPowerBelowPercent = min(max(lowPowerBelowPercent, 0), 100)
        self.maxHold = min(max(maxHold, 60), Limits.absoluteMaxHold)
        self.defaultRunCap = min(max(defaultRunCap, 60), self.maxHold)
        self.batteryFloorPercent = max(batteryFloorPercent, Limits.minimumBatteryFloor)
        self.bagHeatGrace = max(bagHeatGrace, 60)
    }

    public static let standard = Limits()
}

/// Write-ahead record of what Panther changed. Written *before* sleep is disabled.
public struct Journal: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let bootSessionUUID: String
    public let sleepDisabledByPanther: Bool
    public let holds: [Hold]
    /// Optional so journals written before Phase 3 still decode (missing = false).
    public let lowPowerSetByPanther: Bool?

    public init(bootSessionUUID: String, sleepDisabledByPanther: Bool, holds: [Hold], lowPowerSetByPanther: Bool = false) {
        self.version = Journal.currentVersion
        self.bootSessionUUID = bootSessionUUID
        self.sleepDisabledByPanther = sleepDisabledByPanther
        self.holds = holds
        self.lowPowerSetByPanther = lowPowerSetByPanther
    }

    public static func clean(boot: String) -> Journal {
        Journal(bootSessionUUID: boot, sleepDisabledByPanther: false, holds: [])
    }
}
