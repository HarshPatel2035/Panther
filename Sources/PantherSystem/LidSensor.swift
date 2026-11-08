import Foundation
import IOKit

/// Lid state from `IOPMrootDomain`'s `AppleClamshellState`, pushed by IOKit interest notifications.
@MainActor
public final class LidSensor {
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var service: io_service_t = 0
    private var onChange: ((Bool) -> Void)?
    private var last: Bool?

    public init() {}

    public static func isClosed() -> Bool {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }
        let value = IORegistryEntryCreateCFProperty(svc, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    /// Calls `handler` with the current state, then on every change.
    public func start(_ handler: @escaping (Bool) -> Void) throws {
        onChange = handler
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw SensorError.unavailable("IOPMrootDomain")
        }
        self.port = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { refcon, _, _, _ in
            guard let refcon else { return }
            let sensor = Unmanaged<LidSensor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { sensor.refresh() }
        }, context, &notifier)
        guard result == KERN_SUCCESS else { throw SensorError.unavailable("lid notifications (\(result))") }
        refresh()
    }

    private func refresh() {
        let closed = Self.isClosed()
        guard closed != last else { return }
        last = closed
        onChange?(closed)
    }

    isolated deinit {
        if notifier != 0 { IOObjectRelease(notifier) }
        if service != 0 { IOObjectRelease(service) }
        if let port { IONotificationPortDestroy(port) }
    }
}

public enum SensorError: Error, CustomStringConvertible {
    case unavailable(String)
    public var description: String {
        if case .unavailable(let what) = self { return "\(what) unavailable" }
        return "sensor error"
    }
}
