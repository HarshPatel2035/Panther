import Foundation

public struct HoldControllerDependencies: Sendable {
    public let sleep: any SleepControl
    public let sleeper: any SystemSleeper
    public let store: any JournalStore
    public let inspector: any ProcessInspector
    public let lowPower: any LowPowerControl
    public let bootSessionUUID: String
    public let limits: Limits
    public let clock: @Sendable () -> Date
    public let log: @Sendable (String) -> Void

    public init(sleep: any SleepControl, sleeper: any SystemSleeper, store: any JournalStore,
                inspector: any ProcessInspector, lowPower: any LowPowerControl = NoLowPowerControl(),
                bootSessionUUID: String, limits: Limits = .standard,
                clock: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.sleep = sleep
        self.sleeper = sleeper
        self.store = store
        self.inspector = inspector
        self.lowPower = lowPower
        self.bootSessionUUID = bootSessionUUID
        self.limits = limits
        self.clock = clock
        self.log = log
    }
}

/// The one owner of Panther's state. Every change follows the same order:
/// journal first, then the system, then read back. Sleep is disabled exactly while holds exist.
@MainActor
public final class HoldController {
    let deps: HoldControllerDependencies
    let policy: SafetyPolicy
    static let maxEvents = 50
    public static let maxHolds = 16
    /// A client's "external display in use" report is trusted this long, then treated as unknown.
    public static let displayReportLifetime: TimeInterval = 120

    public internal(set) var holds: [Hold] = []
    public private(set) var environment: Environment = .unknown
    public internal(set) var stuck: String?
    /// Why the failed restore was happening, so a successful retry still sleeps a closed Mac.
    var stuckReason: EndReason?
    public internal(set) var foreignSleepDisabled = false
    var sleepDisabledByUs = false
    /// Panther turned Low Power Mode on (so Panther must turn it off). Never set for the user's own LPM.
    public internal(set) var lowPowerByUs = false
    var heavySince: Date?
    var displayReportedAt: Date?
    var events: [PantherEvent] = []

    /// Called after every change to holds, so the daemon can re-arm timers and process watches.
    public var onChange: (@MainActor () -> Void)?

    public init(_ deps: HoldControllerDependencies) {
        self.deps = deps
        self.policy = SafetyPolicy(limits: deps.limits)
    }

    var now: Date { deps.clock() }

    // MARK: - Lifecycle

    /// Run once at daemon start, before accepting clients.
    @discardableResult
    public func reconcile() -> ReconcileDecision {
        let journal: Journal?
        do { journal = try deps.store.load() } catch {
            record("journal unreadable (\(error)); assuming Panther changed sleep, restoring")
            sleepDisabledByUs = true
            restoreSleep(reason: .reconcileExpired)
            return .restore(dropped: [])
        }
        lowPowerByUs = journal?.lowPowerSetByPanther ?? false
        let decision = Reconciler.decide(journal: journal, sleepDisabledNow: deps.sleep.readSleepDisabled(),
                                         currentBoot: deps.bootSessionUUID, now: now, inspector: deps.inspector)
        apply(decision)
        applyLowPowerPolicy()
        return decision
    }

    private func apply(_ decision: ReconcileDecision) {
        switch decision {
        case .nothing:
            record("reconcile: clean")
        case .foreignSleepDisabled:
            foreignSleepDisabled = true
            record("reconcile: SleepDisabled is on but Panther didn't set it; leaving it alone")
        case .resume(let valid):
            record("reconcile: resuming \(valid.count) session(s)")
            sleepDisabledByUs = true
            holds = valid
            reassertSleepDisabled()
            persist()
        case .restore(let dropped):
            record("reconcile: \(dropped.count) expired session(s), restoring sleep")
            sleepDisabledByUs = true
            restoreSleep(reason: .reconcileExpired)
        }
        onChange?()
    }

    /// Daemon is being stopped by launchd (uninstall, shutdown): never leave sleep disabled.
    public func shutdown() {
        guard sleepDisabledByUs else { return }
        holds = []
        restoreSleep(reason: .daemonStopped)
    }

    // MARK: - Client requests

    public func start(_ request: HoldRequest, owner: UInt32? = nil) throws(PantherError) -> Hold {
        guard holds.count < Self.maxHolds else { throw .invalidRequest("too many sessions (max \(Self.maxHolds))") }
        let hold = try makeHold(request, owner: owner)
        if let reason = policy.evaluate(environment, heavySince: heavySince, now: now) {
            throw .invalidRequest("refused: \(Self.describe(reason)) right now")
        }
        try add(hold)
        applyLowPowerPolicy()
        record("started \(hold.label) until \(hold.endsAt.formatted(date: .omitted, time: .shortened))")
        onChange?()
        return hold
    }

    /// Extends one hold, or the newest timed hold (else newest hold) when `id` is nil.
    public func extend(id: UUID?, by seconds: TimeInterval, caller: UInt32? = nil) throws(PantherError) -> Hold {
        guard seconds >= Durations.minimum else { throw .invalidRequest("extend by at least 1 minute") }
        let mine = holds.filter { $0.isControllable(by: caller) }
        let target = id.map { id in mine.first { $0.id == id } } ?? (mine.last { $0.process == nil } ?? mine.last)
        guard let target else { throw .noSuchHold }
        let newEnd = max(target.endsAt, now).addingTimeInterval(seconds)
        guard newEnd.timeIntervalSince(now) <= deps.limits.maxHold else {
            throw .invalidRequest("that would go past the \(Durations.format(deps.limits.maxHold)) limit")
        }
        let updated = target.extended(to: newEnd)
        holds = holds.map { $0.id == updated.id ? updated : $0 }
        persist()
        record("extended \(updated.label) to \(newEnd.formatted(date: .omitted, time: .shortened))")
        onChange?()
        return updated
    }

