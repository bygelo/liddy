import SwiftUI
import LiddyKit

/// One control for what was two switches.
///
/// "Keep awake" and "Closed-lid mode" were never independent booleans — the runtime
/// already refuses the fourth combination, because there is no useful state where the
/// lid may close but nothing is holding the Mac awake. Two switches offered four
/// states for a three-state idea, left the user to discover that one of the four was
/// impossible, and looked like a settings pane rather than a tool with a job.
///
/// As a single axis it reads as what it is: how far you are asking Liddy to go.
struct ModeSelector: View {
    enum Mode: CaseIterable {
        case sleep, awake, lid

        var title: String {
            switch self {
            case .sleep: return "Sleep"
            case .awake: return "Awake"
            case .lid:   return "Lid shut"
            }
        }

        var symbolName: String {
            switch self {
            case .sleep: return "moon.fill"
            case .awake: return "bolt.fill"
            case .lid:   return "laptopcomputer.slash"
            }
        }

        var tint: Color {
            switch self {
            case .sleep: return .secondary
            case .awake: return .green
            case .lid:   return .blue
            }
        }

        var caption: String {
            switch self {
            case .sleep: return "Normal sleep, nothing held"
            case .awake: return "Stays awake while work runs"
            case .lid:   return "Survives the lid closing"
            }
        }
    }

    var selection: Mode
    /// How long the current hold has been running, "0m"-style. nil when nothing is
    /// held. It rides on the caption line because that line exists either way, so
    /// carrying it here costs no height — which is what let the header above be
    /// deleted outright rather than shrunk.
    var elapsed: String?
    /// Named when the governor is refusing to re-arm, so the one state the segmented
    /// control cannot express still has somewhere to say so.
    var blocked: String?
    var onSelect: (Mode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                ForEach(Mode.allCases, id: \.self) { segment($0) }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            HStack(spacing: 6) {
                Text(blocked ?? selection.caption)
                    .font(.system(size: 10))
                    .foregroundStyle(blocked == nil ? .secondary : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let elapsed {
                    Text(elapsed)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func segment(_ mode: Mode) -> some View {
        let isSelected = mode == selection
        return Button {
            onSelect(mode)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                Text(mode.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? .white : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                // Drawn as the selected segment's own background rather than a shared
                // capsule sliding between them. A matched-geometry slide would animate
                // layout on a panel that resizes itself, which is how the countdown
                // ring earned its twitch.
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? mode.tint : .clear)
                    .opacity(mode == .sleep && isSelected ? 0.55 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode.caption)
    }
}

/// The way out of "Holding back".
///
/// A panel that says it is refusing and offers nothing to do about it is a dead end —
/// the same mistake the closed-lid error made. The override is deliberately a *button
/// with a duration on it* rather than a switch: it waives a safety rule, and a waiver
/// with no expiry is just a disabled rule nobody remembers turning off.
struct OverrideBanner: View {
    var reason: StopReason
    var isBusy: Bool
    var onOverride: (Int) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(reason.summary)
                    .font(.system(size: 11, weight: .medium))
                Text("Nothing will re-arm until this recovers.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                HStack(spacing: 5) {
                    ForEach([30 * 60, 60 * 60, 2 * 3600], id: \.self) { second in
                        Button(second < 3600 ? "\(second / 60)m" : "\(second / 3600)h") {
                            onOverride(second)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Keep going for \(second < 3600 ? "\(second / 60) minutes" : "\(second / 3600) hours") anyway")
                    }
                    Text("keep going anyway")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 1)
                .disabled(isBusy)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }
}

/// Shown while an override is running, so it is never a thing you forgot about.
struct OverrideActiveBanner: View {
    var until: Date
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 1) {
                Text("Overriding safety rules")
                    .font(.system(size: 11, weight: .medium))
                Text("\(remainingDisplay) left · hard floor and critical heat still apply")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button("Stop", action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.orange.opacity(0.14))
        )
    }

    private var remainingDisplay: String {
        let second = max(0, Int(until.timeIntervalSinceNow.rounded()))
        if second >= 3600 {
            return "\(second / 3600)h \(String(format: "%02d", (second % 3600) / 60))m"
        }
        return "\(Int((Double(second) / 60).rounded(.up)))m"
    }
}
