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

// MARK: - Wiring
//
// The state store, the `pmset` runner and `ClamshellGuard` itself all live in
// `LiddyKit` now. They used to live in this file, where no test could import them —
// which is exactly how the "any disconnect reverts the toggle" bug shipped and how
// `liddy doctor` ended up disarming the thing it was diagnosing.

func log(_ message: String) {
    FileHandle.standardError.write(Data("[liddy-helper] \(message)\n".utf8))
}

let pmset = LivePmsetRunner()
let store = FileClamshellStateStore()

@discardableResult
func runPmset(_ argument: [String]) -> Bool { pmset.run(argument) }

// MARK: - Entry

let guardian = ClamshellGuard(
    pmset: pmset,
    store: store,
    scheduler: QueueDelayScheduler(),
    deadmanSecond: deadmanSecond,
    log: log
)

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
    onClose: { connection in guardian.connectionLost(connection) }
) { line, connection in
    let request: HelperRequest
    do {
        request = try Wire.decode(HelperRequest.self, from: line)
    } catch {
        return try? Wire.encoder.encode(HelperResponse.failed("bad request"))
    }

    let response: HelperResponse
    switch request {
    case .setClamshell(let isOn):
        response = guardian.set(isOn, owner: connection) ? .ok : .failed("pmset failed")

    case .heartbeat:
        guardian.heartbeat(from: connection)
        response = .ok

    case .sleepNow(let reason):
        log("sleepNow: \(reason)")
        // Revert first: the Mac must be able to sleep before being told to.
        guardian.set(false)
        response = runPmset(["sleepnow"]) ? .ok : .failed("pmset sleepnow failed")

    case .status:
        response = .status(HelperStatus(
            isClamshellOn: guardian.isOn,
            isOwnedByLiddy: store.load()?.isClamshellOn ?? false,
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
