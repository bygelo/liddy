import SwiftUI
import LiddyKit

/// The menu answers two questions before anything else: *why is my Mac awake* and
/// *what will stop it*. Controls come after that, not before.
///
/// The gauges at the top are the same two questions drawn instead of written: every
/// ring is a quantity that can end a hold, so there is nothing on the panel you can
/// look at and correctly ignore. System metrics that cannot end a hold — CPU load,
/// memory pressure, network throughput — are deliberately absent; Activity Monitor
/// already draws them, and putting them here would make the one thing this panel is
/// for harder to find.
struct MenuView: View {
    @ObservedObject var model: AppModel

    private var snapshot: RuntimeSnapshot { model.snapshot }
    private var setting: Setting { model.setting }

    var body: some View {
        // Order is a claim about what matters. The control you came here to flip goes
        // first; the readouts that explain what it is doing go under it. The first
        // build had it backwards — the switch sat below four sections of analytics, so
        // the one thing everybody opens this panel for was the last thing they reached.
        VStack(alignment: .leading, spacing: 11) {
            header
            control
            Divider()
            gaugeRow
            Divider()
            session
            Divider()
            AgentSection(model: model, isExpanded: $model.isAgentExpanded)
            Divider()
            HealthSection(model: model, isExpanded: $model.isHealthExpanded)
            Divider()
            SettingSection(model: model, isExpanded: $model.isSettingExpanded)
            Divider()
            activity
            footer
            // Pins the content to the top of whatever height the window happens to be.
            //
            // A `VStack` centres itself in a container taller than its content, so any
            // moment the window was larger than it needed to be — a resize arriving a
            // frame late, a measurement one update behind — put *half the surplus above
            // the content*. That is the space appearing at the top: not the window
            // growing upward, but the content sliding down inside it.
            //
            // `minLength: 0` means the ideal height is unchanged, so this costs nothing
            // when the fit is exact and only does something when it is not.
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 340)
        // Nothing in this panel animates, by rule.
        //
        // It is a readout you open for four seconds, so motion adds no information —
        // and every animation tried here has cost something. The countdown ring was the
        // worst: `timerFraction` is recomputed from `Date()` on every render, so an
        // eased arc re-animated on each redraw and the ring never settled. The panel
        // also resizes its own window, which animated layout fights.
        //
        // A blanket transaction rather than deleting modifiers one at a time: this way
        // a `withAnimation` added later cannot quietly bring the twitch back.
        .transaction { $0.animation = nil }
    }

    // MARK: - Header

