import Foundation
import PantherCore

/// Turns the controller's state into wake-ups: an exact deadline timer, a periodic safety tick,
/// and a kqueue exit watch per process hold. No busy polling.
@MainActor
final class Scheduler {
    static let tickInterval: TimeInterval = 15

    private let controller: HoldController
    private var deadlineTimer: DispatchSourceTimer?
    private var tickTimer: DispatchSourceTimer?
    private var processWatches: [Int32: DispatchSourceProcess] = [:]

    init(controller: HoldController) {
        self.controller = controller
    }

    func start() {
        let tick = DispatchSource.makeTimerSource(queue: .main)
        tick.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval, leeway: .seconds(2))
        tick.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.controller.tick() } }
        tick.resume()
        tickTimer = tick
        refresh()
    }

    /// Call after any change to the holds.
    func refresh() {
        armDeadline()
        syncProcessWatches()
    }

    private func armDeadline() {
        deadlineTimer?.cancel()
        deadlineTimer = nil
        guard let deadline = controller.nextDeadline else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Wall-clock deadline: still correct after the Mac slept or the clock was changed (Insomnia #119).
        timer.schedule(wallDeadline: Self.wallTime(deadline), leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.controller.tick() } }
        timer.resume()
        deadlineTimer = timer
    }

    private func syncProcessWatches() {
        let wanted = Set(controller.holds.compactMap { $0.process?.pid })
        for (pid, source) in processWatches where !wanted.contains(pid) {
            source.cancel()
            processWatches[pid] = nil
        }
        for pid in wanted where processWatches[pid] == nil {
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.controller.processExited(pid: pid) }
            }
            source.resume()
            processWatches[pid] = source
            // The process may have exited before the watch existed. Check on the next turn of the
            // queue, not here: ending a hold calls back into refresh() and we're mid-update.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.controller.processExited(pid: pid) }
            }
        }
    }

    static func wallTime(_ date: Date) -> DispatchWallTime {
        let seconds = max(0, date.timeIntervalSince1970)
        let whole = seconds.rounded(.down)
        let spec = timespec(tv_sec: Int(whole), tv_nsec: Int((seconds - whole) * 1_000_000_000))
        return DispatchWallTime(timespec: spec)
    }
}
