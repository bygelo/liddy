import SwiftUI
import LiddyKit

/// Every threshold that decides when the Mac is allowed to sleep, editable in place.
///
/// These were CLI-only (`liddy set`), which put the numbers that govern an overnight
/// run behind a command you have to remember. The panel already *draws* the floors —
/// the battery ring turns amber at the soft one — so it should be able to move them.
///
/// Changes apply to the live governor immediately, not on next launch: a floor you
/// just raised should protect the run you are in the middle of.
struct SettingSection: View {
    @ObservedObject var model: AppModel
    @Binding var isExpanded: Bool

    private var setting: Setting { model.setting }

    /// Coarse, human choices rather than a free-entry field. A 7-second idle release
    /// is not a thing anyone wants, and a text field in a menu-bar panel is a way to
    /// find out what happens when you type "abc".
    private static let idleChoice: [(label: String, second: Int)] = [
        ("1m", 60), ("5m", 300), ("10m", 600), ("30m", 1800),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack {
                    SectionLabel(text: "Settings", trailing: isExpanded ? nil : summary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                battery
                Divider().opacity(0.5)
                behaviour
            }
        }
    }

    private var summary: String {
        "\(setting.softBatteryPercent)% · \(setting.idleReleaseSecond / 60)m idle"
    }

    // MARK: - Floors

    private var battery: some View {
        VStack(alignment: .leading, spacing: 6) {
            Stepper(value: Binding(
                get: { setting.softBatteryPercent },
                set: { model.updateSetting(SettingPatch(softBatteryPercent: $0)) }
            ), in: Setting.softBatteryRange, step: 5) {
                row("Sleep at", "\(setting.softBatteryPercent)%",
                    help: "Release the hold and sleep normally, with headroom to resume.")
            }

            Stepper(value: Binding(
                get: { setting.hardBatteryPercent },
                set: { model.updateSetting(SettingPatch(hardBatteryPercent: $0)) }
            ), in: Setting.hardBatteryRange, step: 1) {
                row("Force sleep at", "\(setting.hardBatteryPercent)%",
                    help: "Last resort. Beats every power assertion, not just Liddy's.")
            }

            HStack {
                Text("Back off when").font(.system(size: 11))
                Spacer()
                Picker("", selection: Binding(
                    get: { setting.thermalCeiling },
                    set: { model.updateSetting(SettingPatch(thermalCeiling: $0)) }
                )) {
                    ForEach(Setting.thermalCeilingChoice, id: \.self) { level in
                        Text(level.display).tag(level)
                    }
                }
                .labelsHidden()
                .frame(width: 108)
            }
            .help("Thermal pressure at which the hold is released. Liddy reads the state macOS reports; it does not control fans.")
        }
        .controlSize(.small)
    }

    // MARK: - Behaviour

    private var behaviour: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Release after").font(.system(size: 11))
                Spacer()
                Picker("", selection: Binding(
                    get: { setting.idleReleaseSecond },
                    set: { model.updateSetting(SettingPatch(idleReleaseSecond: $0)) }
                )) {
                    ForEach(Self.idleChoice, id: \.second) { choice in
                        Text(choice.label).tag(choice.second)
                    }
                    // A hand-edited config can hold a value that is not on the menu.
                    // Without this the picker would show blank and silently rewrite it
                    // the first time the section is opened.
                    if !Self.idleChoice.contains(where: { $0.second == setting.idleReleaseSecond }) {
                        Text("\(setting.idleReleaseSecond)s").tag(setting.idleReleaseSecond)
                    }
                }
                .labelsHidden()
                .frame(width: 108)
            }
            .help("Smart mode only: how long every lease must be gone before the Mac is released.")

            Toggle("Watch for known dev and AI processes", isOn: Binding(
                get: { model.snapshot.isAutoWatchOn },
                set: { model.setAutoWatch($0) }
            ))
            .help("Presence-based detection as a fallback. `liddy claim` is the precise path: the work says when it starts and stops.")

            Toggle("Hold only while plugged in", isOn: Binding(
                get: { setting.isChargingOnly },
                set: { model.updateSetting(SettingPatch(isChargingOnly: $0)) }
            ))

            Toggle("Check services over the network", isOn: Binding(
                get: { setting.isNetworkProbeOn },
                set: { model.setNetworkProbe($0) }
            ))
            .help("DNS plus a HEAD request to the API of whichever agent holds a lease. Off means Liddy makes no outbound requests at all.")
        }
        .font(.system(size: 11))
        .controlSize(.small)
    }

    private func row(_ title: String, _ value: String, help: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 11))
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .help(help)
    }
}
