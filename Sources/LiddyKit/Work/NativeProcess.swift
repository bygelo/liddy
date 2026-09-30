import Darwin
import Foundation

/// The process table and working directories, read with libproc and `sysctl` instead
/// of spawning `ps` and `lsof`.
///
/// **Why.** Measured on this Mac with ~610 processes: `ps -Ao pid=,comm=` cost 100 ms
/// and `lsof -d cwd` another ~110 ms, and between the process watcher and the session
/// scanner they ran several times a minute. The same table read in-process is ~6 ms.
///
/// **Same answer as `ps -o comm=`.** `comm` is `argv[0]` as the process last wrote it —
/// which is how `claude` and `npm exec …` show up under their own names rather than as
/// `node` — and `KERN_PROCARGS2` returns exactly that. It is refused for another user's
/// process, where `ps` (setuid root) can still see it; those fall back to the
/// executable path. Compared against `ps` on this machine: 588 of 609 rows identical,
/// and every difference was a root daemon (a `Versions/A` path, or `autofsd` for
/// `/usr/libexec/autofsd`). Agent processes are the user's own, so the rows the
/// watcher matches on are the identical ones.
///
/// CPU is deliberately *not* read here: `proc_pidinfo` cannot see a root process's
/// task info, so a native CPU sample would silently omit WindowServer and friends —
/// the very rows "Using the most" exists to name. `ProcessLoad` keeps `ps` for that.
enum NativeProcess {
    static func allPid() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Headroom for processes started between the two calls.
        var pid = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pid, Int32(pid.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }
        return pid.prefix(Int(filled)).filter { $0 > 0 }
    }

    /// `argv[0]`, else the executable path, else nil when the process is gone.
    static func command(of pid: Int32) -> String? {
        if let name = argv0(of: pid) { return name.trimmingCharacters(in: .whitespaces) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// `KERN_PROCARGS2`: an `Int32` argc, the exec path, NUL padding, then argv.
    private static func argv0(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        guard index > start else { return nil }
        return String(decoding: buffer[start..<index], as: UTF8.self)
    }

    /// The current directory of each pid that could be read. Missing pids exited or
    /// belong to another user — the same pids `lsof` would have skipped.
    static func workingDirectory(of pid: [Int32]) -> [Int32: String] {
        var found: [Int32: String] = [:]
        for one in pid {
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(one, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { continue }
            let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if !path.isEmpty { found[one] = path }
        }
        return found
    }
}
