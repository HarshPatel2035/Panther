import Foundation
import Testing
@testable import PantherCore

@Suite("Durations")
struct DurationTests {
    @Test("Parses compact durations", arguments: [
        ("2h", 7_200.0), ("1h30m", 5_400.0), ("90m", 5_400.0), ("45", 2_700.0),
        ("1d", 86_400.0), ("2H", 7_200.0), (" 10m ", 600.0), ("1m30s", 90.0),
    ])
    func parses(text: String, expected: TimeInterval) throws {
        #expect(try Durations.parse(text) == expected)
    }

    @Test("Rejects malformed durations", arguments: ["", "abc", "2x", "m30", "30m1h", "1h1h", "1.5h", "h"])
    func rejects(text: String) {
        #expect(throws: DurationError.self) { try Durations.parse(text) }
    }

    @Test("Rejects durations under a minute")
    func rejectsTooShort() {
        #expect(throws: DurationError.tooShort) { try Durations.parse("30s") }
    }

    @Test("Formats for humans")
    func formats() {
        #expect(Durations.format(3_725) == "1h 2m")
        #expect(Durations.format(45) == "45s")
        #expect(Durations.format(0) == "0s")
        #expect(Durations.format(90_000) == "1d 1h")
        #expect(Durations.format(125) == "2m 5s")
    }
}

@Suite("Safety policy")
struct SafetyPolicyTests {
    let policy = SafetyPolicy()
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("Critical heat always ends sessions")
    func criticalHeat() {
        let env = World.open.with(thermal: .trapping)
        #expect(policy.evaluate(env, heavySince: nil, now: now) == .criticalHeat)
    }

    @Test("Heavy heat with the lid closed and no display ends sessions only after the grace period")
    func bagHeat() {
        let env = World.headlessClosed.with(thermal: .heavy)
        #expect(policy.evaluate(env, heavySince: now.addingTimeInterval(-599), now: now) == nil)
        #expect(policy.evaluate(env, heavySince: now.addingTimeInterval(-600), now: now) == .bagHeat)
    }

    @Test("Heavy heat at a desk with an external display is not the bag rule")
    func heavyAtDesk() {
        let env = World.deskClosed.with(thermal: .heavy)
        #expect(policy.evaluate(env, heavySince: now.addingTimeInterval(-3_600), now: now) == nil)
        #expect(policy.heavySince(previous: nil, env: env, now: now) == nil)
    }

    @Test("Unknown display counts as no display (safe default)")
    func unknownDisplay() {
        let env = World.headlessClosed.with(externalDisplay: .some(nil), thermal: .heavy)
        #expect(policy.heavySince(previous: nil, env: env, now: now) == now)
    }

    @Test("Battery floor applies only on battery")
    func batteryFloor() {
        let low = World.open.with(power: PowerSnapshot(onBattery: true, percent: 10))
        let charging = World.open.with(power: PowerSnapshot(onBattery: false, percent: 3))
        #expect(policy.evaluate(low, heavySince: nil, now: now) == .batteryFloor)
        #expect(policy.evaluate(charging, heavySince: nil, now: now) == nil)
    }

    @Test("Limits can't be configured below their safety minimums")
    func limitsClamp() {
        let limits = Limits(maxHold: 1_000_000, defaultRunCap: 999_999, batteryFloorPercent: 0, bagHeatGrace: 0)
        #expect(limits.maxHold == Limits.absoluteMaxHold)
        #expect(Limits.absoluteMaxHold == 7 * 86_400)
        #expect(Limits.standard.maxHold == 3 * 86_400)
        #expect(Limits.standard.defaultRunCap == 8 * 3_600)
        #expect(limits.batteryFloorPercent == Limits.minimumBatteryFloor)
        #expect(limits.bagHeatGrace == 60)
        #expect(limits.defaultRunCap <= limits.maxHold)
    }
}

@Suite("Reconciler")
struct ReconcilerTests {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let inspector = FakeInspector()

    func journal(_ holds: [Hold], boot: String = World.boot, dirty: Bool = true) -> Journal {
        Journal(bootSessionUUID: boot, sleepDisabledByPanther: dirty, holds: holds)
    }

    func timed(endingIn seconds: TimeInterval) -> Hold {
        Hold(kind: .timed, label: "t", startedAt: now.addingTimeInterval(-60), endsAt: now.addingTimeInterval(seconds))
    }

    @Test("No journal and sleep normal: nothing to do")
    func clean() {
        #expect(Reconciler.decide(journal: nil, sleepDisabledNow: false, currentBoot: World.boot,
                                  now: now, inspector: inspector) == .nothing)
    }

    @Test("Sleep disabled by someone else is reported, not touched")
    func foreign() {
        #expect(Reconciler.decide(journal: .clean(boot: World.boot), sleepDisabledNow: true,
                                  currentBoot: World.boot, now: now, inspector: inspector) == .foreignSleepDisabled)
    }

    @Test("A reboot ends every hold")
    func rebootRestores() {
        let holds = [timed(endingIn: 3_600)]
        #expect(Reconciler.decide(journal: journal(holds, boot: "old"), sleepDisabledNow: true,
                                  currentBoot: World.boot, now: now, inspector: inspector) == .restore(dropped: holds))
    }

    @Test("Expired holds restore sleep, valid ones resume")
    func mixed() {
        let expired = timed(endingIn: -1)
        let valid = timed(endingIn: 600)
        #expect(Reconciler.decide(journal: journal([expired]), sleepDisabledNow: true, currentBoot: World.boot,
                                  now: now, inspector: inspector) == .restore(dropped: [expired]))
        #expect(Reconciler.decide(journal: journal([expired, valid]), sleepDisabledNow: true, currentBoot: World.boot,
                                  now: now, inspector: inspector) == .resume([valid]))
    }

    @Test("A reused PID doesn't keep a process hold alive")
    func pidReuse() {
        inspector.spawn(42, start: 999)   // same pid, different start time
        let hold = Hold(kind: .untilExit(ProcessIdentity(pid: 42, startMicros: 1)), label: "job",
                        startedAt: now, endsAt: now.addingTimeInterval(3_600))
        #expect(Reconciler.decide(journal: journal([hold]), sleepDisabledNow: true, currentBoot: World.boot,
                                  now: now, inspector: inspector) == .restore(dropped: [hold]))
    }
}
