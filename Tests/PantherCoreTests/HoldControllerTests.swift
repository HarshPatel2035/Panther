import Foundation
import Testing
@testable import PantherCore

@MainActor
@Suite("Hold controller: starting and ending")
struct HoldControllerLifecycleTests {
    @Test("Starting writes the journal before disabling sleep, then confirms it")
    func writeAheadOrder() throws {
        let w = World()
        _ = try w.controller.start(.timed(duration: 3_600, label: "t"))
        #expect(w.log.all == ["journal(dirty=true, holds=1)", "sleep=1"])
        #expect(w.sleep.readSleepDisabled() == true)
        #expect(w.store.current?.sleepDisabledByPanther == true)
    }

    @Test("If disabling sleep fails, nothing is left changed")
    func failedArmRollsBack() {
        let w = World()
        w.sleep.failNextSets = 1
        #expect(throws: PantherError.self) { try w.controller.start(.timed(duration: 600, label: "t")) }
        #expect(w.controller.holds.isEmpty)
        #expect(w.sleep.readSleepDisabled() == false)
        #expect(w.store.current == .clean(boot: World.boot))
    }

    @Test("If the read-back disagrees, start fails instead of pretending")
    func readBackMismatch() {
        let w = World()
        w.sleep.ignoreWrites = true
        #expect(throws: PantherError.readBackMismatch(expected: true, actual: false)) {
            try w.controller.start(.timed(duration: 600, label: "t"))
        }
        #expect(w.controller.holds.isEmpty)
    }

    @Test("If the journal can't be written, sleep is never disabled")
    func journalFailureBlocksStart() {
        let w = World()
        w.store.failSaves = true
        #expect(throws: PantherError.self) { try w.controller.start(.timed(duration: 600, label: "t")) }
        #expect(!w.log.all.contains("sleep=1"))
    }

    @Test("Ending the last hold restores sleep and cleans the journal")
    func endRestores() throws {
        let w = World()
        let hold = try w.controller.start(.timed(duration: 600, label: "t"))
        try w.controller.end(id: hold.id)
        #expect(w.sleep.readSleepDisabled() == false)
        #expect(w.store.current == .clean(boot: World.boot))
        #expect(!w.log.all.contains("sleepNow"))   // lid open: don't sleep
    }

    @Test("Ending with the lid closed and no display sleeps the Mac now (Insomnia #94)")
    func endWithLidClosedSleeps() throws {
        let w = World()
        w.controller.update(World.headlessClosed)
        _ = try w.controller.start(.timed(duration: 600, label: "t"))
        try w.controller.end(id: nil)
        #expect(w.log.all.suffix(2) == ["journal(dirty=false, holds=0)", "sleepNow"])
    }

    @Test("Ending at a desk with an external display does not sleep the Mac (Insomnia #97)")
    func endAtDeskDoesNotSleep() throws {
        let w = World()
        w.controller.update(World.deskClosed)
        _ = try w.controller.start(.timed(duration: 600, label: "t"))
        try w.controller.end(id: nil)
        #expect(!w.log.all.contains("sleepNow"))
    }

    @Test("Two holds: ending one keeps sleep disabled")
    func twoHolds() throws {
        let w = World()
        w.inspector.spawn(77)
        let first = try w.controller.start(.timed(duration: 600, label: "t"))
        _ = try w.controller.start(.untilExit(pid: 77, cap: nil, label: "job"))
        try w.controller.end(id: first.id)
        #expect(w.sleep.readSleepDisabled() == true)
        #expect(w.controller.holds.count == 1)
        #expect(w.log.all.filter { $0 == "sleep=1" }.count == 1)   // armed once, not twice
    }

    @Test("Ending an unknown hold is an error")
    func endUnknown() {
        let w = World()
        #expect(throws: PantherError.noSuchHold) { try w.controller.end(id: UUID()) }
        #expect(throws: PantherError.noSuchHold) { try w.controller.end(id: nil) }
    }

    @Test("Shutdown restores sleep but doesn't put the Mac to sleep")
    func shutdown() throws {
        let w = World()
        w.controller.update(World.headlessClosed)
        _ = try w.controller.start(.timed(duration: 600, label: "t"))
        w.controller.shutdown()
        #expect(w.sleep.readSleepDisabled() == false)
        #expect(!w.log.all.contains("sleepNow"))
    }
}

