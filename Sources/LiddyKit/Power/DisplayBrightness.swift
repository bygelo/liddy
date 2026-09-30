import Foundation
import CoreGraphics

/// Reading and setting the internal display's backlight.
///
/// There is no public API for this on Apple silicon. `IODisplaySetFloatParameter` —
/// the documented route — only ever worked on external DDC displays and does nothing
/// for the built-in panel on an M-series Mac. What the system's own brightness keys
/// drive is `DisplayServices`, a private framework.
///
/// So it is `dlopen`ed by path and the three symbols are looked up at runtime rather
/// than linked. That choice is deliberate and it is the difference between a feature
/// that degrades and one that crashes: if a future macOS drops or renames a symbol,
/// `canChange` simply returns false, `liddy doctor` says the lever is unavailable, and
/// closed-lid mode still works — it just does not dim. A link-time dependency on a
/// private framework would instead fail to launch the app at all.
///
/// Reading has a public fallback that needs no private symbol at all: `AppleARMBacklight`
/// publishes `IODisplayParameters` in the IO registry, which `parse(ioreg:)` reads.
public enum DisplayBrightness {
    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    private typealias SetFunction = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias GetFunction = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias CanFunction = @convention(c) (CGDirectDisplayID) -> Bool

    /// One `dlopen` for the process. `RTLD_LAZY` because nothing here is called on a
    /// hot path, and the handle is deliberately never closed — unloading a framework
    /// other code may still hold pointers into is how this would become a crash.
    private static let handle: UnsafeMutableRawPointer? = dlopen(frameworkPath, RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let raw = dlsym(handle, name) else { return nil }
        return unsafeBitCast(raw, to: type)
    }

    /// Whether this Mac will let us move the backlight at all.
    ///
    /// False on a Mac with no internal display, and false if the private symbol ever
    /// disappears. Both are "do not offer the feature", not "the feature is broken".
    public static func canChange(display: CGDirectDisplayID = CGMainDisplayID()) -> Bool {
        guard let can = symbol("DisplayServicesCanChangeBrightness", as: CanFunction.self) else {
            return false
        }
        return can(display)
    }

    /// Current level, 0...1. nil when it cannot be read — never a fabricated 0, which
    /// would make a restore drive the panel dark instead of putting it back.
    public static func read(display: CGDirectDisplayID = CGMainDisplayID()) -> Double? {
        if let get = symbol("DisplayServicesGetBrightness", as: GetFunction.self) {
            var level: Float = 0
            if get(display, &level) == 0 { return Double(level) }
        }
        return parse(ioreg: ioregOutput())
    }

    @discardableResult
    public static func set(_ level: Double, display: CGDirectDisplayID = CGMainDisplayID()) -> Bool {
        guard let setter = symbol("DisplayServicesSetBrightness", as: SetFunction.self) else {
            return false
        }
        return setter(display, Float(min(1, max(0, level)))) == 0
    }

    /// `ioreg -c AppleARMBacklight -r -d 1`, the public read path.
    public static func ioregOutput() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-c", "AppleARMBacklight", "-r", "-d", "1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Pull `brightness` out of the `IODisplayParameters` blob and normalise it.
    ///
    /// The row is one long line of nested pseudo-JSON, and it carries several
    /// brightness-ish keys — `BrightnessMilliNits`, `rawBrightness`, `BrightnessMicroAmps`
    /// — on the same line. Only the bare `"brightness"` key is the 0...max scale the
    /// slider moves, so the search is anchored on `"brightness"={`, not on the word
    /// appearing anywhere. Measured on this Mac: `{"min"=0,"max"=65536,"value"=32768}`.
    public static func parse(ioreg text: String) -> Double? {
        guard let start = text.range(of: "\"brightness\"={") else { return nil }
        let tail = text[start.upperBound...]
        guard let close = tail.firstIndex(of: "}") else { return nil }
        let blob = tail[..<close]

        func number(_ key: String) -> Double? {
            guard let at = blob.range(of: "\"\(key)\"=") else { return nil }
            let rest = blob[at.upperBound...]
            let digit = rest.prefix { $0.isNumber || $0 == "-" || $0 == "." }
            return Double(digit)
        }

        guard let value = number("value"), let maximum = number("max"), maximum > 0 else {
            return nil
        }
        return min(1, max(0, value / maximum))
    }
}

