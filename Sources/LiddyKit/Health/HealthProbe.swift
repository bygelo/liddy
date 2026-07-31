import Foundation

/// Local state the probe cannot discover on its own, handed in by the runtime.
public struct HealthContext: Sendable {
    public var isAwakeHeld: Bool
    public var isAssertionActive: Bool
    public var isClamshellActive: Bool
    public var isSocketBound: Bool
    /// Whether the app currently holds a live helper connection. See the note in
    /// `liddyCheck` for why the probe reads this instead of dialling the helper.
    public var isHelperConnected: Bool
    public var helperVersion: String?
    public var activeLease: [String]
    public var battery: BatteryReading
    public var thermal: ThermalReading
    public var setting: Setting

    public init(
        isAwakeHeld: Bool = false,
        isAssertionActive: Bool = false,
        isClamshellActive: Bool = false,
        isSocketBound: Bool = false,
        isHelperConnected: Bool = false,
        helperVersion: String? = nil,
        activeLease: [String] = [],
        battery: BatteryReading = .unknown,
        thermal: ThermalReading = .init(level: .nominal),
        setting: Setting = .default
    ) {
        self.isAwakeHeld = isAwakeHeld
        self.isAssertionActive = isAssertionActive
        self.isClamshellActive = isClamshellActive
        self.isSocketBound = isSocketBound
        self.isHelperConnected = isHelperConnected
        self.helperVersion = helperVersion
        self.activeLease = activeLease
        self.battery = battery
        self.thermal = thermal
        self.setting = setting
    }
}

