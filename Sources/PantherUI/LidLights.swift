import CoreGraphics
import Foundation
import PantherSystem

/// Turns the built-in screen and keyboard light off while the lid is closed during a session,
/// and puts them back when it opens. With sleep disabled, macOS no longer does this itself, so the
/// panel would stay lit inside the closed lid.
///
/// Same rules as the daemon: save before changing (UserDefaults, survives a crash or relaunch),
/// and only restore what was saved.
@MainActor
final class LidLights {
    struct KeyboardState: Codable, Equatable {
        let id: UInt64
        let brightness: Float
        let auto: Bool
    }

    struct Saved: Codable, Equatable {
        let display: UInt32?
        let displayBrightness: Float?
        let keyboards: [KeyboardState]
    }

    private static let defaultsKey = "panther.savedLights"
    /// Never restore "off": a panel at 0 looks broken (Insomnia #121).
    static let minimumRestore: Float = 0.05
    static let fallbackRestore: Float = 0.5
    /// A brightness reading is trusted for this long (lid open, panel awake).
    static let sampleLifetime: TimeInterval = 10 * 60

    private let keyboard = KeyboardBacklight()
    private let defaults: UserDefaults
    private var lastSample: (display: CGDirectDisplayID, value: Float, at: Date)?
    private(set) var log: [String] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isDimmed: Bool { saved != nil }

    /// Remember the user's real brightness while the lid is open. Once it closes, the covered light
    /// sensor makes the reading wrong, so this is what gets restored.
    func sample() {
        guard let display = DisplayBacklight.builtInDisplay(), !DisplayBacklight.isAsleep(display),
              let value = DisplayBacklight.brightness(of: display), value >= Self.minimumRestore else { return }
        lastSample = (display, value, Date())
    }

    /// Lid closed during a session with nobody looking: lights off.
    func dim() {
        guard saved == nil else { return }
        let display = DisplayBacklight.builtInDisplay() ?? lastSample?.display
        let fresh = lastSample.flatMap { Date().timeIntervalSince($0.at) < Self.sampleLifetime ? $0.value : nil }
        let displayValue = fresh ?? display.flatMap { DisplayBacklight.brightness(of: $0) }
        let keyboards = keyboard.builtInKeyboards().map { id in
            KeyboardState(id: id, brightness: keyboard.brightness(id) ?? 0, auto: keyboard.isAutoBrightness(id) ?? true)
        }
        saved = Saved(display: display, displayBrightness: displayValue, keyboards: keyboards)   // write-ahead

        if let display { DisplayBacklight.setBrightness(0, of: display) }
        for kb in keyboards {
            keyboard.setAutoBrightness(false, kb.id)   // covered sensor reads "dark" and would light it up
            keyboard.setBrightness(0, kb.id)
        }
        note("lid closed: screen and keyboard light off")
    }

    /// Lid open (or app relaunched with a saved state): put everything back.
    func restore() {
        guard let saved else { return }
        if let display = saved.display ?? DisplayBacklight.builtInDisplay() {
            let value = saved.displayBrightness.map { $0 >= Self.minimumRestore ? $0 : Self.fallbackRestore } ?? Self.fallbackRestore
            DisplayBacklight.setBrightness(value, of: display)
        }
        for kb in saved.keyboards {
            keyboard.setBrightness(kb.brightness, kb.id)
            keyboard.setAutoBrightness(kb.auto, kb.id)
        }
        self.saved = nil
        note("lid opened: screen and keyboard light restored")
    }

    private var saved: Saved? {
        get { defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.defaultsKey)
            } else {
                defaults.removeObject(forKey: Self.defaultsKey)
            }
        }
    }

    private func note(_ message: String) {
        log = Array((log + ["\(Date().formatted(date: .omitted, time: .standard))  \(message)"]).suffix(10))
    }
}
