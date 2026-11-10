import Foundation
import Observation
import PantherCore
import SwiftUI

/// Days / hours / minutes for a custom session. @Observable instead of @State (no SwiftUI macro
/// plugin in the Command Line Tools).
@MainActor
@Observable
final class CustomDuration {
    static let maxDays = 7
    var days = 0 { didSet { if days != Self.clamp(days, 0, Self.maxDays) { days = Self.clamp(days, 0, Self.maxDays) } } }
    var hours = 2 { didSet { if hours != Self.clamp(hours, 0, 23) { hours = Self.clamp(hours, 0, 23) } } }
    var minutes = 0 { didSet { if minutes != Self.clamp(minutes, 0, 59) { minutes = Self.clamp(minutes, 0, 59) } } }

    var seconds: TimeInterval { TimeInterval(days * 86_400 + hours * 3_600 + minutes * 60) }

    /// Why it can't start yet, or nil when it can.
    func problem(maxHold: TimeInterval) -> String? {
        if seconds < Durations.minimum { return "Set at least 1 minute" }
        if seconds > maxHold { return "The longest session is \(Durations.format(maxHold))" }
        return nil
    }

    private static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}

/// The "Custom" row: three small number fields with steppers, then a full-width start button
/// that says exactly what will happen.
struct CustomDurationRow: View {
    let model: AppModel

    private var custom: CustomDuration { model.custom }
    private var maxHold: TimeInterval { model.status?.limits.maxHold ?? Limits.standard.maxHold }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CUSTOM")
                .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 6) {
                UnitField(value: Binding(get: { custom.days }, set: { custom.days = $0 }),
                          unit: "d", range: 0...CustomDuration.maxDays, preview: model.isPreview)
                UnitField(value: Binding(get: { custom.hours }, set: { custom.hours = $0 }),
                          unit: "h", range: 0...23, preview: model.isPreview)
                UnitField(value: Binding(get: { custom.minutes }, set: { custom.minutes = $0 }),
                          unit: "m", range: 0...59, preview: model.isPreview)
            }
            let problem = custom.problem(maxHold: maxHold)
            Button {
                model.start(for: custom.seconds)
            } label: {
                Text(problem ?? "Start \(Durations.format(custom.seconds)) · until \(Self.endText(custom.seconds, now: model.now))")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .foregroundStyle(problem == nil ? Theme.deepNight : Theme.secondaryText)
                    .background(problem == nil ? Theme.gold : Theme.card, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .disabled(problem != nil)
        }
    }

    /// "5:45 PM" today, "Thu 5:45 PM" within a week.
    static func endText(_ seconds: TimeInterval, now: Date) -> String {
        let end = now.addingTimeInterval(seconds)
        if Calendar.current.isDate(end, inSameDayAs: now) { return end.formatted(date: .omitted, time: .shortened) }
        return end.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// One number + unit + stepper, styled as a small card.
private struct UnitField: View {
    let value: Binding<Int>
    let unit: String
    let range: ClosedRange<Int>
    let preview: Bool

    var body: some View {
        HStack(spacing: 3) {
            if preview {
                // ImageRenderer can't draw AppKit text fields or steppers: plain text for snapshots.
                Text("\(value.wrappedValue)").frame(width: 24, alignment: .trailing)
            } else {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 24)
            }
            Text(unit).foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 0)
            if !preview {
                Stepper("", value: value, in: range).labelsHidden().controlSize(.mini)
            }
        }
        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08)))
    }
}
