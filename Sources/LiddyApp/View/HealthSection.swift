import SwiftUI
import LiddyKit

/// The verification panel: every question Liddy can answer about whether an
/// unattended run will survive the night, grouped by what would have to be fixed.
struct HealthSection: View {
    @ObservedObject var model: AppModel
    @Binding var isExpanded: Bool

    private var report: HealthReport? { model.snapshot.health }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header

            if let report {
                if isExpanded {
                    ForEach(HealthGroup.allCases, id: \.self) { group in
                        let check = report.check(in: group)
                        if !check.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                HealthPill(title: group.display, state: report.state(of: group))
                                ForEach(check) { HealthRow(check: $0) { model.apply($0) } }
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
        // No toggle: this is a page now, not a disclosure. See `PanelTab`.
        Group {
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
            }
        }
    }

    private func headline(_ report: HealthReport) -> String {
        let problem = report.problem
        if problem.isEmpty { return "All checks passing" }
        if problem.count == 1 { return problem[0].label }
        return "\(problem.count) checks need attention"
    }

    /// Collapsed: the failing rows, and nothing else. A problem is never hidden behind
    /// a disclosure triangle — but a *passing* group is, because the header line above
    /// already says "All checks passing".
    ///
    /// The four group pills used to sit here too. They were a second drawing of a fact
    /// the header states in words, on a panel whose complaint was its height, so they
    /// now appear only in the expanded view where the per-group rows they label are
    /// actually visible.
    private func summary(_ report: HealthReport) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(report.problem) { HealthRow(check: $0) { model.apply($0) } }
        }
    }
}
