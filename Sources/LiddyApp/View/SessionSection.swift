import SwiftUI
import LiddyKit

/// **Tab Warden** — every live CLI agent session on this Mac, as a wrapping row of
/// pills rather than a list of text.
///
/// Each pill is the repo name, the agent's **real app icon** (borrowed from the copy
/// installed on this Mac — see `AppIconResolver`, nothing is redistributed), and a
/// state colour. Eight sessions across four tools is a paragraph of text as a list and
/// two lines as pills, which is the whole point: the panel's complaint was that it read
/// like a document.
///
/// The colour carries the state, so the word does not have to:
///
/// | Colour | State | Means |
/// |---|---|---|
/// | green | working | writing to its transcript right now |
/// | blue | running | alive; this tool publishes no per-turn activity |
/// | amber | your turn | alive and quiet — it is waiting on you |
/// | grey | idle | alive but untouched for 15 minutes |
///
/// Everything a row used to spell out — tool, branch, exact age, directory — moved into
/// the hover tooltip, which is where detail belongs on a readout you open for four
/// seconds.
struct SessionSection: View {
    @ObservedObject var model: AppModel

    private var session: [AgentSession] { model.snapshot.session }

    /// Nine pills is three rows at this width, which is what the page has room for now
    /// that every page is the same height. Past that the summary already counts them
    /// and the full list is one `liddy session` away.
    private static let pillLimit = 9

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Sessions", trailing: summary)

            if session.isEmpty {
                Text("No agent sessions running")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                PillFlow(spacing: 4, rowSpacing: 4) {
                    ForEach(session.prefix(Self.pillLimit)) { pill(for: $0) }
                }
                if session.count > Self.pillLimit {
                    Text("+\(session.count - Self.pillLimit) more · liddy session")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// "4 working · 2 your turn" — the counts, so the pills do not have to be counted.
    private var summary: String? {
        guard !session.isEmpty else { return nil }
        let working = session.filter { $0.state == .working || $0.state == .running }.count
        let waiting = session.filter { $0.state == .waiting }.count
        var part: [String] = []
        if working > 0 { part.append("\(working) working") }
        if waiting > 0 { part.append("\(waiting) your turn") }
        return part.isEmpty ? "\(session.count) open" : part.joined(separator: " · ")
    }

    private func pill(for entry: AgentSession) -> some View {
        let color = Self.color(for: entry.state)
        return HStack(spacing: 4) {
            AgentIcon(
                symbolName: entry.tool.symbolName,
                bundleIdentifier: entry.tool.bundleIdentifier,
                size: 12,
                isActive: entry.state != .idle)
            Text(entry.projectDisplay)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(0.16))
        )
        .overlay(
            // The state is the border, not a dot: at pill size a 6pt circle is noise,
            // and the outline colours the whole shape the eye already landed on.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(color.opacity(0.55), lineWidth: 1)
        )
        .foregroundStyle(.primary)
        .help(tooltip(for: entry))
    }

    /// Everything the old text row spelled out, on hover.
    private func tooltip(for entry: AgentSession) -> String {
        var line = "\(entry.tool.label) · \(entry.state.display) · \(entry.ageDisplay()) ago"
        if let branch = entry.branch { line += "\nbranch \(branch)" }
        if let directory = entry.directory { line += "\n\(directory)" }
        return line
    }

    /// The one place session colour is decided. Kept beside the table in this file's
    /// doc comment so the two cannot drift.
    static func color(for state: SessionState) -> Color {
        switch state {
        case .working: return .green
        case .running: return .blue
        case .waiting: return .orange
        case .idle:    return .secondary
        case .ended:   return .secondary
        }
    }
}

/// Lays pills left to right and wraps, like text.
///
/// `LazyVGrid` cannot do this: its columns are fixed, so a two-character repo name and
/// a twenty-character one get the same width and the row ends up mostly gap. This is
/// the standard flow layout, ~30 lines of `Layout`, and it is why the pills read as a
/// paragraph of chips rather than a table.
struct PillFlow: Layout {
    var spacing: CGFloat = 4
    var rowSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
