import SwiftUI
import LiddyKit

/// One row per known AI agent — working or idle, and whether its API answers.
///
/// Idle agents are listed but not probed. Showing them keeps the panel honest about
/// what Liddy understands (so an agent missing from the list is a visible gap rather
/// than a silent one), while probing only the ones actually working keeps a power
/// utility from making six outbound requests every thirty seconds.
struct AgentSection: View {
    @ObservedObject var model: AppModel
    @Binding var isExpanded: Bool

    private var status: [AgentStatus] {
        AgentStatus.build(activeLease: model.snapshot.activeLease, health: model.snapshot.health)
    }

    var body: some View {
        let all = status
        let working = all.filter(\.isWorking)
        // Collapsed with nothing working, show an agent that actually has an answer —
        // the always-probed one — rather than whichever sorted first. A single row
        // reading "Antigravity · not checked" is a row that cost space and said nothing.
        let representative = all.first { $0.serviceState != nil } ?? all.first
        // Collapsed is always exactly one row. Showing every working agent meant the
        // section's height tracked how many agents happened to be mid-turn, so the
        // panel resized itself while you were reading it — and switching modes releases
        // leases, which changes that count as a side effect. Expand for the full list.
        let shown = isExpanded
            ? all
            : [working.first ?? representative].compactMap { $0 }

        VStack(alignment: .leading, spacing: 5) {
            // Unanimated on purpose — see the note in `HealthSection`.
            Button {
                isExpanded.toggle()
            } label: {
                HStack {
                    SectionLabel(
                        text: "Agents",
                        trailing: working.isEmpty ? "none working" : "\(working.count) working")
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(shown) { AgentRow(status: $0) }

            if !isExpanded && all.count > shown.count {
                Text("+\(all.count - shown.count) more")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct AgentRow: View {
    var status: AgentStatus

    var body: some View {
        HStack(spacing: 6) {
            AgentIcon(status: status)

            Text(status.label)
                .font(.system(size: 11, weight: status.isWorking ? .medium : .regular))
                .frame(width: 74, alignment: .leading)
                .lineLimit(1)

            Text(status.workDisplay)
                .font(.system(size: 10))
                .foregroundStyle(status.isWorking ? .primary : .secondary)
                .frame(width: 66, alignment: .leading)
                .lineLimit(1)

            Spacer(minLength: 2)

            HStack(spacing: 4) {
                Circle()
                    .fill(status.serviceState.map(Palette.color(for:)) ?? Color.secondary.opacity(0.4))
                    .frame(width: 5, height: 5)
                Text(status.serviceDisplay)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .help(status.leaseLabel.isEmpty
              ? "\(status.label): \(status.serviceDisplay)"
              : status.leaseLabel.joined(separator: ", "))
    }
}
