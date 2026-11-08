import Foundation

/// Hard safety rules. They live in the daemon so they work with no UI running.
/// Pure: given what we know, should every hold end now, and why?
public struct SafetyPolicy: Sendable {
    public let limits: Limits

    public init(limits: Limits = .standard) {
        self.limits = limits
    }

    public func evaluate(_ env: Environment, heavySince: Date?, now: Date) -> EndReason? {
        if env.thermal >= .trapping { return .criticalHeat }
        if let since = heavySince, env.thermal >= .heavy, env.isHeadlessClosed,
           now.timeIntervalSince(since) >= limits.bagHeatGrace {
            return .bagHeat
        }
        if let power = env.power, power.onBattery, let percent = power.percent,
           percent <= limits.batteryFloorPercent {
            return .batteryFloor
        }
        return nil
    }

    /// Should Low Power Mode be on? Only during a session, only on battery: when nobody can see the
    /// Mac (lid closed, no display), or when the battery is getting low.
    public func wantsLowPower(_ env: Environment, sessionActive: Bool) -> Bool {
        guard sessionActive, let power = env.power, power.onBattery else { return false }
        if env.isHeadlessClosed { return true }
        return (power.percent ?? 100) < limits.lowPowerBelowPercent
    }

    /// When "heavy heat while closed and headless" started, carried forward between updates.
    public func heavySince(previous: Date?, env: Environment, now: Date) -> Date? {
        guard env.thermal >= .heavy, env.isHeadlessClosed else { return nil }
        return previous ?? now
    }
}
