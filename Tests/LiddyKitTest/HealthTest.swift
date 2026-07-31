import XCTest
@testable import LiddyKit

/// The health panel's job is to be *believed*, so the parts that decide what is green
/// and what is red are the parts worth locking down.
final class HealthStateTest: XCTestCase {
    func testWorstWins() {
        let check = [
            HealthCheck(id: "a", group: .liddy, label: "A", state: .ok, detail: ""),
            HealthCheck(id: "b", group: .liddy, label: "B", state: .degraded, detail: ""),
            HealthCheck(id: "c", group: .liddy, label: "C", state: .ok, detail: ""),
        ]
        XCTAssertEqual(HealthReport.worst(of: check), .degraded)
    }

    /// Nine passing checks must not average away one broken one.
    func testOneDownBeatsEverythingElse() {
        var check = (0..<9).map {
            HealthCheck(id: "ok\($0)", group: .device, label: "ok", state: .ok, detail: "")
        }
        check.append(HealthCheck(id: "bad", group: .device, label: "bad", state: .down, detail: ""))
        XCTAssertEqual(HealthReport(check: check).overall, .down)
    }

    /// A check the user switched off must never drag the verdict down — that is the
    /// whole reason `.off` sorts below `.ok`.
    func testOffDoesNotDragTheVerdictDown() {
        let check = [
            HealthCheck(id: "a", group: .service, label: "A", state: .ok, detail: ""),
            HealthCheck(id: "b", group: .service, label: "B", state: .off, detail: ""),
        ]
        XCTAssertEqual(HealthReport(check: check).overall, .ok)
    }

    func testAllOffRollsUpToOff() {
        let check = [HealthCheck(id: "a", group: .service, label: "A", state: .off, detail: "")]
        XCTAssertEqual(HealthReport(check: check).overall, .off)
    }

    func testEmptyGroupIsOff() {
        XCTAssertEqual(HealthReport(check: []).state(of: .network), .off)
    }

    func testProblemIsWorstFirst() {
        let report = HealthReport(check: [
            HealthCheck(id: "a", group: .liddy, label: "A", state: .degraded, detail: ""),
            HealthCheck(id: "b", group: .liddy, label: "B", state: .down, detail: ""),
            HealthCheck(id: "c", group: .liddy, label: "C", state: .ok, detail: ""),
        ])
        XCTAssertEqual(report.problem.map(\.id), ["b", "a"])
    }
}

final class HealthProbeLocalTest: XCTestCase {
    private func context(_ mutate: (inout HealthContext) -> Void = { _ in }) -> HealthContext {
        var context = HealthContext(isSocketBound: true, setting: .default)
        mutate(&context)
        return context
    }

    /// The failure that looks fine and isn't: the menu says "keeping awake" while no
    /// assertion exists, so the Mac sleeps anyway mid-run.
    func testHoldWithoutAssertionIsDown() {
        let check = HealthProbe.liddyCheck(
            context: context {
                $0.isAwakeHeld = true
                $0.isAssertionActive = false
            },
            pmsetText: "")
        XCTAssertEqual(check.first { $0.id == "liddy.assertion" }?.state, .down)
    }

    func testAssertionWithoutHoldIsStale() {
        let check = HealthProbe.liddyCheck(
            context: context {
                $0.isAwakeHeld = false
                $0.isAssertionActive = true
            },
            pmsetText: "")
        XCTAssertEqual(check.first { $0.id == "liddy.assertion" }?.state, .degraded)
    }

    func testIdleWithNoAssertionIsFine() {
        let check = HealthProbe.liddyCheck(context: context(), pmsetText: "")
        XCTAssertEqual(check.first { $0.id == "liddy.assertion" }?.state, .ok)
    }

