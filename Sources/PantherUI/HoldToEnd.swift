import AppKit
import Observation
import SwiftUI

/// Press-and-hold state for the end button. Lives in an @Observable object (not @State) because the
/// Command Line Tools don't ship SwiftUI's macro plugin.
@MainActor
@Observable
final class HoldToEndState {
    static let duration: Double = 2
    private(set) var progress: Double = 0
    private(set) var isPressing = false
    private var completed = false

    func begin() {
        completed = false
        isPressing = true
        withAnimation(.linear(duration: Self.duration)) { progress = 1 }
    }

    func release() {
        isPressing = false
        guard !completed else { return }
        withAnimation(.easeOut(duration: 0.25)) { progress = 0 }
    }

    func complete() {
        completed = true
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeOut(duration: 0.3)) { self.progress = 0 }
        }
    }
}

/// A capsule that fills over 2 seconds while pressed; letting go early cancels.
struct HoldToEndButton: View {
    let state: HoldToEndState
    let title: String
    let onComplete: () -> Void

    var body: some View {
        ZStack {
            Capsule().fill(Theme.danger.opacity(0.16))
            GeometryReader { geo in
                Capsule()
                    .fill(Theme.danger.opacity(0.85))
                    .frame(width: max(0, geo.size.width * state.progress))
            }
            Label(state.isPressing ? "Keep holding…" : title, systemImage: "stop.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(height: 34)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Theme.danger.opacity(0.5), lineWidth: 1))
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: HoldToEndState.duration, maximumDistance: 40) {
            state.complete()
            onComplete()
        } onPressingChanged: { pressing in
            pressing ? state.begin() : state.release()
        }
        .help("Press and hold for 2 seconds to end")
        .accessibilityLabel(title)
        .accessibilityAction(named: Text(title)) { onComplete() }
    }
}
