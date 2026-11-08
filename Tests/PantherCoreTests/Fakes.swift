import Foundation
@testable import PantherCore

/// Records the order of every system-touching call, across all fakes, so tests can assert
/// "journal written before sleep disabled".
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) { lock.withLock { entries.append(entry) } }
    var all: [String] { lock.withLock { entries } }
}

final class FakeSleepControl: SleepControl, @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private let log: CallLog
    var failNextSets = 0
    var ignoreWrites = false   // simulates another tool fighting us / a broken read-back

    init(log: CallLog) { self.log = log }

    func setSleepDisabled(_ disabled: Bool) throws(PantherError) {
        log.append("sleep=\(disabled ? 1 : 0)")
        let shouldFail: Bool = lock.withLock {
            if failNextSets > 0 { failNextSets -= 1; return true }
            if !ignoreWrites { value = disabled }
            return false
        }
        if shouldFail { throw .ioKit(operation: "IOPMSetSystemPowerSetting", code: -536_870_212) }
    }

    func readSleepDisabled() -> Bool? { lock.withLock { value } }

    /// Something other than Panther flips the switch.
    func externallySet(_ disabled: Bool) { lock.withLock { value = disabled } }
}

final class FakeLowPower: LowPowerControl, @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    private let log: CallLog
    var failSets = false

    init(log: CallLog) { self.log = log }

    func setLowPower(_ enabled: Bool) throws(PantherError) {
        if failSets { throw .ioKit(operation: "pmset lowpowermode", code: 1) }
        log.append("lowpower=\(enabled ? 1 : 0)")
        lock.withLock { on = enabled }
    }

    func isLowPowerOn() -> Bool? { lock.withLock { on } }
    /// The user switched it on themselves.
    func userSet(_ enabled: Bool) { lock.withLock { on = enabled } }
}

final class FakeSleeper: SystemSleeper, @unchecked Sendable {
    private let log: CallLog
    init(log: CallLog) { self.log = log }
    func sleepNow() throws(PantherError) { log.append("sleepNow") }
}

final class FakeJournalStore: JournalStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Journal?
    private let log: CallLog
    var failSaves = false
    var failLoad = false

    init(log: CallLog, initial: Journal? = nil) {
        self.log = log
        self.stored = initial
    }

    func load() throws(PantherError) -> Journal? {
        if failLoad { throw .journal("corrupt") }
        return lock.withLock { stored }
    }

    func save(_ journal: Journal) throws(PantherError) {
        if failSaves { throw .journal("disk full") }
        log.append("journal(dirty=\(journal.sleepDisabledByPanther), holds=\(journal.holds.count))")
        lock.withLock { stored = journal }
    }

    var current: Journal? { lock.withLock { stored } }
}

final class FakeInspector: ProcessInspector, @unchecked Sendable {
    private let lock = NSLock()
    private var alive: [Int32: UInt64] = [:]

    func spawn(_ pid: Int32, start: UInt64 = 1_000) { lock.withLock { alive[pid] = start } }
    func kill(_ pid: Int32) { _ = lock.withLock { alive.removeValue(forKey: pid) } }

    func identity(of pid: Int32) -> ProcessIdentity? {
        lock.withLock { alive[pid].map { ProcessIdentity(pid: pid, startMicros: $0) } }
    }
}

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// One fully faked world per test (fresh instance each time: no shared state between tests).
@MainActor
struct World {
    let log = CallLog()
    let clock = FakeClock()
    let inspector = FakeInspector()
    let sleep: FakeSleepControl
    let sleeper: FakeSleeper
    let lowPower: FakeLowPower
    let store: FakeJournalStore
    let controller: HoldController
    nonisolated static let boot = "boot-A"

    init(journal: Journal? = nil, limits: Limits = .standard) {
        sleep = FakeSleepControl(log: log)
        sleeper = FakeSleeper(log: log)
        lowPower = FakeLowPower(log: log)
        store = FakeJournalStore(log: log, initial: journal)
        let clock = self.clock
        controller = HoldController(HoldControllerDependencies(
            sleep: sleep, sleeper: sleeper, store: store, inspector: inspector, lowPower: lowPower,
            bootSessionUUID: World.boot, limits: limits, clock: { clock.now }))
    }

    nonisolated static let headlessClosed = Environment(lidClosed: true, externalDisplay: false,
                                            power: PowerSnapshot(onBattery: true, percent: 80), thermal: .nominal)
    nonisolated static let deskClosed = Environment(lidClosed: true, externalDisplay: true,
                                        power: PowerSnapshot(onBattery: false, percent: 80), thermal: .nominal)
    nonisolated static let open = Environment(lidClosed: false, externalDisplay: false,
                                  power: PowerSnapshot(onBattery: true, percent: 80), thermal: .nominal)
}
