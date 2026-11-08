import Darwin
import Foundation
import PantherCore

/// Process identity from the kernel: PID plus start time to the microsecond.
public struct DarwinProcessInspector: ProcessInspector {
    public init() {}

    public func identity(of pid: Int32) -> ProcessIdentity? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // A zombie has exited even though its PID still answers.
        guard info.pbi_status != UInt32(SZOMB) else { return nil }
        let micros = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
        return ProcessIdentity(pid: pid, startMicros: micros)
    }

    /// Real user ID that owns `pid`, or nil if it isn't running.
    public static func ownerUID(of pid: Int32) -> uid_t? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_ruid
    }
}

public enum BootSession {
    /// `kern.bootsessionuuid`: changes on every boot.
    public static func uuid() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