@MainActor
@Suite("Hold controller: requests and limits")
struct HoldControllerRequestTests {
    @Test("Timed sessions must be between 1 minute and the max")
    func timedLimits() {
        let w = World()
        #expect(throws: PantherError.self) { try w.controller.start(.timed(duration: 30, label: "t")) }
        #expect(throws: PantherError.self) { try w.controller.start(.timed(duration: 13 * 3_600, label: "t")) }
    }

    @Test("A process hold needs a running process and defaults to the run cap")
    func processHold() throws {
        let w = World()
        #expect(throws: PantherError.processNotFound(5)) {
            try w.controller.start(.untilExit(pid: 5, cap: nil, label: "job"))
        }
        w.inspector.spawn(5)
        let hold = try w.controller.start(.untilExit(pid: 5, cap: nil, label: "job"))
        #expect(hold.endsAt.timeIntervalSince(hold.startedAt) == Limits.standard.defaultRunCap)
    }

    @Test("Extend moves the end, but never past the max")
    func extend() throws {
        let w = World()
        let hold = try w.controller.start(.timed(duration: 3_600, label: "t"))
        let longer = try w.controller.extend(id: nil, by: 1_800)
        #expect(longer.endsAt == hold.endsAt.addingTimeInterval(1_800))
        #expect(throws: PantherError.self) { try w.controller.extend(id: nil, by: 12 * 3_600) }
    }

    @Test("Starting is refused while the battery is below the floor")
    func refusedOnLowBattery() {
        let w = World()
        w.controller.update(World.open.with(power: PowerSnapshot(onBattery: true, percent: 8)))
        #expect(throws: PantherError.self) { try w.controller.start(.timed(duration: 600, label: "t")) }
    }
}

@MainActor
@Suite("Hold controller: system events")
struct HoldControllerEventTests {
    @Test("A finished program ends its hold")
    func processExit() throws {
        let w = World()
        w.inspector.spawn(9)
        _ = try w.controller.start(.untilExit(pid: 9, cap: nil, label: "job"))
        w.controller.processExited(pid: 9)          // event arrived but process still alive: ignore
        #expect(w.controller.holds.count == 1)
        w.inspector.kill(9)
        w.controller.processExited(pid: 9)
        #expect(w.controller.holds.isEmpty)
        #expect(w.sleep.readSleepDisabled() == false)
    }

    @Test("Tick ends expired holds and holds whose process vanished")
    func tick() throws {
        let w = World()
        w.inspector.spawn(3)
        _ = try w.controller.start(.timed(duration: 600, label: "t"))
        _ = try w.controller.start(.untilExit(pid: 3, cap: nil, label: "job"))
        w.clock.advance(601)
        w.controller.tick()
        #expect(w.controller.holds.count == 1)
        w.inspector.kill(3)                          // missed exit event
        w.controller.tick()
        #expect(w.controller.holds.isEmpty)
    }

    @Test("Low battery during a session ends everything")
    func batteryFloorEndsSessions() throws {
        let w = World()
        w.controller.update(World.headlessClosed)
        _ = try w.controller.start(.timed(duration: 3_600, label: "t"))
        w.controller.update(World.headlessClosed.with(power: PowerSnapshot(onBattery: true, percent: 9)))
        #expect(w.controller.holds.isEmpty)
        #expect(w.log.all.last == "sleepNow")
    }

    @Test("Heavy heat in a bag ends sessions after the grace period")
    func bagHeat() throws {
        let w = World()
        w.controller.update(World.headlessClosed)
        _ = try w.controller.start(.timed(duration: 3_600, label: "t"))
        w.controller.update(World.headlessClosed.with(thermal: .heavy))
        w.clock.advance(599)
        w.controller.tick()
        #expect(w.controller.holds.count == 1)
        w.clock.advance(2)
        w.controller.tick()
        #expect(w.controller.holds.isEmpty)
    }

