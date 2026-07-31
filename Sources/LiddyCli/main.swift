import Foundation
import LiddyKit

let cliVersion = "0.1.0"

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

func send(_ request: AppRequest) -> AppResponse {
    let client = LineSocketClient(path: LiddyPath.appSocket.path)
    do {
        try client.connect()
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
           AppRequest.claim(label: command, ttlSecond: 60),
           expecting: AppResponse.self),
       case .token(let issued) = response {
        token = issued
    } else {
        FileHandle.standardError.write(Data(
            "liddy: app not running — holding an unguarded assertion (no battery or thermal floor)\n".utf8))
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
      liddy start [--timer 3h] [--mode smart|manual]
      liddy stop
      liddy lid on|off [--timer 8h]    closed-lid mode (needs the helper)
      liddy autowatch on|off|toggle    detect known dev/AI processes
      liddy watch <pattern>            add a process pattern
      liddy unwatch <pattern>          remove one
      liddy pattern                    list them
      liddy claim <label> [--ttl 300]  declare live work, prints a token
      liddy renew <token> [--ttl 300]
      liddy release <token>
      liddy lease                      what is currently claimed
      liddy log [-n 20]                why sessions started and stopped
      liddy -- <command>               hold for exactly one command
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
    guard let label = rest.first, !label.hasPrefix("--") else { fail("usage: liddy claim <label> [--ttl 300]") }
    report(send(.claim(label: label, ttlSecond: ttl)))

case "renew":
    guard let token = rest.first else { fail("usage: liddy renew <token> [--ttl 300]") }
    report(send(.renew(token: token, ttlSecond: ttl)))

case "release":
    guard let token = rest.first else { fail("usage: liddy release <token>") }
    report(send(.release(token: token)))

case "lease":
    report(send(.lease))

case "log":
    let limit = flagValue("-n", in: rest).flatMap(Int.init) ?? 20
    report(send(.recentLog(limit: limit)))

case "--version", "-v", "version":
    out(cliVersion)

case "help", "--help", "-h":
    out("run `liddy` with no argument for the command list")

default:
    fail("unknown command '\(command)' — run `liddy` for the command list")
}
