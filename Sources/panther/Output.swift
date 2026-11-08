import Foundation
import PantherCore

enum Output {
    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    static func describe(_ hold: Hold, now: Date) -> String {
        let remaining = Durations.format(hold.endsAt.timeIntervalSince(now))
        switch hold.kind {
        case .timed:
            return "\(hold.label): ends \(time(hold.endsAt)) (in \(remaining))"
        case .untilExit(let p):
            return "\(hold.label) (pid \(p.pid)): until it exits, at most until \(time(hold.endsAt)) (in \(remaining))"
        }
    }

    static func summary(_ s: DaemonStatus) -> String {
        var lines: [String] = []
        if s.holds.isEmpty {
            lines.append("Panther: idle. The Mac sleeps normally when the lid closes.")
        } else {
            let guardOK = s.sleepDisabled == true ? "lid-close sleep is blocked" : "WARNING: SleepDisabled reads \(flag(s.sleepDisabled))"
            lines.append("Panther: awake, \(s.holds.count) session\(s.holds.count == 1 ? "" : "s"), \(guardOK)")
            lines += s.holds.map { "  • " + describe($0, now: s.now) }
        }
        lines.append(environment(s.environment))
        if s.lowPowerByPanther { lines.append("Low Power Mode: on (Panther turned it on; it goes off with the session)") }
        if let stuck = s.stuck { lines.append("PROBLEM: \(stuck)") }
        if s.foreignSleepDisabled, s.holds.isEmpty, s.sleepDisabled == true {
            lines.append("Note: sleep is disabled by another tool, not Panther (`sudo pmset -a disablesleep 0` resets it).")
        }
        return lines.joined(separator: "\n")
    }

    static func environment(_ e: Environment) -> String {
        let lid = e.lidClosed ? "closed" : "open"
        let display = e.externalDisplay.map { $0 ? ", external display in use" : "" } ?? ""
        let power = e.power.map { p in
            let pct = p.percent.map { "\($0)%" } ?? "?"
            return "battery \(pct) \(p.onBattery ? "on battery" : "on power")"
        } ?? "no battery"
        return "Lid \(lid)\(display) · \(power) · heat \(e.thermal)"
    }

    static func flag(_ value: Bool?) -> String { value.map { $0 ? "1" : "0" } ?? "unreadable" }

    static func json(_ status: DaemonStatus) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(status)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
