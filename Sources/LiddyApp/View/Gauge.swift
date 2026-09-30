import SwiftUI
import LiddyKit

/// The one place colour is decided, so a green dot in the health list and a green
/// ring at the top of the panel always mean the same thing.
enum Palette {
    static func color(for state: HealthState) -> Color {
        switch state {
        case .ok:       return .green
        case .degraded: return .orange
        case .down:     return .red
        case .unknown:  return .yellow
        case .off:      return .secondary
        }
    }

    static func color(for level: ThermalLevel) -> Color {
        switch level {
        case .nominal:  return .green
        case .fair:     return .teal
        case .serious:  return .orange
        case .critical: return .red
        }
    }

    /// Die temperature against the throttling point, not against an arbitrary scale:
    /// Apple silicon runs happily in the 60s and starts throttling hard around 90°C.
    /// Falls back to the pressure state's colour when no sensor answered.
    static func temperatureColor(_ celsius: Double?, level: ThermalLevel) -> Color {
        guard let celsius else { return color(for: level) }
        if celsius >= 90 { return .red }
        if celsius >= 75 { return .orange }
        return .green
    }

    /// CPU share, coloured on the same scale the rest of the panel uses: green is
    /// fine, amber is worth knowing, red is the thing cooking the laptop.
    static func loadColor(_ cpuPercent: Double) -> Color {
        if cpuPercent >= 80 { return .red }
        if cpuPercent >= 40 { return .orange }
        return .green
    }

    /// Battery colour tracks the floors, not an arbitrary 20/50 split — the ring goes
    /// amber exactly when the soft floor is the next thing that will happen.
    static func batteryColor(percent: Int?, setting soft: Int, hard: Int, isOnMain: Bool) -> Color {
        guard let percent else { return .secondary }
        if isOnMain { return .green }
        if percent <= hard { return .red }
        if percent <= soft { return .orange }
        return .green
    }
}

/// A donut with a value in the middle. The shape from the reference screenshots, at
/// menu-bar scale.
///
/// The centre is a `Content`, not a free string, because the first build let any label
/// through and "Very hot" promptly rendered straight over the stroke. A ring this size
/// has roughly 44pt of usable width inside the track: numbers fit, words do not. So a
/// measurement gets `.number`, and a *state* gets `.symbol` with the word moved to the
/// caption underneath, where there is room for it.
struct RingGauge: View {
    enum Content {
        case number(String, unit: String?)
        case symbol(String)
    }

    var fraction: Double
    var color: Color
    var content: Content
    var caption: String
    var diameter: CGFloat = 58
    var lineWidth: CGFloat = 6

    /// The square that fits inside the track, minus a hair of breathing room.
    private var innerWidth: CGFloat { diameter - (lineWidth * 2) - 5 }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.22), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, fraction)))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    // Start the fill at 12 o'clock instead of 3.
                    .rotationEffect(.degrees(-90))

                center
                    // Boxed on **both** axes. Width alone let the content keep its
                    // intrinsic height, so when `minimumScaleFactor` shrank a too-wide
                    // label the baseline-aligned row got shorter and the glyph drifted
                    // vertically. A fixed box centres whatever it is given, so a rescale
                    // can no longer move anything.
                    .frame(width: innerWidth, height: innerWidth)
            }
            .frame(width: diameter, height: diameter)

            // No `minimumScaleFactor` here, deliberately. This caption sits in a
            // *flexible* frame, so scaling let SwiftUI answer "not quite enough width"
            // by shrinking the type — and every disclosure below re-ran layout, so
            // expanding a section visibly resized text at the top of the panel.
            // Truncation is the honest failure mode: the caption either fits or it
            // ellipsises, but it never changes size under you.
            Text(caption)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: diameter + 22)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var center: some View {
        switch content {
        case .number(let value, let unit):
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            // Safe to scale, unlike the caption: this sits in a *fixed* frame, so it
            // only ever responds to its own content ("100%") and never to how much
            // room the rest of the panel is using.
            .lineLimit(1)
            .minimumScaleFactor(0.6)

        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(color)
        }
    }
}

