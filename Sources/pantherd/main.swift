import Foundation
import PantherCore
import PantherIPC
import PantherSystem

// pantherd: Panther's root daemon. The only process that touches SleepDisabled.
//   pantherd --client-requirement '<code requirement>' [--state-dir DIR]   (run by launchd)
//   pantherd --restore-only [--state-dir DIR]                             (used by uninstall)

struct Options {
    var clientRequirement: String?
    var stateDirectory = FileJournalStore.systemDirectory
    var restoreOnly = false

    static func parse(_ args: [String]) -> Options {
        var options = Options()
        var it = args.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--client-requirement": options.clientRequirement = it.next()
            case "--state-dir": if let dir = it.next() { options.stateDirectory = URL(fileURLWithPath: dir, isDirectory: true) }
            case "--restore-only": options.restoreOnly = true
            default: fail("unknown argument \(arg)")
            }
        }
        return options
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pantherd: \(message)\n".utf8))
    exit(1)
}

let log = Log()
let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
guard geteuid() == 0 else { fail("must run as root (it is started by launchd)") }

let controller = MainActor.assumeIsolated {
    HoldController(HoldControllerDependencies(
        sleep: IOKitSleepControl(), sleeper: IOKitSystemSleeper(),
        store: FileJournalStore(directory: options.stateDirectory), inspector: DarwinProcessInspector(),
        lowPower: PmsetLowPowerControl(),
        bootSessionUUID: BootSession.uuid(), log: { log.info($0) }))
}

if options.restoreOnly {
    MainActor.assumeIsolated {
        controller.reconcile()
        controller.shutdown()
        let status = controller.status()
        print("SleepDisabled now \(status.sleepDisabled.map { $0 ? "1" : "0" } ?? "unreadable")")
        exit(status.stuck == nil ? 0 : 1)
    }
}

guard let requirement = options.clientRequirement, !requirement.isEmpty else {
    fail("--client-requirement is required: pantherd only talks to Panther's own signed binaries")
}

MainActor.assumeIsolated {
    log.info("pantherd starting (pid \(getpid()), boot \(BootSession.uuid()))")
    let scheduler = Scheduler(controller: controller)
    controller.onChange = { scheduler.refresh() }

    // Seed the environment before reconcile, so "sleep now if the lid is closed" uses real data.
    controller.update(Environment(lidClosed: LidSensor.isClosed(), externalDisplay: nil,
                                  power: PowerSourceSensor.snapshot(), thermal: ThermalSensor.level()))
    controller.reconcile()

    let lid = LidSensor()
    do { try lid.start { closed in controller.update(controller.environment.with(lidClosed: closed)) } } catch {
        log.error("lid sensor: \(error); lid-based rules are off")
    }
    let power = PowerSourceSensor()
    power.start { snapshot in controller.update(controller.environment.with(power: .some(snapshot))) }
    let thermal = ThermalSensor()
    thermal.start { level in controller.update(controller.environment.with(thermal: level)) }
    scheduler.start()

    let service = DaemonService(controller: controller)
    let listener = NSXPCListener(machServiceName: PantherService.machName)
    listener.setConnectionCodeSigningRequirement(requirement)
    listener.delegate = service
    listener.resume()

    // launchd sends SIGTERM on unload/shutdown: never leave sleep disabled behind.
    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler {
        MainActor.assumeIsolated {
            log.info("SIGTERM: restoring sleep and exiting")
            controller.shutdown()
            exit(0)
        }
    }
    term.resume()

    // Keep sensors, listener and sources alive for the life of the process.
    Retained.objects = [lid, power, thermal, scheduler, service, listener, term]
    log.info("pantherd ready")
}

enum Retained { nonisolated(unsafe) static var objects: [Any] = [] }

// Run the main run loop on the main thread. Not dispatchMain(): that exits the main thread and drains
// the main queue on a worker thread, which breaks MainActor (crash on first XPC request) and never
// services run-loop sources such as the IOPowerSources notification.
RunLoop.main.add(NSMachPort(), forMode: .default)   // keeps run() from returning when idle
while true { RunLoop.main.run() }
