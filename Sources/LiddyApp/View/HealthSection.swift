import SwiftUI
import LiddyKit

/// The verification panel: every question Liddy can answer about whether an
/// unattended run will survive the night, grouped by what would have to be fixed.
struct HealthSection: View {
    @ObservedObject var model: AppModel
    @Binding var isExpanded: Bool

    private var report: HealthReport? { model.snapshot.health }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header

            if let report {
                if isExpanded {
                    ForEach(HealthGroup.allCases, id: \.self) { group in
                        let check = report.check(in: group)
                        if !check.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                HealthPill(title: group.display, state: report.state(of: group))
                                ForEach(check) { HealthRow(check: $0) }
                            }
                            .padding(.top, 2)
                        }
                    }
                } else {
                    summary(report)
                }
            } else {
                Text("Checking…").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        // Not animated. The panel is an NSPopover that resizes to fit its content the
        // instant the height changes; animating the SwiftUI side means the content
        // spends 180ms at a height the window is not, which is the jump. Whoever owns
        // the window owns the timing, and here that is AppKit.
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Text("HEALTH")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.4)
                if let report {
                    Circle()
                        .fill(Palette.color(for: report.overall))
                        .frame(width: 6, height: 6)
                    Text(headline(report))
                        .font(.system(size: 10))
                        .foregroundStyle(report.overall >= .degraded ? Palette.color(for: report.overall) : .secondary)
                }
                Spacer()
                if let report {
                    Text(report.at.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func headline(_ report: HealthReport) -> String {
        let problem = report.problem
        if problem.isEmpty { return "All checks passing" }
        if problem.count == 1 { return problem[0].label }
        return "\(problem.count) checks need attention"
    }

    /// Collapsed: one dot per group, plus the failing rows spelled out. A problem is
    /// never hidden behind a disclosure triangle.
    private func summary(_ report: HealthReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                ForEach(HealthGroup.allCases, id: \.self) { group in
                    if !report.check(in: group).isEmpty {
                        HealthPill(title: group.display, state: report.state(of: group))
                    }
                }
                Spacer()
            }
            ForEach(report.problem) { HealthRow(check: $0) }
        }
    }
}
