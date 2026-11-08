import CoreGraphics
import Darwin
import notify
import Foundation
import IOKit.ps
import PantherCore

/// Battery percent and charger state, pushed by IOPowerSources notifications.
@MainActor
public final class PowerSourceSensor {
    private var source: CFRunLoopSource?
    private var onChange: ((PowerSnapshot?) -> Void)?

    public init() {}

    public static func snapshot() -> PowerSnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let onBattery = d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return PowerSnapshot(onBattery: onBattery, percent: d[kIOPSCurrentCapacityKey] as? Int)
        }
        return nil   // a desktop Mac: no battery rules apply
    }

    public func start(_ handler: @escaping (PowerSnapshot?) -> Void) {
        onChange = handler
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let loopSource = IOPSNotificationCreateRunLoopSource({ refcon in
            guard let refcon else { return }
            let sensor = Unmanaged<PowerSourceSensor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { sensor.onChange?(PowerSourceSensor.snapshot()) }
        }, context)?.takeRetainedValue() else { return }
        source = loopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .defaultMode)
        handler(Self.snapshot())
    }
}

/// Thermal pressure from `com.apple.system.thermalpressurelevel`. Battery temperature isn't
/// exposed on macOS 27 / Apple silicon laptops (reads 0), so this is Panther's heat signal.
@MainActor
public final class ThermalSensor {
    // NOTIFY_TOKEN_INVALID is a C macro Swift does not import.
    private static let invalidToken: Int32 = -1
    private var token: Int32 = ThermalSensor.invalidToken
    private static let name = "com.apple.system.thermalpressurelevel"

    public init() {}

    public static func level(token: Int32? = nil) -> ThermalLevel {
        var t = token ?? invalidToken
        var registered = false
        if t == invalidToken {
            guard notify_register_check(name, &t) == NOTIFY_STATUS_OK else { return .nominal }
            registered = true
        }
        defer { if registered { notify_cancel(t) } }
        var state: UInt64 = 0
        guard notify_get_state(t, &state) == NOTIFY_STATUS_OK else { return .nominal }
        return ThermalLevel(rawValue: Int(min(state, 4))) ?? .nominal
    }

    public func start(_ handler: @escaping (ThermalLevel) -> Void) {
        let status = notify_register_dispatch(Self.name, &token, .main) { token in
            MainActor.assumeIsolated { handler(ThermalSensor.level(token: token)) }
        }
        handler(status == NOTIFY_STATUS_OK ? Self.level(token: token) : Self.level())
    }
}

/// Is an external display in use? Run in the user's login session (CLI, menu bar app); a root daemon
/// can't rely on a WindowServer connection, so clients report this to pantherd.
public enum DisplayProbe {
    public static func externalDisplayActive() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsActive($0) != 0 }
    }
}
