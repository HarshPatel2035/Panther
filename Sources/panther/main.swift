import Foundation
import PantherCore
import PantherIPC
import PantherSystem

let usage = """
panther: keep your Mac running with the lid closed.

  panther run [--max 8h] -- <command> [args...]   awake until the command exits
  panther start <duration> [--label text]          awake for a set time (e.g. 2h, 1h30m, 90m)
  panther extend <duration>                        add time to the current session
  panther end                                      end every session now
  panther status [--json]                          what Panther is doing
  panther doctor                                   check that everything really works

Use it on a desk, not in a closed bag: Panther ends sessions on low battery and high heat.
"""

func die(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("panther: \(message)\n".utf8))
    exit(code)
}

func duration(_ text: String?) -> TimeInterval {
    guard let text else { die("missing duration\n\n\(usage)") }
    do { return try Durations.parse(text) } catch { die(error.description) }
}

let client = PantherClient()
let context = ClientContext(externalDisplay: DisplayProbe.externalDisplayActive())

/// Send a command; print the daemon's error (if any) and exit non-zero.
func call(_ command: DaemonCommand) -> DaemonReply {
    do {
        let reply = try client.send(command, context: context)
        if let error = reply.error { die(error.description, code: 1) }
        return reply
    } catch {
        die(error.description, code: 3)
    }
}

var args = Array(CommandLine.arguments.dropFirst())
let verb = args.isEmpty ? "status" : args.removeFirst()

switch verb {
case "run":
    var cap: TimeInterval?
    while let first = args.first, first != "--" {
        args.removeFirst()
        guard first == "--max" else { die("unknown option \(first) (put your command after --)") }
        cap = duration(args.isEmpty ? nil : args.removeFirst())
    }
    guard args.first == "--", args.count > 1 else { die("usage: panther run [--max 8h] -- <command> [args...]") }
    exit(RunCommand.run(command: Array(args.dropFirst()), cap: cap, client: client, context: context))

case "start":
    let seconds = duration(args.first)
    let label = args.firstIndex(of: "--label").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "timed session"
    let reply = call(.start(.timed(duration: seconds, label: label)))
    print("Awake until \(reply.hold.map { Output.time($0.endsAt) } ?? "?"). You can close the lid.")

case "extend":
    let reply = call(.extend(id: nil, by: duration(args.first)))
    print("Extended: now until \(reply.hold.map { Output.time($0.endsAt) } ?? "?").")

case "end", "stop":
    _ = call(.end(id: nil))
    print("Ended. Sleep is back to normal.")

case "status":
    let reply = call(.status)
    guard let status = reply.status else { die("daemon sent no status", code: 1) }
    print(args.contains("--json") ? Output.json(status) : Output.summary(status))

case "doctor":
    exit(Doctor.run(client: client, context: context))

case "help", "-h", "--help":
    print(usage)

default:
    die("unknown command \(verb)\n\n\(usage)")
}
