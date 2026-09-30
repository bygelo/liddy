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

    /// Fixed. The window never resizes — see `PanelTab` for the four bugs that came
    /// from a panel whose height was a function of its content.
    ///
    /// 330 is what the tallest *page* needs (Now, with four rings, the sparkline and
    /// two rows of session pills). Pages that want more than this scroll inside the
    /// page rather than growing the window.
    /// One height for every page. The window is the same size always.
    ///
    /// Per-page heights were tried first and removed: they made the panel change shape
    /// as you clicked between pages, which is its own kind of jumping around even
    /// though each page was individually stable. A menu-bar panel should be one shape.
    ///
    /// The number is what the tallest page (Health) needs. The shorter pages are given
    /// more to show rather than padded with empty panel — six processes instead of
    /// three, nine session pills instead of six, a longer activity log — so the space
    /// is used rather than left blank.
    /// `LIDDY_PAGE_NATURAL=1` drops the fixed frame so each page can be measured at
    /// the height its own content wants — which is where the constants below came from.
    static var isMeasuringNaturalHeight: Bool {
        ProcessInfo.processInfo.environment["LIDDY_PAGE_NATURAL"] == "1"
    }

    private static let pageHeight: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if Self.isMeasuringNaturalHeight {
                page
            } else {
                page
                    .frame(height: Self.pageHeight, alignment: .top)
                    .clipped()
            }

            Divider().opacity(0.4)

            PanelTabBar(
                selection: $model.tab,
                healthProblemCount: snapshot.health?.problem.count ?? 0,
                onQuit: {
                    model.shutdown()
                    NSApplication.shared.terminate(nil)
                })
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: 300)
        // Nothing in this panel animates, by rule.
        //
        // It is a readout you open for four seconds, so motion adds no information —
        // and every animation tried here has cost something. The countdown ring was the
        // worst: `timerFraction` is recomputed from `Date()` on every render, so an
        // eased arc re-animated on each redraw and the ring never settled.
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private var page: some View {
        switch model.tab {
        case .now:
            VStack(alignment: .leading, spacing: 5) {
                Card { control }
                Card(horizontal: 4, top: 10, bottom: 7) { metric }
                Card { SessionSection(model: model) }
            }
        case .apps:
            VStack(alignment: .leading, spacing: 5) {
                Card { load(limit: 6) }
                Card { SessionSection(model: model) }
                Spacer(minLength: 0)
            }
        case .health:
            // The one page that can outgrow the window, on a machine with a lot of
            // checks. It scrolls; the window does not move.
            ScrollView(.vertical, showsIndicators: false) {
                Card { HealthSection(model: model, isExpanded: .constant(true)) }
            }
        case .setting:
            ScrollView(.vertical, showsIndicators: false) {
                Card { SettingSection(model: model, isExpanded: .constant(true)) }
            }
        case .activity:
            Card { activity }
        }
    }

    /// "34m" / "2h 5m". Lives on the mode selector's caption line now that the header
    /// card is gone.
    private var elapsedDisplay: String {
        let second = snapshot.runtimeSecond
        return second < 3600
            ? "\(second / 60)m"
            : "\(second / 3600)h \((second % 3600) / 60)m"
    }

    // MARK: - Gauges

    private var gaugeRow: some View {
        HStack(alignment: .top, spacing: 0) {
            batteryGauge
            thermalGauge
            cpuGauge
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

    /// Degrees in the ring, the pressure word underneath.
    ///
    /// It used to be a thermometer glyph over the word "fair", which is where "the
    /// temperature is not accurate" came from: `thermalState` is a throttling-pressure
    /// signal, not a temperature, and it sits at `fair` on a machine whose die is at
    /// 38°C. Both are now shown, and they are no longer pretending to be each other —
    /// the number is the die, the word is still what the governor acts on.
    private var thermalGauge: some View {
        let thermal = snapshot.thermal
        return RingGauge(
            // Filled against 90°C, the point at which Apple silicon starts throttling
            // hard. Falls back to the four-step rank when no sensor answered.
            fraction: thermal.celsius.map { min(1, $0 / 90) } ?? Double(thermal.level.rank + 1) / 4,
            color: Palette.temperatureColor(thermal.celsius, level: thermal.level),
            content: thermal.celsius.map { .number("\(Int($0.rounded()))", unit: "°") }
                ?? .symbol("thermometer.medium"),
            caption: thermal.level.display.lowercased()
        )
    }

    /// The fourth ring. Three readings could not answer "is something pinning this
    /// machine" — the temperature says it is hot, and the load says what is doing it.
    private var cpuGauge: some View {
        let percent = snapshot.cpuPercent
        return RingGauge(
            fraction: (percent ?? 0) / 100,
            color: Palette.loadColor(percent ?? 0),
            content: percent.map { .number("\(Int($0.rounded()))", unit: "%") } ?? .symbol("cpu"),
            caption: "cpu"
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

    // MARK: - Metrics

    /// The three rings, the lease sparkline and the session timer, in one block.
    ///
    /// "Why awake" used to be a section of its own: a label, up to three lease rows, a
    /// "+N more" line, a sparkline and a progress bar. But the third ring already counts
    /// the live leases and the Sessions card below already names what is running, so the
    /// list was the same fact written a third time — and it was the single tallest thing
    /// on the panel. What is kept is the part the rings cannot show: the shape of the
    /// last few minutes, and how far through a timed session you are.
    private var metric: some View {
        VStack(alignment: .leading, spacing: 6) {
            gaugeRow

            Sparkline(
                value: model.recentSample.map { Double($0.leaseCount) },
                color: .green,
                barCount: AppModel.sparklineSampleCount)

            // Always laid out, only sometimes visible: a bar that appears when a timer
            // starts is another 12pt of window movement, and "Lid shut" starts an 8h
            // timer — so the mode with the biggest jump was the one that also had this.
            SegmentBar(fraction: snapshot.timerFraction ?? 0, color: .blue)
                .opacity(snapshot.timerFraction == nil ? 0 : 1)
        }
    }

    // MARK: - Health, when the panel is off

    private var hasHealthProblem: Bool {
        !(snapshot.health?.problem.isEmpty ?? true)
    }

    /// The whole health section, reduced to one line.
    ///
    /// The checks still run with the panel off — the menu-bar glyph still becomes a
    /// warning triangle — but a wall of green rows nobody reads is the text that was
    /// asked to go. A *failing* check is never hidden: it appears here, and tapping it
    /// turns the full panel back on.
    @ViewBuilder
    private var healthWarning: some View {
        if let report = snapshot.health, !report.problem.isEmpty {
            Button { model.updateSetting(SettingPatch(isHealthPanelOn: true)) } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Palette.color(for: report.overall))
                        .frame(width: 6, height: 6)
                    Text(report.problem.count == 1
                         ? report.problem[0].label
                         : "\(report.problem.count) checks need attention")
                        .font(.system(size: 11))
                    Spacer(minLength: 4)
                    Text("show")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Load

    /// Who is actually eating the machine.
    ///
    /// The panel's standing rule is that every reading on it can end a hold, and this
    /// one cannot — it is here because the user asked to see what is hampering
    /// performance. It reads, it never decides: a CPU threshold driving the hold is
    /// rejected in the README and stays rejected.
    private func load(limit: Int = 3) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(text: "Using the most", trailing: backgroundedSummary)

            ForEach(snapshot.topLoad.prefix(limit), id: \.pid) { entry in
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if snapshot.backgroundedApp.contains(where: { $0.caseInsensitiveCompare(entry.name) == .orderedSame }) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .help("Backgrounded by Liddy for the duration of this hold")
                    }
                    Spacer(minLength: 6)
                    Text("\(Int(entry.cpuPercent.rounded()))%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Palette.loadColor(entry.cpuPercent))
                    Text("\(Int(entry.memoryPercent.rounded()))%")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 26, alignment: .trailing)
                        .help("Share of physical memory")
                }
            }
        }
    }

    private var backgroundedSummary: String? {
        let count = snapshot.backgroundedApp.count
        guard count > 0 else { return snapshot.dimmedFrom != nil ? "screen off" : nil }
        return count == 1 ? "1 backgrounded" : "\(count) backgrounded"
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
        VStack(alignment: .leading, spacing: 5) {
            ModeSelector(
                selection: currentMode,
                elapsed: snapshot.isAwakeHeld ? elapsedDisplay : nil,
                blocked: snapshot.blockedBy.map { "\($0.summary). Won't re-arm until it recovers" }
            ) { model.select(mode: $0) }

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

    /// The activity log. Always open — it is a page now, not a disclosure.
    private var activity: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(text: "Activity")

            if model.recentEntry.isEmpty {
                Text("Nothing yet").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(model.recentEntry.prefix(12).enumerated()), id: \.offset) { _, entry in
                Text("\(entry.at.formatted(date: .omitted, time: .shortened))  \(entry.detail)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }
}
