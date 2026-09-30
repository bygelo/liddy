import Foundation

/// Where the runtime's CPU actually goes, per phase, measured in the running app.
///
/// Built after two rounds of optimising the wrong thing: the temperature read was
/// assumed to be the HID client construction (it was the per-sensor IPC), and the
/// session scan was assumed to be the transcript head reads (it was enumerating 8390
/// files). Both assumptions were reasonable and both were wrong, and each cost a build
/// cycle to disprove. A profile that names the phase is cheaper than another guess.
///
/// Off unless `LIDDY_PROFILE=1`, and when off every call is an `isEnabled` check.
public enum TickProfile {
    public static let isEnabled = ProcessInfo.processInfo.environment["LIDDY_PROFILE"] == "1"

    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var total: [String: TimeInterval] = [:]
        var count: [String: Int] = [:]
        var since = Date()
        var sinceCpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }
    private static let store = Store()

    /// Thread CPU time, not wall time.
    ///
    /// The first version timed with `Date()`, which on a machine already at 100% CPU —
    /// which is exactly when someone profiles — counts the time this thread spent
    /// *waiting for a core* as time spent working. It reported a cached, in-memory
    /// field read at 15ms and made two optimisations look like regressions. Thread CPU
    /// time is what `ps` bills and therefore what the comparison against iStat is in.
    @inlinable
    public static func measure<T>(_ phase: String, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let value = body()
        let end = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        record(phase, Double(end &- start) / 1_000_000_000)
        return value
    }

    public static func record(_ phase: String, _ second: TimeInterval) {
        store.lock.lock(); defer { store.lock.unlock() }
        store.total[phase, default: 0] += second
        store.count[phase, default: 0] += 1
    }

    /// Milliseconds per phase and what share of wall-clock each one is, since the last
    /// report. Written to stderr so it lands in the app's log without a UI.
    public static func report() {
        guard isEnabled else { return }
        store.lock.lock()
        let total = store.total
        let count = store.count
        let window = Date().timeIntervalSince(store.since)
        store.total = [:]; store.count = [:]; store.since = Date()
        store.lock.unlock()

        guard window > 0, !total.isEmpty else { return }
        var line = String(format: "PROFILE window=%.0fs\n", window)
        for (phase, second) in total.sorted(by: { $0.value > $1.value }) {
            line += String(
                format: "  %-24s %7.1f ms total  %5d calls  %6.2f ms/call  %5.3f%% cpu\n",
                (phase as NSString).utf8String!, second * 1000, count[phase] ?? 0,
                second * 1000 / Double(max(1, count[phase] ?? 1)), second / window * 100)
        }
        FileHandle.standardError.write(Data(line.utf8))
    }
}