    /// The hazard `liddy doctor` was written for, now watched continuously.
    func testStrandedDisableSleepIsDown() {
        let check = HealthProbe.liddyCheck(
            context: context { $0.isClamshellActive = false },
            pmsetText: " disablesleep         1\n")
        XCTAssertEqual(check.first { $0.id == "liddy.sleep" }?.state, .down)
    }

    func testDisableSleepDuringClamshellIsExpected() {
        let check = HealthProbe.liddyCheck(
            context: context { $0.isClamshellActive = true },
            pmsetText: " disablesleep         1\n")
        XCTAssertEqual(check.first { $0.id == "liddy.sleep" }?.state, .ok)
    }

    /// Closed-lid on while the kernel says sleep is allowed means the protection the
    /// UI is claiming does not exist.
    func testClamshellWithoutDisableSleepIsDown() {
        let check = HealthProbe.liddyCheck(
            context: context { $0.isClamshellActive = true },
            pmsetText: "")
        XCTAssertEqual(check.first { $0.id == "liddy.sleep" }?.state, .down)
    }

    func testAbsentDisableSleepRowMeansNormalSleep() {
        let check = HealthProbe.liddyCheck(
            context: context(),
            pmsetText: "Active Profiles:\nBattery Power  -1\n")
        XCTAssertEqual(check.first { $0.id == "liddy.sleep" }?.state, .ok)
    }

    func testUnboundSocketIsDown() {
        let check = HealthProbe.liddyCheck(context: context { $0.isSocketBound = false }, pmsetText: "")
        XCTAssertEqual(check.first { $0.id == "liddy.socket" }?.state, .down)
    }

    /// A missing helper is only a problem for the feature that needs it.
    func testMissingHelperIsOffNotBroken() {
        let check = HealthProbe.liddyCheck(context: context(), pmsetText: "")
        let helper = check.first { $0.id == "liddy.helper" }
        XCTAssertNotNil(helper)
        if !FileManager.default.fileExists(atPath: "/usr/local/libexec/liddy-helper") {
            XCTAssertEqual(helper?.state, .off)
        }
    }

    func testBatteryBelowHardFloorIsDown() {
        let check = HealthProbe.deviceCheck(context: context {
            $0.battery = BatteryReading(percent: 3, isCharging: false, isOnMain: false)
        })
        XCTAssertEqual(check.first { $0.id == "device.battery" }?.state, .down)
    }

    func testBatteryBelowSoftFloorIsDegraded() {
        let check = HealthProbe.deviceCheck(context: context {
            $0.battery = BatteryReading(percent: 15, isCharging: false, isOnMain: false)
        })
        XCTAssertEqual(check.first { $0.id == "device.battery" }?.state, .degraded)
    }

    /// The soft floor only ends a run on battery — plugged in at 15% is heading up,
    /// not down, so it must not read as a problem.
    func testLowBatteryOnMainsIsFine() {
        let check = HealthProbe.deviceCheck(context: context {
            $0.battery = BatteryReading(percent: 15, isCharging: true, isOnMain: true)
        })
        XCTAssertEqual(check.first { $0.id == "device.battery" }?.state, .ok)
    }

    func testNoBatteryIsOffNotBroken() {
        let check = HealthProbe.deviceCheck(context: context { $0.battery = .unknown })
        XCTAssertEqual(check.first { $0.id == "device.battery" }?.state, .off)
    }

    func testThermalAtCeilingIsDown() {
        let check = HealthProbe.deviceCheck(context: context {
            $0.thermal = ThermalReading(level: .critical)
            $0.setting.thermalCeiling = .critical
        })
        XCTAssertEqual(check.first { $0.id == "device.thermal" }?.state, .down)
    }

    func testHotBelowCeilingIsDegraded() {
        let check = HealthProbe.deviceCheck(context: context {
            $0.thermal = ThermalReading(level: .serious)
            $0.setting.thermalCeiling = .critical
        })
        XCTAssertEqual(check.first { $0.id == "device.thermal" }?.state, .degraded)
    }

