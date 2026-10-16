import ServiceManagement
import SwiftUI

struct MillumeApp: App {
    @StateObject private var sync = SyncController()

    var body: some Scene {
        MenuBarExtra {
            MenuView(sync: sync)
        } label: {
            Image(systemName: sync.lidClosed ? "sun.max.circle" : "sun.max")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuView: View {
    @ObservedObject var sync: SyncController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Sync with MacBook display", isOn: $sync.enabled)

            VStack(spacing: 4) {
                row("MacBook", percent(sync.macBrightness))
                if sync.displayCount == 0 {
                    row("External", "no DDC display", color: .orange)
                } else {
                    row("External", percent(sync.externalBrightness))
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                row("Offset", sync.offset > 0 ? "+\(sync.offset)%" : "\(sync.offset)%")
                Slider(
                    value: Binding(get: { Double(sync.offset) }, set: { sync.offset = Int($0.rounded()) }),
                    in: Double(SyncController.offsetRange.lowerBound) ... Double(SyncController.offsetRange.upperBound)
                )
            }

            // Always present (disabled while syncing) so the menu never changes height:
            // MenuBarExtra windows don't shrink cleanly and lose their rounded corners.
            VStack(alignment: .leading, spacing: 4) {
                Text(manualCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(sync.externalBrightness ?? 50) },
                        set: { sync.setManual(Int($0.rounded())) }
                    ),
                    in: 0 ... 100
                )
                .disabled(!manualAllowed)
            }

            Divider()

            Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
            Button("Quit Millume") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 260)
    }

    private var manualAllowed: Bool {
        sync.lidClosed || !sync.enabled
    }

    private var manualCaption: String {
        if sync.lidClosed { return "Lid closed: holding brightness" }
        return sync.enabled ? "External brightness (synced)" : "External brightness"
    }

    private func row(_ title: String, _ value: String, color: Color = .secondary) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(color)
        }
    }

    private func percent(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "–"
    }

    private func setLaunchAtLogin(_ enable: Bool) {
        try? enable ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
