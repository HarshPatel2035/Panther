import Foundation
import PantherCore

/// Low Power Mode on the battery profile via /usr/bin/pmset (run by the root daemon, no sudo).
/// The setting has been named `lowpowermode` and `powermode` on different macOS releases
/// (Insomnia #69), so try both, then confirm with the system's own flag rather than parsing output.
public struct PmsetLowPowerControl: LowPowerControl {
    private static let pmset = URL(fileURLWithPath: "/usr/bin/pmset")
    private static let names = ["lowpowermode", "powermode"]
    private static let timeout: TimeInterval = 5

    public init() {}

    public func setLowPower(_ enabled: Bool) throws(PantherError) {
        var lastStatus: Int32 = -1
        for name in Self.names {
            lastStatus = Self.run(["-b", name, enabled ? "1" : "0"])
            if lastStatus == 0 { return }
        }
        throw .ioKit(operation: "pmset -b lowpowermode \(enabled ? 1 : 0)", code: lastStatus)
    }

    public func isLowPowerOn() -> Bool? {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private static func run(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = pmset
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return -2
        }
        return process.terminationStatus
    }
}
