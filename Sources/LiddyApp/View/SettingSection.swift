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
            SectionLabel(text: "Settings", trailing: summary)

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
            Toggle("Open at login", isOn: Binding(
                get: { model.isOpenAtLogin },
                set: { model.setOpenAtLogin($0) }
            ))
            .disabled(!model.canOpenAtLogin)
            .help(model.canOpenAtLogin
                  ? "Launch Liddy when you log in. A menu-bar app with no Dock icon is otherwise gone after a reboot."
                  : "Move Liddy.app to /Applications first. Login Items need a stable path.")

            if model.loginItemNeedsApproval {
                Button("Allow in System Settings…") { model.openLoginItemSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("macOS is waiting for you to allow Liddy under Login Items.")
            } else if !model.canOpenAtLogin {
                Text("Needs Liddy.app in /Applications")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

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

            Toggle("Show health checks", isOn: Binding(
                get: { setting.isHealthPanelOn },
                set: { model.updateSetting(SettingPatch(isHealthPanelOn: $0)) }
            ))
            .help("Off by default. The checks still run either way — a failing one still turns the menu-bar glyph into a warning triangle and still appears as a single line in the panel. This only controls whether the passing ones are drawn.")

            Toggle("Screen off while the lid is shut", isOn: Binding(
                get: { setting.isLidBrightnessOff },
                set: { model.updateSetting(SettingPatch(isLidBrightnessOff: $0)) }
            ))
            .help("Turns the backlight down to zero when the lid closes on a Liddy session, and puts it back at the level you left it when the lid opens. A closed panel that is still lit is watts and heat spent on a screen nobody can see.")

            Toggle("Background apps while holding", isOn: Binding(
                get: { setting.isResourceSaverOn },
                set: { model.updateSetting(SettingPatch(isResourceSaverOn: $0)) }
            ))
            .help("Lid open: hides \(setting.backgroundApp.joined(separator: ", ")) while a hold runs. Lid shut: hides everything that is not keeping the work alive, since there is no screen to look at — never terminals, never an app with a live agent session, never Liddy or Finder. Everything is unhidden when the hold ends.")

            if setting.isResourceSaverOn {
                Text("lid open: \(setting.backgroundApp.joined(separator: ", ")) · lid shut: everything idle")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .help("Edit this list with `liddy set --background-app \"Google Chrome,Discord\"`")
            }

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
