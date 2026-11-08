import PantherUI
import SwiftUI

@main
struct PantherMenuBarApp: App {
    // Plain property, not @State: the Command Line Tools don't ship SwiftUI's macro plugin.
    // The App value is created once, and AppModel is @Observable, so views still update.
    private let model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            // Paw print, filled while awake, with the countdown (H:MM:SS) next to it.
            HStack(spacing: 4) {
                Image(systemName: model.hasProblem ? "exclamationmark.triangle.fill"
                                  : model.isActive ? "pawprint.fill" : "pawprint")
                if let clock = model.clockText {
                    Text(clock).monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