    /// Charging-only turns the same reading into a stop condition, so it has to read
    /// differently depending on the setting.
    func testOnBatteryIsDegradedOnlyWhenChargingOnly() {
        let onBattery = BatteryReading(percent: 80, isCharging: false, isOnMain: false)
        let relaxed = HealthProbe.deviceCheck(context: context { $0.battery = onBattery })
        XCTAssertEqual(relaxed.first { $0.id == "device.power" }?.state, .ok)

        let strict = HealthProbe.deviceCheck(context: context {
            $0.battery = onBattery
            $0.setting.isChargingOnly = true
        })
        XCTAssertEqual(strict.first { $0.id == "device.power" }?.state, .degraded)
    }

    func testNoLinkIsDown() {
        let check = HealthProbe.linkCheck(path: .unknown)
        XCTAssertEqual(check.first?.state, .down)
    }

    func testLinkNamesTheInterface() {
        let check = HealthProbe.linkCheck(path: NetworkPathReading(
            isSatisfied: true, interface: .wifi, isExpensive: false, isConstrained: false))
        XCTAssertEqual(check.first?.state, .ok)
        XCTAssertEqual(check.first?.detail, "Wi-Fi")
    }

    /// The session refuses expensive and constrained networks, so on a hotspot every
    /// request fails at the client. Reporting that as a service outage would be a lie
    /// about a service that was never contacted.
    func testMeteredLinkSkipsRemoteProbeRatherThanFailingThem() async {
        let probe = HealthProbe(path: NetworkPathObserver())
        let check = await probe.remoteCheckForTest(
            context: HealthContext(setting: .default),
            path: NetworkPathReading(
                isSatisfied: true, interface: .cellular, isExpensive: true, isConstrained: false))
        XCTAssertEqual(check.first?.state, .off)
        XCTAssertTrue(check.first?.detail.contains("metered") == true)
        XCTAssertFalse(check.contains { $0.state == .down }, "nothing was asked, so nothing is down")
    }

    func testLowDataModeAlsoSkips() async {
        let probe = HealthProbe(path: NetworkPathObserver())
        let check = await probe.remoteCheckForTest(
            context: HealthContext(setting: .default),
            path: NetworkPathReading(
                isSatisfied: true, interface: .wifi, isExpensive: false, isConstrained: true))
        XCTAssertEqual(check.first?.state, .off)
        XCTAssertTrue(check.first?.detail.contains("low data") == true)
    }

    func testOfflineSkipsRemoteProbe() async {
        let probe = HealthProbe(path: NetworkPathObserver())
        let check = await probe.remoteCheckForTest(
            context: HealthContext(setting: .default), path: .unknown)
        XCTAssertEqual(check.first?.state, .off)
        XCTAssertTrue(check.first?.detail.contains("no link") == true)
    }

    func testMeteredLinkIsFlaggedButStillUp() {
        let check = HealthProbe.linkCheck(path: NetworkPathReading(
            isSatisfied: true, interface: .cellular, isExpensive: true, isConstrained: false))
        XCTAssertEqual(check.first?.state, .ok)
        XCTAssertTrue(check.first?.detail.contains("metered") == true)
    }
}

/// The flap filter is the reason the panel is worth believing, so it gets its own
/// coverage. Observed in practice: the first sweep after launch pays for a cold DNS
/// cache and a cold TLS handshake, and without this every launch showed a red row that
/// was green thirty seconds later.
final class HealthFlapFilterTest: XCTestCase {
    private func probe() -> HealthProbe { HealthProbe(path: NetworkPathObserver()) }

    private func check(_ state: HealthState, detail: String = "boom") -> HealthCheck {
        HealthCheck(id: "service.x", group: .service, label: "X", state: state, detail: detail)
    }

    func testFirstFailureIsSoftenedToDegraded() async {
        let filtered = await probe().settledForTest(check(.down))
        XCTAssertEqual(filtered.state, .degraded)
        XCTAssertTrue(filtered.detail.contains("retrying"))
    }

