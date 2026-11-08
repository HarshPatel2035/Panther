import Foundation

public enum ReconcileDecision: Equatable, Sendable {
    /// Journal clean, sleep normal.
    case nothing
    /// `SleepDisabled` is on but Panther didn't do it. Leave it alone, report it.
    case foreignSleepDisabled
    /// Panther disabled sleep and these holds are still valid: carry on.
    case resume([Hold])
    /// Panther disabled sleep and nothing justifies it any more: restore sleep.
    case restore(dropped: [Hold])
}

/// Decides what to do when the daemon starts (boot, crash restart, upgrade). Pure.
public enum Reconciler {
    public static func decide(journal: Journal?, sleepDisabledNow: Bool?, currentBoot: String,
                              now: Date, inspector: any ProcessInspector) -> ReconcileDecision {
        guard let journal, journal.sleepDisabledByPanther else {
            return sleepDisabledNow == true ? .foreignSleepDisabled : .nothing
        }
        // A reboot ends every hold: processes are gone, and a timed session shouldn't survive a restart.
        guard journal.bootSessionUUID == currentBoot else { return .restore(dropped: journal.holds) }

        let valid = journal.holds.filter { isStillValid($0, now: now, inspector: inspector) }
        if valid.isEmpty { return .restore(dropped: journal.holds) }
        return .resume(valid)
    }

    static func isStillValid(_ hold: Hold, now: Date, inspector: any ProcessInspector) -> Bool {
        guard hold.endsAt > now else { return false }
        guard let process = hold.process else { return true }
        return inspector.isAlive(process)
    }
}
