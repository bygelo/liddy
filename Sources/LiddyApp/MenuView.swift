import SwiftUI
import LiddyKit

/// The menu answers two questions before anything else: *why is my Mac awake* and
/// *what will stop it*. Controls come after that, not before.
struct MenuView: View {
    @ObservedObject var model: AppModel

    private var snapshot: RuntimeSnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            whyAwake
            Divider()
            control
            Divider()
            recent
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(snapshot.isAwakeHeld ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(snapshot.isClamshellActive
                 ? "Protected — lid can close"
                 : (snapshot.isAwakeHeld ? "Keeping awake" : "Idle"))
                .font(.headline)
            Spacer()
            if snapshot.isAwakeHeld {
                Text("\(snapshot.runtimeSecond / 60)m")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var whyAwake: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Why awake").font(.caption.bold()).foregroundStyle(.secondary)
            if snapshot.activeLease.isEmpty {
                Text(snapshot.isAwakeHeld ? "Held manually — nothing tracked" : "Nothing running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.activeLease, id: \.self) { lease in
                    Label(lease, systemImage: "circle.fill")
                        .labelStyle(DotLabel())
                        .font(.caption)
                }
            }
            HStack(spacing: 10) {
                Label(snapshot.battery.display, systemImage: "battery.50")
                Label(snapshot.thermal.level.display, systemImage: "thermometer.medium")
            }
            .font(.caption)
            .foregroundStyle(snapshot.thermal.level >= .serious ? .orange : .secondary)

            if let expiresAt = snapshot.expiresAt {
                Label("Releases at \(expiresAt.formatted(date: .omitted, time: .shortened))",
                      systemImage: "timer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var control: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Keep awake", isOn: Binding(
                get: { snapshot.isAwakeHeld },
                set: { _ in model.toggleAwake() }
            ))
            Toggle("Closed-lid mode", isOn: Binding(
                get: { snapshot.isClamshellActive },
                set: { _ in model.toggleClamshell(second: 8 * 3600) }
            ))
            .help("Needs the Liddy helper. Reverts automatically if Liddy stops.")

            HStack(spacing: 6) {
                ForEach([30 * 60, 3 * 3600, 8 * 3600], id: \.self) { second in
                    Button(second < 3600 ? "\(second / 60)m" : "\(second / 3600)h") {
                        model.hold(forSecond: second)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Activity").font(.caption.bold()).foregroundStyle(.secondary)
            if model.recentEntry.isEmpty {
                Text("Nothing yet").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(model.recentEntry.prefix(4).enumerated()), id: \.offset) { _, entry in
                Text("\(entry.at.formatted(date: .omitted, time: .shortened))  \(entry.detail)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let alert = model.alert {
                Text(alert).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
            Spacer()
            Button("Quit") {
                model.shutdown()
                NSApplication.shared.terminate(nil)
            }
            .controlSize(.small)
        }
    }
}

private struct DotLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(.green)
            configuration.title
        }
    }
}
