import Foundation
import LiddyKit

let cliVersion = LiddyVersion.current

func out(_ text: String) { print(text) }
func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data("liddy: \(text)\n".utf8))
    exit(1)
}

/// Accepts `90`, `30m`, `3h`, `2h30m`.
func parseSecond(_ text: String) -> Int? {
    if let plain = Int(text) { return plain }
    var total = 0
    var digit = ""
    for character in text.lowercased() {
        if character.isNumber {
            digit.append(character)
            continue
        }
        guard let value = Int(digit) else { return nil }
        switch character {
        case "s": total += value
        case "m": total += value * 60
        case "h": total += value * 3600
        default: return nil
        }
        digit = ""
    }
    guard digit.isEmpty else { return nil }
    return total > 0 ? total : nil
}

func flagValue(_ name: String, in argument: [String]) -> String? {
    guard let index = argument.firstIndex(of: name), index + 1 < argument.count else { return nil }
    return argument[index + 1]
}

// MARK: - Talking to the app

/// `health` is the one request the app answers slowly on purpose: it re-runs the whole
/// sweep, including the network half, before replying. The default 5s read timeout is
/// tuned for the instant commands and would give up on a cold DNS cache mid-sweep, so
/// this one connection gets a window wider than the probe's own worst case.
func send(_ request: AppRequest, timeoutSecond: Int = 5) -> AppResponse {
    let client = LineSocketClient(path: LiddyPath.appSocket.path)
    do {
        try client.connect(timeoutSecond: timeoutSecond)
        return try client.roundTrip(request, expecting: AppResponse.self)
    } catch {
        fail(LiddyError.appNotRunning.localizedDescription)
    }
}

func report(_ response: AppResponse) {
    switch response {
    case .ok(let message):      out(message)
    case .failed(let message):  fail(message)
    case .token(let token):     out(token)
    case .text(let line):       line.forEach(out)
    case .snapshot(let snap):   printSnapshot(snap)
    case .log(let entry):       entry.forEach { printEntry($0) }
    }
}

let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func printSnapshot(_ snap: RuntimeSnapshot) {
    out("Mode:      \(snap.isAwakeHeld ? "Awake On" : "Awake Off") (\(snap.mode.rawValue))")
    out("Assertion: \(snap.isAssertionActive ? "active" : "inactive")")
    out("Clamshell: \(snap.isClamshellActive ? "on" : "off")")
    out("Battery:   \(snap.battery.display)")
    out("Thermal:   \(snap.thermal.level.display)")
    if snap.isAwakeHeld {
        out("Runtime:   \(snap.runtimeSecond / 60)m \(snap.runtimeSecond % 60)s")
    }
    if let expiresAt = snap.expiresAt {
        out("Expires:   \(stamp.string(from: expiresAt))")
    }
    if snap.activeLease.isEmpty {
        out("Holding:   nothing tracked")
    } else {
        out("Holding:   \(snap.activeLease.joined(separator: ", "))")
    }
    if let reason = snap.lastStopReason, !snap.isAwakeHeld {
        out("Last stop: \(reason.summary)")
    }
}

func printEntry(_ entry: LogEntry) {
    var line = "\(stamp.string(from: entry.at))  \(entry.kind.rawValue)  \(entry.detail)"
    if let percent = entry.batteryPercent { line += "  [battery \(percent)%]" }
    if let thermal = entry.thermal, thermal != .nominal { line += "  [\(thermal.display)]" }
    out(line)
}

// MARK: - `liddy -- <command>`

