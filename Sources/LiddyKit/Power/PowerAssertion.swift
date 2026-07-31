import Foundation
import IOKit.pwr_mgt

/// Wrapper around `IOPMAssertionCreateWithName` — the same public API `caffeinate`
/// and every menu-bar keep-awake app is built on.
///
/// Important limit, and the reason the helper exists: this blocks *idle* sleep only.
/// It does nothing about clamshell sleep, which macOS triggers the moment the lid
/// closes. No user-level assertion can stop that.
public final class PowerAssertion {
    private var assertionId: IOPMAssertionID = IOPMAssertionID(0)
    private let lock = NSLock()

    public private(set) var isActive = false

    public init() {}

    deinit { release() }

    @discardableResult
    public func acquire(reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isActive else { return true }

        var id = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard status == kIOReturnSuccess else { return false }
        assertionId = id
        isActive = true
        return true
    }

    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return }
        IOPMAssertionRelease(assertionId)
        assertionId = IOPMAssertionID(0)
        isActive = false
    }
}
