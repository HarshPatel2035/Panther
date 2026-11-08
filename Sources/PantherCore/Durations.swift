import Foundation

public enum DurationError: Error, Equatable, CustomStringConvertible {
    case empty
    case invalid(String)
    case tooShort

    public var description: String {
        switch self {
        case .empty: "no duration given"
        case .invalid(let s): "can't read duration \"\(s)\"; use forms like 90m, 2h, 1h30m, 45s"
        case .tooShort: "duration must be at least 1 minute"
        }
    }
}

/// Parses and formats durations like `2h`, `1h30m`, `90m`, `45s`, `1d`. A bare number means minutes.
public enum Durations {
    private static let units: [Character: TimeInterval] = ["d": 86_400, "h": 3_600, "m": 60, "s": 1]
    public static let minimum: TimeInterval = 60

    public static func parse(_ text: String) throws(DurationError) -> TimeInterval {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { throw .empty }
        if let minutes = Int(s) { return try validated(TimeInterval(minutes) * 60) }

        var total: TimeInterval = 0
        var digits = ""
        var lastUnitRank = Int.max
        let ranks: [Character: Int] = ["d": 3, "h": 2, "m": 1, "s": 0]
        for ch in s {
            if ch.isASCII, ch.isNumber {
                digits.append(ch)
                continue
            }
            guard let unit = units[ch], let rank = ranks[ch], rank < lastUnitRank,
                  let value = Int(digits) else { throw .invalid(text) }
            total += TimeInterval(value) * unit
            digits = ""
            lastUnitRank = rank
        }
        guard digits.isEmpty else { throw .invalid(text) }
        return try validated(total)
    }

    private static func validated(_ t: TimeInterval) throws(DurationError) -> TimeInterval {
        guard t >= minimum else { throw .tooShort }
        return t
    }

    /// `3725` → `1h 2m`, `45` → `45s`. For humans, so seconds are dropped above one hour.
    public static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let d = total / 86_400, h = (total % 86_400) / 3_600, m = (total % 3_600) / 60, s = total % 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d)d") }
        if h > 0 { parts.append("\(h)h") }
        if m > 0 { parts.append("\(m)m") }
        if total < 3_600, s > 0 || parts.isEmpty { parts.append("\(s)s") }
        return parts.joined(separator: " ")
    }
}