/// Wrap one command in a keep-awake hold for exactly its lifetime.
///
/// Unlike the equivalent in the tool this is modelled on, the wrapper does not run
/// unguarded when the app is available: it registers a renewing lease first, so the
/// app's battery and thermal governor covers a wrapped command too. Only when the app
/// genuinely is not running does it fall back to a bare assertion — and it says so.
func runWrapped(_ argument: [String]) -> Never {
    guard !argument.isEmpty else { fail("usage: liddy -- <command>") }
    let command = argument.joined(separator: " ")

    let assertion = PowerAssertion()
    assertion.acquire(reason: "liddy -- \(command)")

    var token: String?
    let client = LineSocketClient(path: LiddyPath.appSocket.path)
    if (try? client.connect()) != nil,
       let response = try? client.roundTrip(
           AppRequest.claim(label: command, ttlSecond: 60, key: nil),
           expecting: AppResponse.self),
       case .token(let issued) = response {
        token = issued
    } else {
        FileHandle.standardError.write(Data(
            "liddy: app not running, holding an unguarded assertion (no battery or thermal floor)\n".utf8))
    }

    // Renew well inside the 60s TTL so a stalled CLI cannot outlive its own claim.
    let renewTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.liddy.cli.renew"))
    if let token {
        renewTimer.schedule(deadline: .now() + .seconds(20), repeating: .seconds(20))
        renewTimer.setEventHandler {
            _ = try? client.roundTrip(AppRequest.renew(token: token, ttlSecond: 60), expecting: AppResponse.self)
        }
        renewTimer.resume()
    }

    // A login shell so `&&`, pipes, and Homebrew/pyenv/nvm PATH resolve the way they
    // do interactively. Quote the whole command to keep it in one hold.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-lc", command]

    func cleanUp() {
        renewTimer.cancel()
        if let token {
            _ = try? client.roundTrip(AppRequest.release(token: token), expecting: AppResponse.self)
        }
        assertion.release()
    }

    do {
        try process.run()
    } catch {
        cleanUp()
        fail("cannot run: \(error.localizedDescription)")
    }
    process.waitUntilExit()
    cleanUp()
    exit(process.terminationStatus)
}

// MARK: - Dispatch

let argument = Array(CommandLine.arguments.dropFirst())

if let separator = argument.firstIndex(of: "--") {
    runWrapped(Array(argument[(separator + 1)...]))
}

guard let command = argument.first else {
    out("""
    liddy \(cliVersion) — keep a Mac awake for work that must finish

      liddy status                     what is holding the Mac, and why
      liddy health                     every check the menu bar draws, as text
      liddy override [30m] | off       keep going despite a soft safety stop
      liddy start [--timer 3h] [--mode smart|manual]
      liddy stop
      liddy lid on|off [--timer 8h]    closed-lid mode (needs the helper)
      liddy autowatch on|off|toggle    detect known dev/AI processes
      liddy watch <pattern>            add a process pattern
      liddy unwatch <pattern>          remove one
      liddy pattern                    list them
      liddy claim <label> [--ttl 300] [--key K]   declare live work
      liddy renew <token> [--ttl 300]
      liddy release <token> | --key K
      liddy lease                      what is currently claimed
      liddy log [-n 20]                why sessions started and stopped
      liddy -- <command>               hold for exactly one command
      liddy setting                    show thresholds
      liddy set --soft-battery 25 --idle-release 5m --charging-only on
      liddy set --network-probe off    stop probing DNS and agent APIs
      liddy set --resource-saver on    hide Chrome and friends while a hold runs
      liddy top                        what is eating the machine right now
      liddy session                    live CLI agent sessions, per project
      liddy hook install [--project]   hold the Mac only while Claude Code works
      liddy doctor                     check the install, find a stuck disablesleep
    """)
    exit(0)
}

let rest = Array(argument.dropFirst())
let second = flagValue("--timer", in: rest).flatMap(parseSecond)
let mode = HoldMode(rawValue: flagValue("--mode", in: rest) ?? "smart") ?? .smart
let ttl = flagValue("--ttl", in: rest).flatMap(parseSecond) ?? 300