    @Test("If another tool turns sleep back on mid-session, tick turns it off again")
    func reassert() throws {
        let w = World()
        _ = try w.controller.start(.timed(duration: 600, label: "t"))
        w.sleep.externallySet(false)
        w.controller.tick()
        #expect(w.sleep.readSleepDisabled() == true)
    }

    @Test("A failed restore is retried on tick, with a dirty journal in the meantime")
    func stuckRestoreRetries() throws {
        let w = World()
        let hold = try w.controller.start(.timed(duration: 600, label: "t"))
        w.sleep.failNextSets = 1
        try w.controller.end(id: hold.id)
        #expect(w.controller.stuck != nil)
        #expect(w.store.current?.sleepDisabledByPanther == true)
        w.controller.tick()
        #expect(w.controller.stuck == nil)
        #expect(w.sleep.readSleepDisabled() == false)
        #expect(w.store.current == .clean(boot: World.boot))
    }
}

@MainActor
@Suite("Hold controller: reconcile at daemon start")
struct HoldControllerReconcileTests {
    @Test("After a crash mid-session, valid holds resume and sleep stays disabled")
    func resumeAfterCrash() {
        let now = FakeClock().now
        let hold = Hold(kind: .timed, label: "t", startedAt: now, endsAt: now.addingTimeInterval(600))
        let w = World(journal: Journal(bootSessionUUID: World.boot, sleepDisabledByPanther: true, holds: [hold]))
        w.sleep.externallySet(true)
        #expect(w.controller.reconcile() == .resume([hold]))
        #expect(w.controller.holds == [hold])
        #expect(w.sleep.readSleepDisabled() == true)
    }

    @Test("After a crash, expired holds restore sleep")
    func restoreAfterCrash() {
        let now = FakeClock().now
        let hold = Hold(kind: .timed, label: "t", startedAt: now, endsAt: now.addingTimeInterval(-1))
        let w = World(journal: Journal(bootSessionUUID: World.boot, sleepDisabledByPanther: true, holds: [hold]))
        w.sleep.externallySet(true)
        w.controller.reconcile()
        #expect(w.sleep.readSleepDisabled() == false)
        #expect(w.store.current == .clean(boot: World.boot))
    }

    @Test("An unreadable journal is treated as dirty: restore sleep")
    func corruptJournal() {
        let w = World()
        w.store.failLoad = true
        w.sleep.externallySet(true)
        w.controller.reconcile()
        #expect(w.sleep.readSleepDisabled() == false)
    }

    @Test("Foreign SleepDisabled is reported and left alone")
    func foreign() {
        let w = World()
        w.sleep.externallySet(true)
        #expect(w.controller.reconcile() == .foreignSleepDisabled)
        #expect(w.controller.foreignSleepDisabled)
        #expect(w.sleep.readSleepDisabled() == true)
    }
}

@MainActor
@Suite("Hold controller: failed-restore edge cases")
struct HoldControllerStuckTests {
    @Test("A new session during a pending restore keeps sleep disabled; the retry doesn't undo it")
    func newHoldWhileStuck() throws {
        let w = World()
        let first = try w.controller.start(.timed(duration: 600, label: "t"))
        w.sleep.failNextSets = 1
        try w.controller.end(id: first.id)            // restore fails: stuck
        #expect(w.controller.stuck != nil)
        _ = try w.controller.start(.timed(duration: 600, label: "again"))
        #expect(w.controller.stuck == nil)
        w.controller.tick()
        #expect(w.sleep.readSleepDisabled() == true)
        #expect(w.controller.holds.count == 1)
    }

    @Test("A restore that succeeds on retry still sleeps a closed, headless Mac")
    func retrySleepsClosedMac() throws {
        let w = World()
        w.controller.update(World.headlessClosed)
        let hold = try w.controller.start(.timed(duration: 600, label: "t"))
        w.sleep.failNextSets = 1
        try w.controller.end(id: hold.id)
        #expect(!w.log.all.contains("sleepNow"))
        w.controller.tick()
        #expect(w.log.all.last == "sleepNow")
    }
}