/// A progress bar broken into ticks, so a glance reads as "about two thirds" without
/// having to measure a smooth bar against its container.
struct SegmentBar: View {
    var fraction: Double
    var color: Color
    var segmentCount: Int = 24
    var height: CGFloat = 4

    var body: some View {
        let filled = Int((Double(segmentCount) * min(1, max(0, fraction))).rounded())
        HStack(spacing: 2) {
            ForEach(0..<segmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index < filled ? color : Color.secondary.opacity(0.18))
            }
        }
        .frame(height: height)
    }
}

/// Bar sparkline over recent samples. Bars, not a line: the underlying series is a
/// count of leases, which is a step function — drawing it as a smooth curve would
/// imply values it never had.
struct Sparkline: View {
    var value: [Double]
    var color: Color
    var barCount: Int
    var height: CGFloat = 18

    var body: some View {
        let series = padded
        let peak = max(series.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(Array(series.enumerated()), id: \.offset) { _, sample in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(sample > 0 ? color : Color.secondary.opacity(0.16))
                    .frame(height: max(2, CGFloat(sample / peak) * height))
            }
        }
        .frame(height: height, alignment: .bottom)
    }

    /// Left-pad with zeros so a fresh session's three samples sit at the right-hand
    /// edge and grow leftward, instead of stretching three fat bars across the strip.
    private var padded: [Double] {
        guard value.count < barCount else { return Array(value.suffix(barCount)) }
        return Array(repeating: 0, count: barCount - value.count) + value
    }
}

/// A single answered check.
struct HealthRow: View {
    var check: HealthCheck
    /// nil in contexts with no model to act through — the CLI's text rendering, and
    /// the group rows in the expanded panel.
    var onFix: ((HealthRemedy) -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: check.state.symbolName)
                .font(.system(size: 9))
                .foregroundStyle(Palette.color(for: check.state))
                .frame(width: 11)
            Text(check.label)
                .font(.system(size: 11))
                .frame(width: 96, alignment: .leading)
            Text(check.detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            if let millisecond = check.latencyMillisecond {
                Text("\(millisecond)ms")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            // A diagnosis with no next step leaves the user stuck. Only on rows that
            // are actually failing: a green check with a button invites a click that
            // does nothing.
            if let remedy = check.remedy, let onFix, check.state >= .degraded {
                Button(remedy.title) { onFix(remedy) }
                    .buttonStyle(.link)
                    .font(.system(size: 10, weight: .medium))
            }
        }
    }
}

/// The group header — name on the left, worst-in-group verdict on the right.
struct HealthPill: View {
    var title: String
    var state: HealthState

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Palette.color(for: state))
                .frame(width: 6, height: 6)
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.4)
        }
    }
}

/// Section label used across the panel.
struct SectionLabel: View {
    var text: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .kerning(0.4)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}


/// A sectioned block: the panel's grouping unit.
///
/// Replaces the horizontal rules. A `Divider()` says "something changes here" without
/// saying what belongs together — seven of them down a 300pt column read as a table of
/// contents. A filled block states the grouping positively, which is how every
/// menu-bar meter that shows more than one reading does it (iStat Menus, Stats), and
/// it is what the user asked for over the rules.
///
/// Fill rather than stroke: a 1pt border at this size draws more attention than the
/// content inside it, and stacked bordered boxes re-create exactly the busy grid the
/// rules were.
struct Card<Content: View>: View {
    var content: Content
    /// Overridable per card. The gauge card runs a narrower inset than the text cards
    /// so its rings can be bigger without the panel getting wider — a ring is a shape
    /// you read at a glance, and 8pt of side gutter bought nothing there that it buys
    /// beside a line of text.
    var horizontal: CGFloat
    var top: CGFloat
    var bottom: CGFloat

    init(
        horizontal: CGFloat = 8,
        top: CGFloat = 6,
        bottom: CGFloat = 6,
        @ViewBuilder content: () -> Content
    ) {
        self.horizontal = horizontal
        self.top = top
        self.bottom = bottom
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, horizontal)
            .padding(.top, top)
            .padding(.bottom, bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
    }
}