    func testSecondConsecutiveFailureEscalatesToDown() async {
        let probe = probe()
        _ = await probe.settledForTest(check(.down))
        let second = await probe.settledForTest(check(.down))
        XCTAssertEqual(second.state, .down)
    }

    /// A hiccup that fixes itself must reset the count, or the next unrelated blip
    /// would escalate immediately.
    func testRecoveryResetsTheCount() async {
        let probe = probe()
        _ = await probe.settledForTest(check(.down))
        _ = await probe.settledForTest(check(.ok))
        let afterRecovery = await probe.settledForTest(check(.down))
        XCTAssertEqual(afterRecovery.state, .degraded, "a fresh failure starts at one strike again")
    }

    func testPassingChecksAreUntouched() async {
        let filtered = await probe().settledForTest(check(.ok, detail: "reachable"))
        XCTAssertEqual(filtered.state, .ok)
        XCTAssertEqual(filtered.detail, "reachable")
    }

    /// Each check counts its own strikes — a broken status page must not escalate the
    /// API check next to it.
    func testStrikesAreCountedPerCheck() async {
        let probe = probe()
        _ = await probe.settledForTest(check(.down))
        let other = HealthCheck(
            id: "service.y", group: .service, label: "Y", state: .down, detail: "boom")
        let filtered = await probe.settledForTest(other)
        XCTAssertEqual(filtered.state, .degraded)
    }
}

final class ResolveOutcomeTest: XCTestCase {
    /// A name that cannot exist: the resolver answers, and the answer is "no".
    func testNonexistentHostFails() async {
        let outcome = await HealthProbe.resolve("liddy-does-not-exist.invalid")
        XCTAssertEqual(outcome, .failed, "an authoritative NXDOMAIN is a failure, not a timeout")
    }

    func testLocalhostResolves() async {
        let outcome = await HealthProbe.resolve("localhost")
        XCTAssertEqual(outcome, .resolved)
    }
}

final class ServiceEndpointTest: XCTestCase {
    /// An idle Mac makes exactly one outbound request, not four.
    func testIdleProbesOnlyTheAlwaysOnEndpoint() {
        let selected = ServiceEndpoint.selected(forLease: [])
        XCTAssertEqual(selected.map(\.id), ["anthropic"])
    }

    func testLeaseLabelPullsInItsProvider() {
        let selected = ServiceEndpoint.selected(forLease: ["Codex · liddy"])
        XCTAssertEqual(Set(selected.map(\.id)), ["anthropic", "openai"])
    }

    func testMatchingIsCaseInsensitive() {
        let selected = ServiceEndpoint.selected(forLease: ["CURSOR agent"])
        XCTAssertTrue(selected.contains { $0.id == "cursor" })
    }

    func testUnrelatedLeaseAddsNothing() {
        let selected = ServiceEndpoint.selected(forLease: ["xcodebuild", "ffmpeg"])
        XCTAssertEqual(selected.map(\.id), ["anthropic"])
    }
}

final class AgentStatusTest: XCTestCase {
    private func report(_ check: HealthCheck...) -> HealthReport { HealthReport(check: check) }

    func testEveryKnownAgentGetsARow() {
        let status = AgentStatus.build(activeLease: [], health: nil)
        XCTAssertEqual(status.count, ServiceEndpoint.known.count)
        XCTAssertTrue(status.allSatisfy { !$0.isWorking })
    }

    func testLeaseMarksTheRightAgentWorking() {
        let status = AgentStatus.build(activeLease: ["Claude Code · liddy"], health: nil)
        XCTAssertEqual(status.first { $0.id == "anthropic" }?.isWorking, true)
        XCTAssertEqual(status.first { $0.id == "openai" }?.isWorking, false)
    }