/// What to do about the backlight, as a pure function of the lid.
///
/// Separated from the IOKit call so the decision — which is the part with edge cases —
/// can be tested without a display attached. The restore level lives here rather than
/// in the caller because forgetting it is the failure that matters: a Mac whose lid was
/// opened to a black screen looks broken, and the user's next move is a hard reboot.
public struct DimmingPlan: Equatable, Sendable {
    /// The level to write now, or nil to leave the backlight alone.
    public var apply: Double?
    /// What the caller should remember for the next restore, or nil to forget.
    public var saved: Double?

    public static let doNothing = DimmingPlan(apply: nil, saved: nil)

    public init(apply: Double?, saved: Double?) {
        self.apply = apply
        self.saved = saved
    }

    /// - Parameters:
    ///   - isLidClosed: the kernel's `AppleClamshellState`, not an inference.
    ///   - isEnabled: the user's setting. Off must also RESTORE a level this already
    ///     dimmed, otherwise turning the feature off while the lid is shut strands the
    ///     panel at zero.
    ///   - current: what the backlight reads now, nil when it cannot be read.
    ///   - saved: what a previous call stashed, nil when nothing is dimmed.
    public static func plan(
        isLidClosed: Bool,
        isEnabled: Bool,
        current: Double?,
        saved: Double?
    ) -> DimmingPlan {
        guard isEnabled else {
            // Disabling mid-dim still owes the user their screen back.
            return saved.map { DimmingPlan(apply: $0, saved: nil) } ?? .doNothing
        }

        if isLidClosed {
            // Already dimmed: do not re-save. Saving again would capture the 0 we wrote
            // ourselves, and the restore would then put the panel back to black.
            guard saved == nil else { return .doNothing }
            // A level we could not read is a level we cannot restore, so do not dim.
            guard let current, current > 0 else { return .doNothing }
            return DimmingPlan(apply: 0, saved: current)
        }

        guard let saved else { return .doNothing }
        return DimmingPlan(apply: saved, saved: nil)
    }
}

/// Applies `DimmingPlan` to the real backlight and remembers what to put back.
///
/// Deliberately scoped to Liddy's *own* closed-lid session. A lid shut with an external
/// display attached and no hold of ours is still a lid shut, but it is not Liddy's, and
/// a utility that moves a setting it was not asked to move is the thing this whole
/// project argues against.
public final class DisplayDimmer {
    private let readLevel: () -> Double?
    private let writeLevel: (Double) -> Bool
    private let readLidClosed: () -> Bool?
    private let lock = NSLock()
    private var saved: Double?

    public init(
        readLevel: @escaping () -> Double? = { DisplayBrightness.read() },
        writeLevel: @escaping (Double) -> Bool = { DisplayBrightness.set($0) },
        readLidClosed: @escaping () -> Bool? = { ClamshellProbe.isLidClosed() }
    ) {
        self.readLevel = readLevel
        self.writeLevel = writeLevel
        self.readLidClosed = readLidClosed
    }

    /// What the backlight is currently being held at by us, nil when we are not holding
    /// it. Read by the panel so the user can see the feature acted.
    public var dimmedFrom: Double? {
        lock.lock(); defer { lock.unlock() }
        return saved
    }

    /// One tick's worth of work.
    ///
    /// - Parameter isEnabled: the setting AND the session — see the type's note.
    /// - Returns: the plan that was applied, for the log.
    @discardableResult
    /// - Parameter isLidClosed: passed in when the caller already read it this tick,
    ///   so one `ioreg` answers every question about the lid rather than one each.
    public func update(isEnabled: Bool, isLidClosed provided: Bool?? = nil) -> DimmingPlan {
        lock.lock(); defer { lock.unlock() }

        // A lid state we could not read is not a closed lid. Guessing here would dim a
        // screen the user is looking at.
        guard let isLidClosed = provided ?? readLidClosed() else {
            return saved.map { restoreLocked(to: $0) } ?? .doNothing
        }

        let plan = DimmingPlan.plan(
            isLidClosed: isLidClosed,
            isEnabled: isEnabled,
            current: saved == nil ? readLevel() : nil,
            saved: saved)

        if let level = plan.apply, writeLevel(level) {
            saved = plan.saved
        } else if plan.apply == nil {
            saved = plan.saved ?? saved
        }
        return plan
    }

    /// Put the screen back, now, whatever the lid says. The quit and safety-release
    /// paths call this: leaving a Mac dark because the app exited mid-dim is the one
    /// outcome worse than not having the feature.
    @discardableResult
    public func restore() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let level = saved else { return false }
        _ = restoreLocked(to: level)
        return true
    }

    private func restoreLocked(to level: Double) -> DimmingPlan {
        if writeLevel(level) { saved = nil }
        return DimmingPlan(apply: level, saved: nil)
    }
}
