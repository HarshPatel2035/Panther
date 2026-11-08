import AppKit
import PantherCore
import SwiftUI

/// The panel that opens from the menu bar paw. A regular window (MenuBarExtra .window style), so
/// press-and-hold works here; the status item itself keeps the system's own click handling.
public struct PanelView: View {
    let model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let message = problem { ProblemBanner(message: message) }
            if model.isActive { ActiveCard(model: model) }
            StartCard(model: model)
            EnvironmentRow(environment: model.status?.environment, lowPower: model.status?.lowPowerByPanther == true)
            Divider().overlay(Color.white.opacity(0.08))
            FooterRow(model: model)
        }
        .padding(16)
        .frame(width: 310)
        .background(Theme.background)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onAppear { model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.gold)
            Text("Panther").font(.system(size: 16, weight: .bold, design: .rounded))
            Spacer()
            StatusPill(active: model.isActive, reachable: model.status != nil)
        }
    }

    private var problem: String? {
        if let error = model.lastError { return error }
        if let stuck = model.status?.stuck { return stuck }
        if model.isActive, model.status?.sleepDisabled != true { return "Sleep guard isn't set. Run panther doctor." }
        return nil
    }
}

private struct StatusPill: View {
    let active: Bool
    let reachable: Bool

    var body: some View {
        let (text, color) = !reachable ? ("Offline", Theme.danger) : active ? ("Awake", Theme.gold) : ("Idle", Theme.secondaryText)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
    }
}

private struct ActiveCard: View {
    let model: AppModel

    var body: some View {
        Card {
            Text(model.isCountingDown ? "TIME LEFT" : "RUNNING FOR")
                .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                .foregroundStyle(Theme.secondaryText)
            Text(model.clockText ?? "0:00:00")
                .font(.system(size: 42, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .foregroundStyle(Theme.gold)
            if model.isCountingDown {
                ProgressBar(value: model.progress)
            }
            ForEach(model.holds) { hold in SessionRow(hold: hold) }
            HStack(spacing: 8) {
                ChipButton(title: "30m", systemImage: "plus") { model.extend(by: 1_800) }
                ChipButton(title: "1h", systemImage: "plus") { model.extend(by: 3_600) }
                ChipButton(title: "2h", systemImage: "plus") { model.extend(by: 7_200) }
            }
            HoldToEndButton(state: model.holdToEnd,
                            title: model.holds.count > 1 ? "Hold to end all sessions" : "Hold to end session") {
                model.end()
            }
        }
    }
}

private struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Theme.gold.opacity(0.7), Theme.gold], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * (1 - value))
            }
        }
        .frame(height: 5)
    }
}

private struct SessionRow: View {
    let hold: Hold

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: hold.process == nil ? "timer" : "app.badge.checkmark")
                .foregroundStyle(Theme.secondaryText)
            Text(hold.label).lineLimit(1)
            Spacer()
            Text(hold.process == nil ? "ends \(Self.time(hold.endsAt))" : "max \(Self.time(hold.endsAt))")
                .foregroundStyle(Theme.secondaryText)
        }
        .font(.system(size: 11))
    }

    static func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
}

private struct StartCard: View {
    let model: AppModel
    private let presets: [(String, TimeInterval)] = [("30m", 1_800), ("1h", 3_600), ("2h", 7_200), ("4h", 14_400), ("8h", 28_800)]

    var body: some View {
        Card {
            Text(model.isActive ? "START ANOTHER" : "KEEP AWAKE WITH THE LID CLOSED")
                .font(.system(size: 10, weight: .semibold)).tracking(1.2)
                .foregroundStyle(Theme.secondaryText)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(presets, id: \.1) { preset in
                    ChipButton(title: preset.0, prominent: !model.isActive && preset.1 == 3_600) {
                        model.start(for: preset.1)
                    }
                }
                AppPicker(model: model)
            }
        }
    }
}

/// "Until an app quits": pick one of the running apps.
private struct AppPicker: View {
    let model: AppModel

    var body: some View {
        Menu {
            let apps = Self.runningApps()
            if apps.isEmpty { Text("No apps found") }
            ForEach(apps, id: \.processIdentifier) { app in
                Button(app.localizedName ?? "App") { model.startUntilQuit(app) }
            }
        } label: {
            Label("App…", systemImage: "app.badge")
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.08)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Keep awake until an app quits")
    }

    static func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }
}

private struct EnvironmentRow: View {
    let environment: PantherCore.Environment?
    let lowPower: Bool

    var body: some View {
        if let e = environment {
            HStack(spacing: 14) {
                item(e.lidClosed ? "laptopcomputer.slash" : "laptopcomputer", e.lidClosed ? "Lid closed" : "Lid open")
                if let p = e.power {
                    item(p.onBattery ? Self.batterySymbol(p.percent) : "bolt.fill",
                         p.percent.map { "\($0)%" } ?? "?")
                }
                item("thermometer.medium", "\(e.thermal)".capitalized)
                if lowPower { item("leaf.fill", "Low Power").foregroundStyle(Theme.gold) }
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondaryText)
        }
    }

    private func item(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) { Image(systemName: symbol); Text(text) }
    }

    static func batterySymbol(_ percent: Int?) -> String {
        switch percent ?? 50 {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

private struct FooterRow: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if model.isPreview {
                // ImageRenderer can't draw AppKit switches; draw a stand-in for snapshots.
                HStack(spacing: 6) {
                    Text("Open at login").font(.system(size: 11))
                    Capsule().fill(Theme.gold).frame(width: 26, height: 15)
                        .overlay(Circle().fill(.white).frame(width: 12).offset(x: 5.5))
                }
            } else {
                Toggle("Open at login", isOn: Binding(get: { model.loginItem.isEnabled },
                                                       set: { model.loginItem.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Library/Logs/Panther/pantherd.log"))
            } label: { Image(systemName: "doc.text.magnifyingglass") }
                .help("Show log")
            Button {
                NSApplication.shared.terminate(nil)
            } label: { Image(systemName: "power") }
                .help("Quit the menu bar app (running sessions continue)")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondaryText)
    }
}

private struct ProblemBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
            Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
