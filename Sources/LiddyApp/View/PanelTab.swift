import SwiftUI
import LiddyKit

/// The panel's pages, reached from an icon bar at the bottom — the iStat Menus shape.
///
/// **Why this replaced disclosure sections.** Every section that could expand was a
/// section that could change the panel's height, and a panel that changes height has to
/// resize its own window while SwiftUI is mid-layout. That produced, in order: a
/// one-frame jump when Health opened, a measurement feedback loop that grew the window
/// to fill the screen, content clipped off the top when the window was shorter than the
/// content, and a 1330pt content height that no clamp could make look like a dropdown.
/// Four bugs, one cause.
///
/// Pages have a fixed height. The window never resizes at all — not on a disclosure,
/// not on a tick, not when a health sweep lands — so the entire class is gone rather
/// than fixed. What was a disclosure is now a page that is always open once you are on
/// it, which is also less clicking to reach the same thing.
enum PanelTab: String, CaseIterable, Identifiable {
    case now
    case apps
    case health
    case setting
    case activity

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .now:      return "bolt.fill"
        case .apps:     return "square.stack.3d.up"
        case .health:   return "stethoscope"
        case .setting:  return "slider.horizontal.3"
        case .activity: return "list.bullet"
        }
    }

    var label: String {
        switch self {
        case .now:      return "Now"
        case .apps:     return "Apps"
        case .health:   return "Health"
        case .setting:  return "Settings"
        case .activity: return "Activity"
        }
    }
}

/// The bottom bar: one button per page, plus Quit.
///
/// Every tab gets an equal share of the width, glyph over a one-word label. The first
/// version packed five 30pt icons against the left edge and left a 100pt hole before
/// Quit, so the bar read as unfinished; and without labels the glyphs were a guessing
/// game (a stack of layers is not obviously "Apps"). Equal cells also give each target
/// a ~48pt hit area instead of 30.
///
/// Glyphs sit in one fixed box so SF Symbols of different aspect ratios — the wide
/// stethoscope, the narrow bolt — share a baseline and a centre instead of each
/// sizing its own frame.
struct PanelTabBar: View {
    @Binding var selection: PanelTab
    /// Drawn as a dot on the Health glyph, so a failing check is visible from every
    /// page rather than only from the one you would have to go looking on.
    var healthProblemCount: Int
    var onQuit: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                button(for: tab)
            }
            Divider()
                .frame(height: 22)
                .padding(.horizontal, 2)
            Button(action: onQuit) {
                cell(symbol: "power", label: "Quit", isSelected: false)
                    .frame(width: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit Liddy (⌘Q)")
            .accessibilityLabel("Quit Liddy")
            .keyboardShortcut("q", modifiers: .command)
        }
        .frame(height: Self.height)
    }

    /// Fixed so the bar can never change the panel's height — see `PanelTab`.
    static let height: CGFloat = 36

    private func button(for tab: PanelTab) -> some View {
        let isSelected = tab == selection
        return Button { selection = tab } label: {
            cell(symbol: tab.symbolName, label: tab.label, isSelected: isSelected)
                .overlay(alignment: .top) {
                    if tab == .health, healthProblemCount > 0 {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                            // Top-right of the glyph box, not of the whole cell.
                            .offset(x: 10, y: 3)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.primary.opacity(0.1) : .clear)
                )
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.primary : .secondary)
        .help(tab.label)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func cell(symbol: String, label: String, isSelected: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .imageScale(.medium)
                .frame(width: 20, height: 16)
            Text(label)
                .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}