/// Runs every check behind the health panel.
///
/// Split in two on purpose: `localCheck` is pure-ish, instant and always safe to run,
/// while `remoteCheck` touches the network and is skipped entirely when the user turns
/// probing off. The panel therefore always has something true to draw, even offline.
public actor HealthProbe {
    private let path: NetworkPathObserver
    private let session: URLSession
    /// Previous verdict per remote check, for the flap filter in `settled`.
    private var lastRemoteState: [String: HealthState] = [:]

    public init(path: NetworkPathObserver) {
        self.path = path
        let config = URLSessionConfiguration.ephemeral
        // Generous on purpose. The first sweep after launch pays for a cold DNS cache
        // and a cold TLS handshake, and measured together those ran to ~3.6s on a
        // healthy connection — a tighter budget turns every app launch into a red row.
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    public func run(context: HealthContext) async -> HealthReport {
        let reading = path.reading
        var check = Self.localCheck(context: context, path: reading)
        if context.setting.isNetworkProbeOn {
            check += await remoteCheck(context: context, path: reading)
        } else {
            check.append(HealthCheck(
                id: "service.probe", group: .service, label: "Service probe",
                state: .off, detail: "network checks off. Turn on with liddy set --network-probe on"))
        }
        return HealthReport(check: check, at: Date())
    }

    // MARK: - Local

    /// Everything answerable without a packet. Pure apart from `pmset` and two
    /// filesystem reads, which makes it cheap enough to run on every panel open.
    public static func localCheck(
        context: HealthContext,
        path: NetworkPathReading,
        pmsetText: String? = nil
    ) -> [HealthCheck] {
        liddyCheck(context: context, pmsetText: pmsetText)
            + deviceCheck(context: context)
            + linkCheck(path: path)
    }

    static func liddyCheck(context: HealthContext, pmsetText: String? = nil) -> [HealthCheck] {
        var check: [HealthCheck] = []

        check.append(HealthCheck(
            id: "liddy.socket", group: .liddy, label: "CLI socket",
            state: context.isSocketBound ? .ok : .down,
            detail: context.isSocketBound
                ? LiddyPath.appSocket.path
                : "not bound. The liddy command cannot reach the app"))

        // A hold with no assertion behind it is the one failure that looks fine and
        // isn't: the menu says "keeping awake" while the Mac quietly sleeps anyway.
        let assertionState: HealthState
        let assertionDetail: String
        switch (context.isAwakeHeld, context.isAssertionActive) {
        case (true, true):
            assertionState = .ok
            assertionDetail = "held"
        case (true, false):
            assertionState = .down
            assertionDetail = "hold is on but no power assertion. Your Mac can still sleep"
        case (false, true):
            assertionState = .degraded
            assertionDetail = "assertion still active with no hold, stale"
        case (false, false):
            assertionState = .ok
            assertionDetail = "idle"
        }
        check.append(HealthCheck(
            id: "liddy.assertion", group: .liddy, label: "Power assertion",
            state: assertionState, detail: assertionDetail))

        // The probe reads the *existing* helper connection rather than opening its own.
        // Dialling the helper socket and hanging up is what makes `liddy doctor` revert
        // an active closed-lid session (the helper treats any closed connection as "the
        // app died"), and a health panel that refreshes on a timer would do it every 30
        // seconds. Filesystem checks plus the live connection's own state are enough.
        let isBinaryPresent = FileManager.default.fileExists(atPath: "/usr/local/libexec/liddy-helper")
        let isHelperUp = FileManager.default.fileExists(atPath: LiddyPath.helperSocketPath)
        let helperState: HealthState
        let helperDetail: String
        if !isBinaryPresent {
            helperState = .off
            helperDetail = "not installed, needed only for closed-lid"
        } else if !isHelperUp {
            helperState = context.isClamshellActive ? .down : .degraded
            helperDetail = "installed but not running"
        } else if context.isClamshellActive {
            helperState = context.isHelperConnected ? .ok : .down
            helperDetail = context.isHelperConnected
                ? "connected\(context.helperVersion.map { " · v\($0)" } ?? "") · heartbeat armed"
                : "closed-lid on but the connection is gone"
        } else {
            helperState = .ok
            helperDetail = "running · idle"
        }
        check.append(HealthCheck(
            id: "liddy.helper", group: .liddy, label: "Helper daemon",
            state: helperState, detail: helperDetail))

        let text = pmsetText ?? PmsetReader.output()
        let isDisableSleepOn = PmsetReader.isDisableSleepOn(text)
        let sleepState: HealthState
        let sleepDetail: String
        switch (isDisableSleepOn, context.isClamshellActive) {
        case (false, false): sleepState = .ok;       sleepDetail = "normal sleep"
        case (true, true):   sleepState = .ok;       sleepDetail = "disablesleep 1, closed-lid, watched"
        case (true, false):  sleepState = .down;     sleepDetail = "disablesleep 1 with nothing watching it"
        case (false, true):  sleepState = .down;     sleepDetail = "closed-lid on but disablesleep is 0"
        }
        check.append(HealthCheck(
            id: "liddy.sleep", group: .liddy, label: "Sleep policy",
            state: sleepState, detail: sleepDetail))

        let isHookInstalled = isClaudeHookInstalled()
        check.append(HealthCheck(
            id: "liddy.hook", group: .liddy, label: "Claude Code hook",
            state: isHookInstalled ? .ok : .off,
            detail: isHookInstalled ? "installed, holds per turn" : "not installed. Run liddy hook install"))

        return check
    }

    /// Reads the user's Claude Code settings for a hook pointing at this binary.
    public static func isClaudeHookInstalled() -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hook = root["hooks"] as? [String: Any]
        else { return false }

        for (_, value) in hook {
            guard let group = value as? [[String: Any]] else { continue }
            for entry in group {
                guard let inner = entry["hooks"] as? [[String: Any]] else { continue }
                if inner.contains(where: { ($0["command"] as? String)?.contains("liddy hook") == true }) {
                    return true
                }
            }
        }
        return false
    }

    static func deviceCheck(context: HealthContext) -> [HealthCheck] {
        var check: [HealthCheck] = []
        let setting = context.setting
        let battery = context.battery

        if let percent = battery.percent {
            let state: HealthState
            let detail: String
            if percent < setting.hardBatteryPercent {
                state = .down
                detail = "\(percent)%, below the \(setting.hardBatteryPercent)% hard floor"
            } else if percent < setting.softBatteryPercent && !battery.isOnMain {
                state = .degraded
                detail = "\(percent)%, below the \(setting.softBatteryPercent)% soft floor"
            } else {
                state = .ok
                detail = "\(percent)% · \(battery.sourceDisplay)"
            }
            check.append(HealthCheck(
                id: "device.battery", group: .device, label: "Battery", state: state, detail: detail))
        } else {
            check.append(HealthCheck(
                id: "device.battery", group: .device, label: "Battery",
                state: .off, detail: "no internal battery"))
        }

        let thermal = context.thermal.level
        let thermalState: HealthState
        if thermal >= setting.thermalCeiling {
            thermalState = .down
        } else if thermal >= .serious {
            thermalState = .degraded
        } else {
            thermalState = .ok
        }
        check.append(HealthCheck(
            id: "device.thermal", group: .device, label: "Thermal",
            state: thermalState,
            detail: "\(thermal.display) · ceiling \(setting.thermalCeiling.display)"))

        // Charging-only turns "on battery" from a fact into a stop condition, so the
        // same reading has to read differently depending on the setting.
        let powerState: HealthState = (setting.isChargingOnly && !battery.isOnMain) ? .degraded : .ok
        check.append(HealthCheck(
            id: "device.power", group: .device, label: "Power source",
            state: powerState,
            detail: battery.isOnMain
                ? "mains"
                : (setting.isChargingOnly ? "on battery, charging-only is on" : "on battery")))

        if let free = freeDiskByte() {
            let gigabyte = Double(free) / 1_073_741_824
            let state: HealthState = gigabyte < 2 ? .down : (gigabyte < 10 ? .degraded : .ok)
            check.append(HealthCheck(
                id: "device.disk", group: .device, label: "Disk",
                state: state, detail: String(format: "%.1f GB free", gigabyte)))
        }

        return check
    }

    /// Free space on the volume the user's home lives on — the one a long unattended
    /// build or agent run actually fills.
    static func freeDiskByte() -> Int64? {
        let url = FileManager.default.homeDirectoryForCurrentUser
        let value = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return value?.volumeAvailableCapacityForImportantUsage
    }

    static func linkCheck(path: NetworkPathReading) -> [HealthCheck] {
        var detail = path.interface.display
        if path.isExpensive { detail += " · metered" }
        if path.isConstrained { detail += " · low data mode" }
        return [HealthCheck(
            id: "network.link", group: .network, label: "Link",
            state: path.isSatisfied ? .ok : .down,
            detail: path.isSatisfied ? detail : "no route to the internet")]
    }

    // MARK: - Remote

    /// Takes the path reading rather than re-reading the observer, so a test can state
    /// the network conditions instead of having to be on a hotspot to check them.
    func remoteCheckForTest(context: HealthContext, path: NetworkPathReading) async -> [HealthCheck] {
        await remoteCheck(context: context, path: path)
    }

    private func remoteCheck(context: HealthContext, path: NetworkPathReading) async -> [HealthCheck] {
        // Offline is already reported by the link check; probing anyway would just add
        // four identical red rows and a four-second stall.
        guard path.isSatisfied else {
            return [HealthCheck(
                id: "network.dns", group: .network, label: "DNS",
                state: .off, detail: "skipped, no link")]
        }

        // The session is configured to refuse expensive and constrained networks, so on
        // a personal hotspot or in Low Data Mode every request fails at the *client*.
        // Reporting that as "API unreachable" would be a flat lie about the service —
        // it was never asked. Not probing at all is the honest answer, and it is also
        // the polite one: a keep-awake utility should not spend someone's tethered data
        // on reachability checks.
        guard !path.isExpensive, !path.isConstrained else {
            let reason = path.isExpensive ? "metered connection" : "low data mode"
            return [HealthCheck(
                id: "network.dns", group: .network, label: "DNS",
                state: .off, detail: "skipped, \(reason)")]
        }

        async let dns = dnsCheck()
        let endpoint = ServiceEndpoint.selected(forLease: context.activeLease)

        var check = [await dns]
        check += await withTaskGroup(of: HealthCheck.self) { group in
            for target in endpoint {
                group.addTask { await self.endpointCheck(target) }
            }
            group.addTask { await self.statusPageCheck() }
            var collected: [HealthCheck] = []
            for await one in group { collected.append(one) }
            return collected.sorted { $0.id < $1.id }
        }
        return check.map(settled)
    }

    /// Two strikes before a remote check is called down.
    ///
    /// Networks are lossy in ways that local state is not: one dropped handshake, a
    /// Wi-Fi roam, or a laptop waking up is not an outage, but it looks exactly like
    /// one to a single request. Reporting the first failure as `.degraded` and only
    /// escalating when the next sweep agrees is what keeps the panel worth believing —
    /// and it is what stops a 3am notification firing over a hiccup that fixed itself
    /// thirty seconds later.
    private func settled(_ check: HealthCheck) -> HealthCheck {
        let previous = lastRemoteState[check.id]
        lastRemoteState[check.id] = check.state
        guard check.state == .down, previous != .down, previous != .degraded else { return check }

        var softened = check
        softened.state = .degraded
        softened.detail = "\(check.detail), retrying"
        return softened
    }

    /// Test seam. `settled` carries the strike count that makes the filter meaningful,
    /// so it has to be exercised on a real instance rather than a static copy of itself.
    func settledForTest(_ check: HealthCheck) -> HealthCheck { settled(check) }

    private func dnsCheck() async -> HealthCheck {
        let start = Date()
        let outcome = await Self.resolve("api.anthropic.com")
        let millisecond = Int(Date().timeIntervalSince(start) * 1000)

        let state: HealthState
        let detail: String
        switch outcome {
        case .resolved:
            // A cold cache legitimately takes a second or two; that is slow, not broken.
            state = millisecond > 2500 ? .degraded : .ok
            detail = millisecond > 2500 ? "resolving slowly" : "resolving"
        case .timedOut:
            // Timing out is not the same as being told the name does not exist. The
            // first sweep after launch hits a cold resolver and lands here routinely.
            state = .degraded
            detail = "no answer in \(Self.resolveTimeoutSecond)s"
        case .failed:
            state = .down
            detail = "cannot resolve. Captive portal?"
        }
        return HealthCheck(
            id: "network.dns", group: .network, label: "DNS",
            state: state, detail: detail, latencyMillisecond: millisecond)
    }

    enum ResolveOutcome: Sendable, Equatable {
        case resolved
        /// The resolver answered, and the answer was "no".
        case failed
        /// The resolver did not answer in time, which says nothing either way.
        case timedOut
    }

    static let resolveTimeoutSecond = 5

    /// `getaddrinfo` on a background thread. It has no timeout knob of its own, so the
    /// caller races it; the thread is left to finish on its own rather than cancelled,
    /// because tearing down a resolver mid-call is not safe.
    static func resolve(_ host: String) async -> ResolveOutcome {
        await withCheckedContinuation { continuation in
            let box = ResultBox()
            DispatchQueue.global(qos: .utility).async {
                var hint = addrinfo(
                    ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                    ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                var info: UnsafeMutablePointer<addrinfo>?
                let code = getaddrinfo(host, "443", &hint, &info)
                if let info { freeaddrinfo(info) }
                if box.claim() { continuation.resume(returning: code == 0 ? .resolved : .failed) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .seconds(resolveTimeoutSecond)
            ) {
                if box.claim() { continuation.resume(returning: .timedOut) }
            }
        }
    }

    private func endpointCheck(_ endpoint: ServiceEndpoint) async -> HealthCheck {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "HEAD"
        request.setValue("liddy-health", forHTTPHeaderField: "User-Agent")

        let start = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let millisecond = Int(Date().timeIntervalSince(start) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Any HTTP answer means the service is reachable. 401/403 is the expected
            // reply to an unauthenticated probe and is not a failure.
            let state: HealthState
            if code >= 500 {
                state = .degraded
            } else if code > 0 {
                state = millisecond > 2500 ? .degraded : .ok
            } else {
                state = .unknown
            }
            return HealthCheck(
                id: "service.\(endpoint.id)", group: .service, label: endpoint.label,
                state: state, detail: code >= 500 ? "HTTP \(code)" : "reachable",
                latencyMillisecond: millisecond)
        } catch {
            return HealthCheck(
                id: "service.\(endpoint.id)", group: .service, label: endpoint.label,
                state: .down, detail: (error as NSError).localizedDescription,
                latencyMillisecond: Int(Date().timeIntervalSince(start) * 1000))
        }
    }

    private func statusPageCheck() async -> HealthCheck {
        do {
            let (data, _) = try await session.data(from: ServiceStatusPage.anthropic)
            guard let parsed = ServiceStatusPage.parse(data) else {
                return HealthCheck(
                    id: "service.anthropic-status", group: .service, label: "Anthropic status",
                    state: .unknown, detail: "unreadable response")
            }
            return HealthCheck(
                id: "service.anthropic-status", group: .service, label: "Anthropic status",
                state: parsed.state, detail: parsed.description)
        } catch {
            return HealthCheck(
                id: "service.anthropic-status", group: .service, label: "Anthropic status",
                state: .unknown, detail: "status page unreachable")
        }
    }
}

/// One-shot winner-takes-all flag, so a raced continuation is resumed exactly once.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isClaimed { return false }
        isClaimed = true
        return true
    }
}
