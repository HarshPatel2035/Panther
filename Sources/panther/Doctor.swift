import Foundation
import PantherCore
import PantherIPC
import PantherSystem

/// `panther doctor`: checks the claims, not just the state. Exit 0 = all good.
enum Doctor {
    static func run(client: PantherClient, context: ClientContext) -> Int32 {
        var problems = 0
        func check(_ ok: Bool, _ good: String, _ bad: String) {
            print(ok ? "  ✓ \(good)" : "  ✗ \(bad)")
            if !ok { problems += 1 }
        }

        print("Install")
        let fm = FileManager.default
        check(fm.fileExists(atPath: "/Library/PrivilegedHelperTools/com.panther.daemon"),
              "daemon installed", "daemon binary missing: run scripts/install.sh")
        check(fm.fileExists(atPath: "/Library/LaunchDaemons/com.panther.daemon.plist"),
              "LaunchDaemon registered", "LaunchDaemon plist missing: run scripts/install.sh")
        check(!fm.fileExists(atPath: "/etc/sudoers.d/insomnia"),
              "no Insomnia sudoers rule", "Insomnia is still installed; it fights Panther over SleepDisabled. Uninstall it")

        print("Daemon")
        let reply: DaemonReply
        do { reply = try client.send(.status, context: context) } catch {
            check(false, "", "\(error)")
            return 1
        }
        guard let s = reply.status else { check(false, "", "daemon sent no status"); return 1 }
        check(true, "pantherd answers over XPC (signature check passed)", "")
        check(s.stuck == nil, "no failed restore", "restore problem: \(s.stuck ?? "")")

        print("Sleep guard")
        let expected = !s.holds.isEmpty
        check(s.sleepDisabled == expected,
              "SleepDisabled reads \(Output.flag(s.sleepDisabled)), as expected \(expected ? "during a session" : "when idle")",
              "SleepDisabled reads \(Output.flag(s.sleepDisabled)) but should be \(expected ? 1 : 0)")
        if s.foreignSleepDisabled { print("  ! another tool disabled sleep before Panther started") }

        print("Machine")
        print("  " + Output.environment(s.environment))
        print("  external display (seen from your session): \(context.externalDisplay == true ? "yes" : "no")")

        print("Recent events")
        for event in s.events.suffix(8) { print("  \(Output.time(event.date))  \(event.message)") }

        print(problems == 0 ? "\nAll good." : "\n\(problems) problem(s) found.")
        return problems == 0 ? 0 : 1
    }
}
