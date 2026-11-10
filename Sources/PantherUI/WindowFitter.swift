import AppKit
import SwiftUI

/// MenuBarExtra(.window) sizes its panel once and doesn't shrink it when the content gets smaller
/// (for example after a session ends while the panel is open), leaving the content floating in an
/// oversized window. This resizes the window to fit its content, keeping the top edge under the
/// menu bar. `token` should change whenever the layout's height can change.
struct WindowFitter: NSViewRepresentable {
    let token: Int

    final class Coordinator { var lastToken: Int? }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.lastToken != token else { return }
        context.coordinator.lastToken = token
        // After this layout pass, so fittingSize reflects the new content.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window, let content = window.contentView else { return }
            let fit = content.fittingSize
            guard fit.height > 1 else { return }
            let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: fit)).size
            guard abs(window.frame.height - target.height) > 0.5 else { return }
            var frame = window.frame
            let top = frame.maxY
            frame.size.height = target.height
            frame.origin.y = top - target.height
            window.setFrame(frame, display: true)
        }
    }
}
