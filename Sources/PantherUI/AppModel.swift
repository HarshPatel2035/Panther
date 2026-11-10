import AppKit
import Foundation
import Observation
import PantherCore
import PantherIPC
import PantherSystem

/// The menu bar app's view of pantherd. The daemon owns every session; this is only a remote control,
/// so quitting the app never leaves sleep disabled and never ends a session.
@MainActor
@Observable
public final class AppModel {
    private(set) var status: DaemonStatus?
    private(set) var lastError: String?
    private(set) var busy = false
    /// Advances every second while a session is active (the countdown shows seconds); frozen when idle.
    private(set) var now = Date()

    let loginItem = LoginItem()
    let holdToEnd = HoldToEndState()
    let custom = CustomDuration()
    let lights = LidLights()
    private var lid: LidSensor?
    private(set) var lidClosed = false
    private let client = PantherClient()
    private var timer: Timer?
    private var ticker: Timer?
    static let refreshInterval: TimeInterval = 30

    /// Snapshot mode: fixed data, no daemon, no timers.
    let isPreview: Bool

    public init() {
        isPreview = false
        startLidWatch()
        refresh()
        // Every 30 s: refresh the countdown and re-report the display (the daemon trusts a report for 120 s).
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Fixed sample state for design snapshots: no daemon, no timers.
    public init(preview status: DaemonStatus) {
        isPreview = true
        self.status = status
        self.now = status.now
    }

    public var isActive: Bool { status?.isActive ?? false }
    var holds: [Hold] { status?.holds ?? [] }

    // MARK: - Lid: screen and keyboard light

    private func startLidWatch() {
        let sensor = LidSensor()
        do {
            try sensor.start { [weak self] closed in self?.lidChanged(closed: closed) }
            lid = sensor
        } catch {
            lastError = "can't watch the lid: \(error)"
        }
        // Relaunched after a crash with the lights still off and the lid open: put them back.
        if !LidSensor.isClosed() { lights.restore() }
    }

    private func lidChanged(closed: Bool) {
        lidClosed = closed
        if closed {
            if isActive, !DisplayProbe.externalDisplayActive() { lights.dim() }
        } else {
            lights.restore()
        }
        refresh()
    }

    /// The timed session that ends last: that's when the Mac may sleep again (if nothing else holds it).
    var countdownHold: Hold? { holds.filter { $0.process == nil }.max { $0.endsAt < $1.endsAt } }

    /// `1:23:45` left on the timed session; for "until an app quits" sessions, time elapsed so far.
    public var clockText: String? {
        guard isActive else { return nil }
        if let hold = countdownHold { return Self.clock(hold.endsAt.timeIntervalSince(now)) }
        guard let first = holds.min(by: { $0.startedAt < $1.startedAt }) else { return nil }
        return Self.clock(now.timeIntervalSince(first.startedAt))
    }

    var isCountingDown: Bool { countdownHold != nil }

    /// 0…1 of the timed session used up.
    var progress: Double {
        guard let hold = countdownHold else { return 0 }
        let total = hold.endsAt.timeIntervalSince(hold.startedAt)
        guard total > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(hold.startedAt) / total))
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d:%02d", s / 3_600, (s % 3_600) / 60, s % 60)
    }

    /// One-second ticks only while a session runs: idle costs nothing.
    private func updateTicker() {
        if isActive, ticker == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.now = Date() }
            }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)   // keeps ticking while the panel is open
            ticker = t
        } else if !isActive, let t = ticker {
            t.invalidate()
            ticker = nil
        }
    }

    public var hasProblem: Bool {
        lastError != nil || status?.stuck != nil || (isActive && status?.sleepDisabled != true)
    }

    // MARK: - Actions

    func refresh() {
        guard !isPreview else { return }
        if !lidClosed { lights.sample() }
        perform(.status, quietly: true)
    }

    func start(for seconds: TimeInterval) {
        perform(.start(.timed(duration: seconds, label: "\(Durations.format(seconds)) session")))
    }

    func startUntilQuit(_ app: NSRunningApplication) {
        let name = app.localizedName ?? "app"
        perform(.start(.untilExit(pid: app.processIdentifier, cap: nil, label: "until \(name) quits")))
    }

    func extend(by seconds: TimeInterval) { perform(.extend(id: nil, by: seconds)) }

    func end(_ id: UUID? = nil) { perform(.end(id: id)) }

    /// Runs the blocking XPC call off the main thread, then publishes the result.
    private func perform(_ command: DaemonCommand, quietly: Bool = false) {
        if !quietly { busy = true }
        let client = self.client
        let context = ClientContext(externalDisplay: DisplayProbe.externalDisplayActive())
        Task.detached {
            let outcome: Result<DaemonReply, PantherError>
            do throws(PantherError) { outcome = .success(try client.send(command, context: context)) } catch {
                outcome = .failure(error)
            }
            await MainActor.run { self.apply(outcome) }
        }
    }

    private func apply(_ outcome: Result<DaemonReply, PantherError>) {
        busy = false
        now = Date()
        switch outcome {
        case .success(let reply):
            if let status = reply.status { self.status = status }
            lastError = reply.error?.description
        case .failure(let error):
            lastError = error.description
        }
        updateTicker()
    }
}
