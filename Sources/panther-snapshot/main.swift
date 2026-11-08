import AppKit
import PantherCore
import PantherUI
import SwiftUI

// Renders the menu bar panel with sample data to PNGs, for design review without a daemon.
//   swift run panther-snapshot <output-dir>
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".", isDirectory: true)
let now = Date(timeIntervalSince1970: 1_800_000_000)
let env = PantherCore.Environment(lidClosed: false, externalDisplay: false,
                                  power: PowerSnapshot(onBattery: true, percent: 76), thermal: .nominal)

func status(_ holds: [Hold]) -> DaemonStatus {
    DaemonStatus(now: now, holds: holds, environment: env, sleepDisabled: !holds.isEmpty,
                 sleepDisabledByPanther: !holds.isEmpty, foreignSleepDisabled: false, stuck: nil,
                 limits: .standard, events: [])
}

let timed = Hold(kind: .timed, label: "2h session", startedAt: now.addingTimeInterval(-2_655),
                 endsAt: now.addingTimeInterval(4_545))
let job = Hold(kind: .untilExit(ProcessIdentity(pid: 4242, startMicros: 1)), label: "until Xcode quits",
               startedAt: now.addingTimeInterval(-600), endsAt: now.addingTimeInterval(8 * 3_600))

let scenes: [(String, DaemonStatus)] = [
    ("idle", status([])), ("active", status([timed])), ("two-sessions", status([timed, job])),
]

MainActor.assumeIsolated {
    for (name, s) in scenes {
        let renderer = ImageRenderer(content: PanelView(model: AppModel(preview: s)))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("could not render \(name)"); continue
        }
        let url = out.appendingPathComponent("panel-\(name).png")
        try? png.write(to: url)
        print(url.path)
    }
}