    /// The panel is read top-down, so what is running now has to be at the top.
    func testWorkingAgentSortFirst() {
        let status = AgentStatus.build(activeLease: ["cursor-agent"], health: nil)
        XCTAssertEqual(status.first?.id, "cursor")
    }

    func testTwoAgentsCanWorkAtOnce() {
        let status = AgentStatus.build(activeLease: ["claude", "codex"], health: nil)
        XCTAssertEqual(Set(status.filter(\.isWorking).map(\.id)), ["anthropic", "openai"])
    }

    func testLeaseCountShowsInTheWorkLabel() {
        let status = AgentStatus.build(
            activeLease: ["Claude Code · a", "Claude Code · b"], health: nil)
        XCTAssertEqual(status.first { $0.id == "anthropic" }?.workDisplay, "working ×2")
    }

    func testIdleAgentSaysIdle() {
        let status = AgentStatus.build(activeLease: [], health: nil)
        XCTAssertEqual(status.first { $0.id == "xai" }?.workDisplay, "idle")
    }

    func testServiceCheckIsAttachedToItsAgent() {
        let health = report(HealthCheck(
            id: "service.anthropic", group: .service, label: "Claude",
            state: .ok, detail: "reachable", latencyMillisecond: 42))
        let status = AgentStatus.build(activeLease: [], health: health)
        let claude = status.first { $0.id == "anthropic" }
        XCTAssertEqual(claude?.serviceState, .ok)
        XCTAssertEqual(claude?.serviceDisplay, "API ok · 42ms")
    }

    /// An unprobed agent must not masquerade as healthy — no dot, not a green one.
    func testUnprobedAgentHasNoServiceState() {
        let status = AgentStatus.build(activeLease: [], health: report())
        let grok = status.first { $0.id == "xai" }
        XCTAssertNil(grok?.serviceState)
        XCTAssertEqual(grok?.serviceDisplay, "not checked")
    }

    func testDownServiceIsSpelledOut() {
        let health = report(HealthCheck(
            id: "service.openai", group: .service, label: "Codex", state: .down, detail: "boom"))
        let status = AgentStatus.build(activeLease: ["codex"], health: health)
        XCTAssertEqual(status.first { $0.id == "openai" }?.serviceDisplay, "API unreachable")
    }

    /// The case the split exists for: working hard against an API that is down.
    func testWorkingAndDownAreReportedIndependently() {
        let health = report(HealthCheck(
            id: "service.anthropic", group: .service, label: "Claude", state: .down, detail: "boom"))
        let claude = AgentStatus.build(activeLease: ["claude"], health: health)
            .first { $0.id == "anthropic" }
        XCTAssertEqual(claude?.isWorking, true)
        XCTAssertEqual(claude?.serviceState, .down)
    }
}

final class ServiceStatusPageTest: XCTestCase {
    func testOperationalParsesAsOk() {
        let body = Data("""
        {"status":{"indicator":"none","description":"All Systems Operational"}}
        """.utf8)
        let parsed = ServiceStatusPage.parse(body)
        XCTAssertEqual(parsed?.state, .ok)
        XCTAssertEqual(parsed?.description, "All Systems Operational")
    }

    func testMinorIsDegradedAndMajorIsDown() {
        XCTAssertEqual(ServiceStatusPage.state(forIndicator: "minor"), .degraded)
        XCTAssertEqual(ServiceStatusPage.state(forIndicator: "major"), .down)
        XCTAssertEqual(ServiceStatusPage.state(forIndicator: "critical"), .down)
    }

    /// An unrecognised indicator must not be reported as healthy.
    func testUnknownIndicatorIsNotOk() {
        XCTAssertEqual(ServiceStatusPage.state(forIndicator: "wat"), .unknown)
    }

    func testGarbageBodyParsesToNil() {
        XCTAssertNil(ServiceStatusPage.parse(Data("not json".utf8)))
        XCTAssertNil(ServiceStatusPage.parse(Data("{}".utf8)))
    }
}