    /// Status on the left, the primary switch on the right — the shape every menu-bar
    /// utility with one main job uses, because it puts the control where the pointer
    /// already is when the panel opens.
    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.22))
                    .frame(width: 18, height: 18)
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(statusTitle).font(.system(size: 14, weight: .semibold))
                    if snapshot.isAwakeHeld {
                        Text(elapsedDisplay)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                // Two lines of space held open whether or not both are used. The status
                // line grows a second line in exactly the states you switch *between*
                // — "Battery crossed the floor, won't re-arm until it recovers" wraps,
                // "Smart, releases when work stops" does not — so letting it size
                // itself moved the whole panel on a mode change.
                Text(statusDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: 26, alignment: .topLeading)
            }
            Spacer(minLength: 8)
            // No switch here any more. The mode selector directly below *is* the
            // control, and a second one that sets the same state read as clutter and
            // invited the two to disagree.
            if snapshot.isAwakeHeld {
                Image(systemName: snapshot.isClamshellActive ? "laptopcomputer.slash" : "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
        }
    }

    private var statusColor: Color {
        if snapshot.overrideUntil != nil || snapshot.blockedBy != nil { return .orange }
        if snapshot.isClamshellActive { return .blue }
        return snapshot.isAwakeHeld ? .green : .secondary
    }

    /// "Holding back" is its own state, distinct from "Idle".
    ///
    /// Idle means nothing wants the Mac awake. Holding back means something does and
    /// the governor is refusing — which is what you are looking at when five leases are
    /// live, the ring is full, and the Mac is sleeping anyway.
    private var statusTitle: String {
        if snapshot.overrideUntil != nil { return "Keeping going" }
        if snapshot.blockedBy != nil { return "Holding back" }
        if snapshot.isClamshellActive { return "Protected, lid can close" }
        if snapshot.isAwakeHeld { return "Keeping awake" }
        return snapshot.isUserPaused ? "Paused by you" : "Idle"
    }

    private var statusDetail: String {
        if snapshot.overrideUntil != nil {
            return "Safety rules waived by you. Hard floor still applies"
        }
        if let blocked = snapshot.blockedBy {
            return "\(blocked.summary). Won't re-arm until it recovers"
        }
        // Named explicitly, because the alternative reads as a broken switch: with work
        // running, "off" and "off but five things want it on" look identical until the
        // panel says which one you are in.
        if snapshot.isUserPaused && !snapshot.isAwakeHeld {
            return snapshot.activeLease.isEmpty
                ? "Auto-watch won't turn this back on"
                : "\(snapshot.activeLease.count) running. Auto-watch won't turn this back on"
        }
        if let reason = snapshot.lastStopReason, !snapshot.isAwakeHeld {
            return "Last stop: \(reason.summary)"
        }
        return snapshot.mode == .manual ? "Manual hold" : "Smart, releases when work stops"
    }

    private var elapsedDisplay: String {
        let second = snapshot.runtimeSecond
        return second < 3600
            ? "\(second / 60)m"
            : "\(second / 3600)h \((second % 3600) / 60)m"
    }

    // MARK: - Gauges

    private var gaugeRow: some View {
        HStack(alignment: .top, spacing: 4) {
            batteryGauge
            thermalGauge
            sessionGauge
        }
    }

    private var batteryGauge: some View {
        let battery = snapshot.battery
        let percent = battery.percent
        return RingGauge(
            fraction: Double(percent ?? 100) / 100,
            color: Palette.batteryColor(
                percent: percent,
                setting: setting.softBatteryPercent,
                hard: setting.hardBatteryPercent,
                isOnMain: battery.isOnMain),
            content: percent.map { .number("\($0)", unit: "%") } ?? .symbol("powerplug.fill"),
            caption: battery.sourceDisplay
        )
    }

    private var thermalGauge: some View {
        let level = snapshot.thermal.level
        return RingGauge(
            // Nominal still shows a quarter ring: an empty circle reads as "no data"
            // rather than "cool".
            fraction: Double(level.rank + 1) / 4,
            color: Palette.color(for: level),
            // The word goes in the caption, not the ring — "Very hot" rendered straight
            // over the stroke when it lived inside the circle.
            content: .symbol("thermometer.medium"),
            caption: level.display.lowercased()
        )
    }

    /// One gauge, not an `if`/`else` pair.
    ///
    /// Two `RingGauge`s in separate branches are two *identities* to SwiftUI, so
    /// starting or ending a timer replaced the view instead of updating it — a
    /// transition where there should have been a value change. Computing the inputs
    /// keeps one view that simply changes what it shows.
    private var sessionGauge: some View {
        RingGauge(
            fraction: sessionFraction,
            color: sessionColor,
            content: sessionContent,
            caption: sessionCaption
        )
    }

    private var isTimed: Bool { snapshot.timerFraction != nil }

    private var sessionFraction: Double {
        if let fraction = snapshot.timerFraction { return 1 - fraction }
        return snapshot.activeLease.isEmpty ? 0 : 1
    }

    private var sessionColor: Color {
        if isTimed { return .blue }
        return snapshot.activeLease.isEmpty ? .secondary : .green
    }

    /// At most two digits and one unit character, always.
    ///
    /// The old format put `"7h59"` inside a 44pt circle with `minimumScaleFactor`. As
    /// the countdown changed the string — `"7h59"` → `"7h5"` → `"59"`+`"m"` — its width
    /// crossed the fit boundary, so SwiftUI rescaled the text every few seconds. Scaled
    /// text has a different height, and the row is baseline-aligned, so each rescale
    /// moved the glyph up or back down. That was the twitch: a countdown quietly
    /// resizing its own type.
    private var sessionContent: RingGauge.Content {
        guard let remaining = snapshot.remainingDisplay else {
            return .number("\(snapshot.activeLease.count)", unit: nil)
        }
        return .number(remaining.value, unit: remaining.unit)
    }

    /// The precision the ring gave up. A caption truncates when it does not fit, which
    /// is a failure mode that holds still.
    private var sessionCaption: String {
        guard let remaining = snapshot.remainingDisplay else {
            return snapshot.activeLease.count == 1 ? "live lease" : "live leases"
        }
        return remaining.caption
    }

    // MARK: - Session

    /// Tall enough for three lease rows and the "+N more" line, always.
    ///
    /// This is the fix for the panel resizing itself seconds after a click. Switching
    /// to Sleep releases every lease, so the list collapses from four rows to one line;
    /// switching back to Awake lets the watcher repopulate it ~10s later and it grows
    /// again. Four rows is about 60pt, so the window jumped by that much — twice —
    /// without the user touching anything in between.
    ///
    /// Reserving the space costs a little emptiness on an idle Mac and buys a panel
    /// whose size is a function of *what you opened*, not of what the watcher happened
    /// to find while you were reading it.
    /// 66, not 62: three 11pt rows (~13.2 each) plus two 4pt gaps, then a 4pt gap and
    /// the 9pt "+N more" line (~10.8) comes to ~62.4. Sized to the content it has to
    /// hold, with a little margin, rather than to a round number that clips it.
    private static let leaseListHeight: CGFloat = 66

    private var session: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Why awake", trailing: sparklineSpan)

            leaseList
                .frame(height: Self.leaseListHeight, alignment: .topLeading)

            Sparkline(
                value: model.recentSample.map { Double($0.leaseCount) },
                color: .green,
                barCount: AppModel.sparklineSampleCount
            )

            // Always laid out, only sometimes visible. A bar that appears when a timer
            // starts is another 12pt of window movement, and "Lid shut" starts an 8h
            // timer — so the mode with the biggest jump was the one that also had this.
            SegmentBar(fraction: snapshot.timerFraction ?? 0, color: .blue)
                .opacity(snapshot.timerFraction == nil ? 0 : 1)
        }
    }

    @ViewBuilder
    private var leaseList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if snapshot.activeLease.isEmpty {
                Text(snapshot.isAwakeHeld ? "Held manually, nothing tracked" : "Nothing running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Three, not the whole list: a busy machine can hold a dozen leases,
                // and the panel below this is the part worth scrolling to. The full
                // list is one `liddy lease` away.
                ForEach(snapshot.activeLease.prefix(3), id: \.self) { lease in
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                        Text(lease)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if snapshot.activeLease.count > 3 {
                    Text("+\(snapshot.activeLease.count - 3) more")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// How far back the sparkline actually reaches — an unlabelled strip invites the
    /// reader to guess, and they will guess wrong on a Mac that just woke up.
    private var sparklineSpan: String? {
        guard let first = model.recentSample.first else { return nil }
        let minute = Int(Date().timeIntervalSince(first.at) / 60)
        return minute < 1 ? "last minute" : "last \(minute)m"
    }

    // MARK: - Control

    /// Closed-lid needs root. Rather than let the switch be clicked and then answer
    /// with an error naming a shell script, the row states the prerequisite and offers
    /// to satisfy it — the app has the helper bundled, so the only thing it was ever
    /// missing was permission to ask.
    private var currentMode: ModeSelector.Mode {
        if snapshot.isClamshellActive { return .lid }
        return snapshot.isAwakeHeld ? .awake : .sleep
    }

    @ViewBuilder
    /// Only drawn while the helper is missing. "Lid shut" stays visible in the selector
    /// either way — hiding a capability is not the same as explaining it — and choosing
    /// it without the helper runs the install rather than throwing an error.
    private var helperRow: some View {
        Group {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lid shut needs the helper")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(model.isInstallingHelper ? "Installing…" : "A small root daemon, installed once")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if model.isInstallingHelper {
                    ProgressView().controlSize(.small)
                } else if HelperInstaller.canInstall {
                    Button("Install…") { model.installHelper() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Installs a root LaunchDaemon. macOS will ask for your password once.")
                } else {
                    Text("Script/install-helper.sh")
                        .font(.system(size: 9).monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var control: some View {
        VStack(alignment: .leading, spacing: 8) {
            ModeSelector(selection: currentMode) { model.select(mode: $0) }

            if let until = snapshot.overrideUntil {
                OverrideActiveBanner(until: until) { model.cancelOverride() }
            } else if let blocked = snapshot.blockedBy {
                OverrideBanner(reason: blocked, isBusy: false) { model.override(second: $0) }
            }

            if !model.isHelperReady { helperRow }

            HStack(spacing: 6) {
                ForEach([30 * 60, 3 * 3600, 8 * 3600], id: \.self) { second in
                    Button(second < 3600 ? "\(second / 60)m" : "\(second / 3600)h") {
                        model.hold(forSecond: second)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Keep awake for \(second < 3600 ? "\(second / 60) minutes" : "\(second / 3600) hours"), then release")
                }
                Spacer()
                Button {
                    model.refreshHealth()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Re-run every health check now")
            }
        }
    }

    // MARK: - Activity

    private var activity: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Unanimated on purpose — see the note in `HealthSection`.
            Button {
                model.isActivityExpanded.toggle()
            } label: {
                HStack {
                    SectionLabel(text: "Activity")
                    Image(systemName: model.isActivityExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if model.recentEntry.isEmpty {
                Text("Nothing yet").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(model.recentEntry.prefix(model.isActivityExpanded ? 10 : 3).enumerated()), id: \.offset) { _, entry in
                Text("\(entry.at.formatted(date: .omitted, time: .shortened))  \(entry.detail)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
