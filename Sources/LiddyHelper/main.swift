import Foundation
import LiddyKit

/// Liddy's privileged helper — a root launchd daemon whose entire job is owning the
/// one system setting that closed-lid work needs, and giving it back.
///
/// Why it exists at all: a power assertion cannot stop clamshell sleep. The only
/// monitor-free lever macOS offers is `pmset -a disablesleep`, which is global,
/// sticky, and needs root. That combination is the actual hazard in this product —
/// a Mac left unable to sleep, in a bag, indefinitely.
///
/// So the helper, not the app, owns the toggle, and it holds it on a **deadman
/// switch**: while `disablesleep` is on, the app must keep a socket open and
/// heartbeat every few seconds. Drop the connection, crash, get force-quit, or go
/// quiet, and the helper reverts within `deadmanSecond`. Reverting is also wired to
/// helper startup, SIGTERM and SIGINT, so no single failure leaves the toggle stuck.
///
/// The privileged surface is deliberately three messages wide. The helper never runs
/// a command the app hands it.

let version = LiddyVersion.current

/// Three missed heartbeats at the app's 5s interval.
let deadmanSecond = 15

// MARK: - State, persisted so a helper restart can tell our toggle from the user's

struct HelperState: Codable {
    var isClamshellOn: Bool
    var setAt: Date
}

let stateUrl = URL(fileURLWithPath: LiddyPath.helperStatePath)

func loadState() -> HelperState? {
    guard let data = try? Data(contentsOf: stateUrl) else { return nil }
    return try? Wire.decoder.decode(HelperState.self, from: data)
}

func saveState(_ state: HelperState?) {
    let directory = stateUrl.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard let state else {
        try? FileManager.default.removeItem(at: stateUrl)
        return
    }
    guard let data = try? Wire.encoder.encode(state) else { return }
    try? data.write(to: stateUrl, options: .atomic)
}

// MARK: - pmset

@discardableResult
func runPmset(_ argument: [String]) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = argument
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("[liddy-helper] \(message)\n".utf8))
}

// MARK: - The toggle, with its deadman switch

final class ClamshellGuard {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.liddy.helper.deadman")
    private var deadman: DispatchWorkItem?

    private(set) var isOn = false
    private(set) var lastHeartbeatAt: Date?

    /// Called at startup: if we left `disablesleep` on, put it back. This is the
    /// recovery path for the case where even the helper died.
    func reconcileOnLaunch() {
        guard let state = loadState(), state.isClamshellOn else { return }
        log("found leftover disablesleep from \(state.setAt), reverting")
        _ = runPmset(["-a", "disablesleep", "0"])
        saveState(nil)
    }

    @discardableResult
    func set(_ wanted: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return setLocked(wanted)
    }

    private func setLocked(_ wanted: Bool) -> Bool {
        guard runPmset(["-a", "disablesleep", wanted ? "1" : "0"]) else {
            log("pmset disablesleep \(wanted ? 1 : 0) FAILED")
            return false
        }
        isOn = wanted
        saveState(wanted ? HelperState(isClamshellOn: true, setAt: Date()) : nil)
        log("disablesleep \(wanted ? 1 : 0)")
        if wanted {
            lastHeartbeatAt = Date()
            armDeadman()
        } else {
            disarmDeadman()
            lastHeartbeatAt = nil
        }
        return true
    }

    func heartbeat() {
        lock.lock()
        defer { lock.unlock() }
        guard isOn else { return }
        lastHeartbeatAt = Date()
        armDeadman()
    }

    /// The app's socket closed. No grace period: a closed connection is unambiguous.
    func connectionLost() {
        lock.lock()
        defer { lock.unlock() }
        guard isOn else { return }
        log("client disconnected while disablesleep was on, reverting now")
        _ = setLocked(false)
    }

    private func armDeadman() {
        deadman?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.isOn else { return }
            log("no heartbeat for \(deadmanSecond)s, reverting disablesleep")
            _ = self.setLocked(false)
        }
        deadman = item
        queue.asyncAfter(deadline: .now() + .seconds(deadmanSecond), execute: item)
    }

    private func disarmDeadman() {
        deadman?.cancel()
        deadman = nil
    }
}

// MARK: - Entry

let guardian = ClamshellGuard()

guard getuid() == 0 else {
    log("must run as root (installed as a launchd daemon)")
    exit(1)
}

// `--uid N`: the socket is chowned to exactly this user rather than made world
// writable, so a local account cannot toggle another user's power settings.
var ownerUid: uid_t?
var argument = CommandLine.arguments.dropFirst().makeIterator()
while let flag = argument.next() {
    if flag == "--uid", let value = argument.next(), let parsed = UInt32(value) {
        ownerUid = uid_t(parsed)
    }
}

guardian.reconcileOnLaunch()

let server = LineSocketServer(
    path: LiddyPath.helperSocketPath,
    onClose: { guardian.connectionLost() }
) { line in
    let request: HelperRequest
    do {
        request = try Wire.decode(HelperRequest.self, from: line)
    } catch {
        return try? Wire.encoder.encode(HelperResponse.failed("bad request"))
    }

    let response: HelperResponse
    switch request {
    case .setClamshell(let isOn):
        response = guardian.set(isOn) ? .ok : .failed("pmset failed")

    case .heartbeat:
        guardian.heartbeat()
        response = .ok

    case .sleepNow(let reason):
        log("sleepNow: \(reason)")
        // Revert first: the Mac must be able to sleep before being told to.
        guardian.set(false)
        response = runPmset(["sleepnow"]) ? .ok : .failed("pmset sleepnow failed")

    case .status:
        response = .status(HelperStatus(
            isClamshellOn: guardian.isOn,
            isOwnedByLiddy: loadState()?.isClamshellOn ?? false,
            secondSinceHeartbeat: guardian.lastHeartbeatAt.map { Int(Date().timeIntervalSince($0)) },
            version: version
        ))
    }
    return try? Wire.encoder.encode(response)
}

do {
    try server.start(mode: 0o600, ownerUid: ownerUid)
} catch {
    log("cannot start: \(error.localizedDescription)")
    exit(1)
}

for signalNumber in [SIGTERM, SIGINT] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        log("shutting down, reverting disablesleep")
        guardian.set(false)
        server.stop()
        exit(0)
    }
    source.resume()
}

log("ready on \(LiddyPath.helperSocketPath) (deadman \(deadmanSecond)s)")
dispatchMain()
