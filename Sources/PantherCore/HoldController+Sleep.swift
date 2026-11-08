import Foundation

/// The ordered, failure-aware steps that touch the global sleep switch.
extension HoldController {
    func add(_ hold: Hold) throws(PantherError) {
        let newHolds = holds + [hold]
        if sleepDisabledByUs {
            if stuck != nil {
                // A restore was still pending; this new hold needs sleep disabled after all.
                try setAndVerify(disabled: true)
                stuck = nil
                stuckReason = nil
            }
            holds = newHolds
            persist()
            return
        }
        // Write-ahead: if we crash right after disabling sleep, the journal already says so.
        try deps.store.save(journal(sleepDisabled: true, holds: newHolds))
        do {
            try setAndVerify(disabled: true)
        } catch {
            rollBackFailedArm()
            throw error
        }
        sleepDisabledByUs = true
        foreignSleepDisabled = false
        holds = newHolds
    }

    private func rollBackFailedArm() {
        try? deps.sleep.setSleepDisabled(false)
        if deps.sleep.readSleepDisabled() == false {
            try? deps.store.save(journal(sleepDisabled: false, holds: []))
        } else {
            // Couldn't confirm sleep is back: keep a dirty journal so reconcile retries.
            sleepDisabledByUs = true
            stuck = "rollback after a failed start could not be confirmed"
        }
    }

    func remove(ids: Set<UUID>, reason: EndReason) {
        let ending = holds.filter { ids.contains($0.id) }
        guard !ending.isEmpty else { return }
        holds = holds.filter { !ids.contains($0.id) }
        for hold in ending { record("ended \(hold.label): \(Self.describe(reason))") }
        if holds.isEmpty {
            restoreSleep(reason: reason)
        } else {
            persist()
            applyLowPowerPolicy()
        }
        onChange?()
    }

    /// Turns sleep back on. Then, if nobody can see the Mac (lid closed, no display), sleeps it now:
    /// the lid-close event was swallowed while sleep was disabled, so macOS won't do it by itself (Insomnia #94).
    func restoreSleep(reason: EndReason) {
        guard sleepDisabledByUs else { return }
        do {
            try setAndVerify(disabled: false)
        } catch {
            let message = "\(error)"
            if stuck == nil { record("restore failed: \(message); retrying") }
            stuck = message
            stuckReason = reason
            try? deps.store.save(journal(sleepDisabled: true, holds: holds))
            return
        }
        sleepDisabledByUs = false
        stuck = nil
        stuckReason = nil
        applyLowPowerPolicy()   // holds are gone: Low Power Mode goes back too, before any sleep-now
        do { try deps.store.save(journal(sleepDisabled: false, holds: [])) } catch {
            record("sleep restored, but the journal could not be cleared: \(error)")
        }
        record("sleep restored (\(Self.describe(reason)))")
        guard environment.isHeadlessClosed, reason != .daemonStopped else { return }
        do {
            try deps.sleeper.sleepNow()
            record("lid is closed: sleeping now")
        } catch {
            record("lid is closed but sleep-now failed: \(error)")
        }
    }

    func reassertSleepDisabled() {
        do { try setAndVerify(disabled: true) } catch { record("could not keep sleep disabled: \(error)") }
    }

    func persist() {
        do {
            try deps.store.save(journal(sleepDisabled: sleepDisabledByUs, holds: holds))
        } catch {
            record("journal write failed: \(error)")
        }
    }

    func journal(sleepDisabled: Bool, holds: [Hold], lowPower: Bool? = nil) -> Journal {
        Journal(bootSessionUUID: deps.bootSessionUUID, sleepDisabledByPanther: sleepDisabled, holds: holds,
                lowPowerSetByPanther: lowPower ?? lowPowerByUs)
    }

    /// Turns Low Power Mode on or off to match the policy. Only ever turns off what Panther turned on.
    func applyLowPowerPolicy() {
        let wanted = policy.wantsLowPower(environment, sessionActive: !holds.isEmpty)
        if wanted, !lowPowerByUs {
            guard deps.lowPower.isLowPowerOn() == false else { return }   // already on (yours) or unknown
            do {
                try deps.store.save(journal(sleepDisabled: sleepDisabledByUs, holds: holds, lowPower: true))   // write-ahead
                try deps.lowPower.setLowPower(true)
                lowPowerByUs = true
                record("Low Power Mode on (saving battery while the lid is closed)")
            } catch {
                record("could not turn on Low Power Mode: \(error)")
                persist()
            }
        } else if !wanted, lowPowerByUs {
            do {
                try deps.lowPower.setLowPower(false)
                lowPowerByUs = false
                persist()
                record("Low Power Mode off")
            } catch {
                record("could not turn off Low Power Mode: \(error); retrying")
            }
        }
    }

    private func setAndVerify(disabled: Bool) throws(PantherError) {
        try deps.sleep.setSleepDisabled(disabled)
        let actual = deps.sleep.readSleepDisabled()
        guard actual == disabled else { throw .readBackMismatch(expected: disabled, actual: actual) }
    }
}
