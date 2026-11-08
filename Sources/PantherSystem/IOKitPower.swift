import Foundation
import IOKit
import IOKit.pwr_mgt
import PantherCore

// Private IOKit power APIs. Found as imports of /usr/bin/pmset (docs/03-re-findings.md),
// verified on macOS 27.0.1: setting needs root, reading doesn't.
@_silgen_name("IOPMCopySystemPowerSettings")
private func IOPMCopySystemPowerSettings() -> Unmanaged<CFDictionary>?

@_silgen_name("IOPMSetSystemPowerSetting")
private func IOPMSetSystemPowerSetting(_ key: CFString, _ value: CFTypeRef) -> IOReturn

/// `SleepDisabled`, the switch behind `pmset -a disablesleep`.
public struct IOKitSleepControl: SleepControl {
    private static let key = "SleepDisabled"

    public init() {}

    public func setSleepDisabled(_ disabled: Bool) throws(PantherError) {
        let value: CFBoolean = disabled ? kCFBooleanTrue : kCFBooleanFalse
        let result = IOPMSetSystemPowerSetting(Self.key as CFString, value)
        if result == kIOReturnNotPrivileged { throw .notPrivileged }
        guard result == kIOReturnSuccess else {
            throw .ioKit(operation: "IOPMSetSystemPowerSetting(SleepDisabled)", code: result)
        }
    }

    public func readSleepDisabled() -> Bool? {
        guard let settings = IOPMCopySystemPowerSettings()?.takeRetainedValue() as? [String: Any] else { return nil }
        return (settings[Self.key] as? NSNumber)?.boolValue
    }
}

/// `IOPMSleepSystem`, the call behind `pmset sleepnow`.
public struct IOKitSystemSleeper: SystemSleeper {
    public init() {}

    public func sleepNow() throws(PantherError) {
        let port = IOPMFindPowerManagement(kIOMainPortDefault)
        guard port != 0 else { throw .ioKit(operation: "IOPMFindPowerManagement", code: -1) }
        defer { IOServiceClose(port) }
        let result = IOPMSleepSystem(port)
        guard result == kIOReturnSuccess else { throw .ioKit(operation: "IOPMSleepSystem", code: result) }
    }
}