    /// Ends one hold, or all of the caller's holds when `id` is nil. Root (nil/0) may end any.
    public func end(id: UUID?, caller: UInt32? = nil, reason: EndReason = .userEnded) throws(PantherError) {
        let mine = holds.filter { $0.isControllable(by: caller) }
        let ids = id.map { [$0] } ?? mine.map(\.id)
        guard !ids.isEmpty, ids.allSatisfy({ id in mine.contains { $0.id == id } }) else { throw .noSuchHold }
        remove(ids: Set(ids), reason: reason)
    }

    // MARK: - Events from the system

    public func processExited(pid: Int32) {
        let ended = holds.filter { hold in
            guard let process = hold.process, process.pid == pid else { return false }
            return !deps.inspector.isAlive(process)
        }
        guard !ended.isEmpty else { return }
        remove(ids: Set(ended.map(\.id)), reason: .processExited)
    }

    /// A login-session client saw (or didn't see) an external display. Expires, so a stale or
    /// spoofed `true` can't switch off the closed-lid rules for long.
    public func reportExternalDisplay(_ inUse: Bool) {
        displayReportedAt = now
        update(environment.with(externalDisplay: .some(inUse)))
    }

    private func expireDisplayReport() {
        guard let at = displayReportedAt, now.timeIntervalSince(at) > Self.displayReportLifetime else { return }
        displayReportedAt = nil
        update(environment.with(externalDisplay: .some(nil)))
    }

    public func update(_ env: Environment) {
        let lidChanged = env.lidClosed != environment.lidClosed
        environment = env
        heavySince = policy.heavySince(previous: heavySince, env: env, now: now)
        if lidChanged { record(env.lidClosed ? "lid closed" : "lid opened") }
        enforceSafety()
        applyLowPowerPolicy()
    }

    /// Periodic check: deadlines, dead processes (missed exit events), safety, stuck restores.
    public func tick() {
        expireDisplayReport()
        // Retry a failed restore, but only while nothing needs sleep disabled any more.
        if stuck != nil, holds.isEmpty { restoreSleep(reason: stuckReason ?? .deadline) }
        let current = now
        let expired = holds.filter { $0.endsAt <= current }
        if !expired.isEmpty { remove(ids: Set(expired.map(\.id)), reason: .deadline) }
        let dead = holds.filter { hold in hold.process.map { !deps.inspector.isAlive($0) } ?? false }
        if !dead.isEmpty { remove(ids: Set(dead.map(\.id)), reason: .processExited) }
        if !holds.isEmpty, deps.sleep.readSleepDisabled() == false {
            record("SleepDisabled was turned off by something else; turning it back on")
            reassertSleepDisabled()
        }
        enforceSafety()
        applyLowPowerPolicy()
    }

    public var nextDeadline: Date? { holds.map(\.endsAt).min() }

    public func status() -> DaemonStatus {
        DaemonStatus(now: now, holds: holds, environment: environment,
                     sleepDisabled: deps.sleep.readSleepDisabled(), sleepDisabledByPanther: sleepDisabledByUs,
                     foreignSleepDisabled: foreignSleepDisabled, stuck: stuck, limits: deps.limits, events: events,
                     lowPowerOn: deps.lowPower.isLowPowerOn(), lowPowerByPanther: lowPowerByUs)
    }

    // MARK: - Helpers

    private func makeHold(_ request: HoldRequest, owner: UInt32?) throws(PantherError) -> Hold {
        let start = now
        switch request {
        case let .timed(duration, rawLabel):
            let label = Hold.sanitizedLabel(rawLabel)
            guard duration >= Durations.minimum else { throw .invalidRequest("duration must be at least 1 minute") }
            guard duration <= deps.limits.maxHold else {
                throw .invalidRequest("the longest session is \(Durations.format(deps.limits.maxHold))")
            }
            return Hold(kind: .timed, label: label, startedAt: start, endsAt: start.addingTimeInterval(duration),
                        ownerUID: owner)
        case let .untilExit(pid, cap, rawLabel):
            let label = Hold.sanitizedLabel(rawLabel)
            guard let identity = deps.inspector.identity(of: pid) else { throw .processNotFound(pid) }
            let limit = min(cap ?? deps.limits.defaultRunCap, deps.limits.maxHold)
            guard limit >= Durations.minimum else { throw .invalidRequest("--max must be at least 1 minute") }
            return Hold(kind: .untilExit(identity), label: label, startedAt: start,
                        endsAt: start.addingTimeInterval(limit), ownerUID: owner)
        }
    }

    private func enforceSafety() {
        guard !holds.isEmpty, let reason = policy.evaluate(environment, heavySince: heavySince, now: now) else { return }
        record("safety: \(Self.describe(reason)); ending all sessions")
        remove(ids: Set(holds.map(\.id)), reason: reason)
    }

    func record(_ message: String) {
        deps.log(message)
        events = Array((events + [PantherEvent(date: now, message: message)]).suffix(Self.maxEvents))
    }

    public static func describe(_ reason: EndReason) -> String {
        switch reason {
        case .deadline: "time is up"
        case .processExited: "the program finished"
        case .userEnded: "ended by you"
        case .batteryFloor: "battery is low"
        case .criticalHeat: "the Mac is critically hot"
        case .bagHeat: "the Mac has been hot with the lid closed for too long (in a bag?)"
        case .daemonStopped: "Panther stopped"
        case .reconcileExpired: "the session expired while Panther wasn't running"
        }
    }
}
