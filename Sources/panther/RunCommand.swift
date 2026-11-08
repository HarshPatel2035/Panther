import Darwin
import Foundation
import PantherCore
import PantherIPC

/// `panther run [--max 8h] -- cmd args...`: keep the Mac awake until `cmd` exits.
/// The child shares our terminal and process group; we exit with its status.
enum RunCommand {
    static func run(command: [String], cap: TimeInterval?, client: PantherClient, context: ClientContext) -> Int32 {
        guard let pid = spawn(command) else { return 127 }

        // Ctrl-C reaches the child directly (same process group); we keep waiting for it.
        signal(SIGINT, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        forwardTermination(to: pid)

        // Only the program name: arguments can hold tokens or passwords, and labels end up in logs.
        let name = URL(fileURLWithPath: command[0]).lastPathComponent
        let label = command.count > 1 ? "\(name) …" : name
        var holdID: UUID?
        do {
            let reply = try client.send(.start(.untilExit(pid: pid, cap: cap, label: label)), context: context)
            if let error = reply.error { throw error }
            holdID = reply.hold?.id
            if let hold = reply.hold {
                note("keeping the Mac awake until it exits (at most until \(Output.time(hold.endsAt))); you can close the lid")
            }
        } catch PantherError.processNotFound {
            // The command finished before the daemon could look at it: nothing to keep awake for.
        } catch {
            note("NOT keeping the Mac awake: \(error)")
        }

        let status = waitForExit(pid)
        if let holdID {
            // The daemon usually noticed already; ending again is harmless.
            _ = try? client.send(.end(id: holdID), context: context)
        }
        return status
    }

    private static func spawn(_ command: [String]) -> pid_t? {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let result = posix_spawnp(&pid, command[0], nil, nil, argv, environ)
        guard result == 0 else {
            note("can't run \(command[0]): \(String(cString: strerror(result)))")
            return nil
        }
        return pid
    }

    private static func forwardTermination(to pid: pid_t) {
        for sig in [SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { kill(pid, sig) }
            source.resume()
            SignalSources.keep(source)
        }
    }

    private static func waitForExit(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            guard errno == EINTR else { return 1 }
        }
        let low = status & 0x7f
        if low == 0 { return (status >> 8) & 0xff }   // exited normally
        return 128 + low                                // killed by a signal
    }

    static func note(_ message: String) {
        FileHandle.standardError.write(Data("panther: \(message)\n".utf8))
    }
}

private enum SignalSources {
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []
    static func keep(_ s: DispatchSourceSignal) { sources.append(s) }
}