switch command {
case "status":
    report(send(.status))

case "override":
    if rest.first == "off" {
        report(send(.override(second: nil)))
    } else {
        report(send(.override(second: second ?? parseSecond(rest.first ?? "30m") ?? 1800)))
    }

case "health":
    report(send(.health, timeoutSecond: 15))

case "start":
    report(send(.start(second: second, mode: mode)))

case "stop":
    report(send(.stop))

case "lid":
    guard let state = rest.first, state == "on" || state == "off" else {
        fail("usage: liddy lid on|off [--timer 8h]")
    }
    report(send(.clamshell(isOn: state == "on", second: second, mode: mode)))

case "autowatch":
    guard let state = rest.first else { fail("usage: liddy autowatch on|off|toggle") }
    switch state {
    case "on":     report(send(.autowatch(isOn: true)))
    case "off":    report(send(.autowatch(isOn: false)))
    case "toggle":
        if case .snapshot(let snap) = send(.status) {
            report(send(.autowatch(isOn: !snap.isAwakeHeld)))
        }
    default: fail("usage: liddy autowatch on|off|toggle")
    }

case "watch":
    guard let pattern = rest.first else { fail("usage: liddy watch <pattern>") }
    report(send(.watch(pattern: pattern)))

case "unwatch":
    guard let pattern = rest.first else { fail("usage: liddy unwatch <pattern>") }
    report(send(.unwatch(pattern: pattern)))

case "pattern":
    report(send(.pattern))

case "claim":
    guard let label = rest.first, !label.hasPrefix("--") else {
        fail("usage: liddy claim <label> [--ttl 300] [--key K]")
    }
    report(send(.claim(label: label, ttlSecond: ttl, key: flagValue("--key", in: rest))))

case "renew":
    guard let token = rest.first else { fail("usage: liddy renew <token> [--ttl 300]") }
    report(send(.renew(token: token, ttlSecond: ttl)))

case "release":
    if let key = flagValue("--key", in: rest) {
        report(send(.releaseKey(key: key)))
    } else if let token = rest.first, !token.hasPrefix("--") {
        report(send(.release(token: token)))
    } else {
        fail("usage: liddy release <token> | --key K")
    }

case "lease":
    report(send(.lease))

case "log":
    let limit = flagValue("-n", in: rest).flatMap(Int.init) ?? 20
    report(send(.recentLog(limit: limit)))

case "setting":
    report(send(.settingList))

// Tab Warden: every live CLI agent session, from the transcripts the tools write.
// Read straight off the filesystem rather than through the app socket, so it answers
// whether or not Liddy is running.
case "session", "sessions":
    let live = SessionScanner.live()
    let found = SessionScanner.scan(live: live, limit: 20)
    if found.isEmpty {
        print("no agent sessions running")
    } else {
        for entry in found {
            let state = entry.state.display.padding(toLength: 9, withPad: " ", startingAt: 0)
            let tool = entry.tool.label.padding(toLength: 7, withPad: " ", startingAt: 0)
            let age = entry.ageDisplay().padding(toLength: 4, withPad: " ", startingAt: 0)
            let branch = entry.branch.map { " (\($0))" } ?? ""
            print("\(state) \(tool) \(age) \(entry.projectDisplay)\(branch)")
        }
    }
    exit(0)

// Visibility, not a decision: nothing in the governor reads this. See `ProcessLoad`.
case "top":
    let limit = flagValue("-n", in: rest).flatMap(Int.init) ?? 6
    let load = ProcessLoad.top(ProcessLoad.sample(), limit: limit, minimumCpuPercent: 1)
    if load.isEmpty {
        print("nothing above 1% CPU")
    } else {
        for entry in load {
            let cpu = String(format: "%5.1f", entry.cpuPercent)
            let memory = String(format: "%5.1f", entry.memoryPercent)
            print("\(cpu)% cpu  \(memory)% mem  \(entry.name)")
        }
    }
    exit(0)

case "set":
    var patch = SettingPatch()
    patch.softBatteryPercent = flagValue("--soft-battery", in: rest).flatMap(Int.init)
    patch.hardBatteryPercent = flagValue("--hard-battery", in: rest).flatMap(Int.init)
    patch.idleReleaseSecond = flagValue("--idle-release", in: rest).flatMap(parseSecond)
    patch.thermalCeiling = flagValue("--thermal-ceiling", in: rest).flatMap(ThermalLevel.init(rawValue:))
    if let charging = flagValue("--charging-only", in: rest) {
        patch.isChargingOnly = charging == "on" || charging == "true"
    }
    if let probe = flagValue("--network-probe", in: rest) {
        patch.isNetworkProbeOn = probe == "on" || probe == "true"
    }
    if let health = flagValue("--health-panel", in: rest) {
        patch.isHealthPanelOn = health == "on" || health == "true"
    }
    if let dim = flagValue("--lid-brightness-off", in: rest) {
        patch.isLidBrightnessOff = dim == "on" || dim == "true"
    }
    if let saver = flagValue("--resource-saver", in: rest) {
        patch.isResourceSaverOn = saver == "on" || saver == "true"
    }
    // Comma-separated because these are app names with spaces in them — "Google
    // Chrome", not "chrome" — so whitespace cannot be the separator.
    if let app = flagValue("--background-app", in: rest) {
        patch.backgroundApp = app
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    guard !patch.isEmpty else {
        fail("usage: liddy set [--soft-battery 25] [--hard-battery 5] [--idle-release 5m] "
             + "[--thermal-ceiling serious] [--charging-only on|off] [--network-probe on|off] "
             + "[--health-panel on|off] [--lid-brightness-off on|off] [--resource-saver on|off] "
             + "[--background-app \"Google Chrome,Discord\"]")
    }
    report(send(.updateSetting(patch)))

case "hook":
    Hook.run(rest)

case "doctor":
    Doctor.run()

case "--version", "-v", "version":
    out(cliVersion)

case "help", "--help", "-h":
    out("run `liddy` with no argument for the command list")

default:
    fail("unknown command '\(command)'. Run `liddy` for the command list")
}
