import XCTest
@testable import LiddyKit

final class LeaseRegistryTest: XCTestCase {
    func testClaimedLeaseExpiresWithoutRenewal() {
        let registry = LeaseRegistry()
        _ = registry.claim(label: "overnight-refactor", ttlSecond: 1)
        XCTAssertEqual(registry.active.count, 1)

        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertTrue(registry.isEmpty, "a claimer that dies must stop holding the Mac on its own")
    }

    func testRenewalExtendsTheLease() {
        let registry = LeaseRegistry()
        let lease = registry.claim(label: "build", ttlSecond: 1)
        XCTAssertTrue(registry.renew(token: lease.token, ttlSecond: 30))
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(registry.active.count, 1)
    }

    func testRenewingAnUnknownTokenFailsRatherThanSilentlySucceeding() {
        let registry = LeaseRegistry()
        XCTAssertFalse(registry.renew(token: "claim:nonexistent", ttlSecond: 60))
    }

    /// Process leases are rebuilt every scan; a build that is still running must keep
    /// its original start time so the log shows true duration.
    func testProcessLeasePreservesStartAcrossScan() {
        let registry = LeaseRegistry()
        registry.replaceProcessLease(["claude", "docker"])
        let first = registry.active.first { $0.label == "claude" }?.startedAt

        registry.replaceProcessLease(["claude"])
        let active = registry.active
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.label, "claude")
        XCTAssertEqual(active.first?.startedAt, first)
    }

    func testProcessLeaseIsNotRenewable() {
        let registry = LeaseRegistry()
        registry.replaceProcessLease(["claude"])
        XCTAssertFalse(registry.renew(token: "process:claude", ttlSecond: 60))
    }
}
