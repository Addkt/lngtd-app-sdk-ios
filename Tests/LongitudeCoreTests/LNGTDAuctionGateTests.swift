import XCTest
@testable import LongitudeCore

final class LNGTDAuctionGateTests: XCTestCase {

    func test1_sixConcurrentAcquisitionsSucceed() {
        let gate = LNGTDAuctionGate()
        var acquired = 0

        for _ in 0..<6 {
            _ = gate.acquire { acquired += 1 }
        }

        XCTAssertEqual(acquired, 6, "Expected exactly 6 permits to be granted immediately.")
    }

    func test2_seventhDoesNotSucceedWhileSixAreHeld() {
        let gate = LNGTDAuctionGate()
        var acquired = 0

        let permits = (0..<6).map { _ in gate.acquire { acquired += 1 } }
        let seventh = gate.acquire { acquired += 1 }

        XCTAssertEqual(acquired, 6, "Expected exactly 6 permits to be granted immediately, seventh should wait.")

        // Suppress unused warnings
        _ = permits
        _ = seventh
    }

    func test3_releasingOneAdmitsExactlyOneMore() {
        let gate = LNGTDAuctionGate()
        var acquired = 0

        var permits = (0..<6).map { _ in gate.acquire { acquired += 1 } }
        let seventh = gate.acquire { acquired += 1 }
        let eighth = gate.acquire { acquired += 1 }

        XCTAssertEqual(acquired, 6)

        let release1 = LNGTDAuctionGateRelease(host: gate)
        release1.arm(permits[0])
        release1.release()

        XCTAssertEqual(acquired, 7, "Releasing one permit should admit the seventh.")

        let release2 = LNGTDAuctionGateRelease(host: gate)
        release2.arm(permits[1])
        release2.release()

        XCTAssertEqual(acquired, 8, "Releasing another permit should admit the eighth.")

        _ = seventh
        _ = eighth
    }

    func test4_releaseIsIdempotent() {
        let gate = LNGTDAuctionGate()
        var acquired = 0

        let p1 = gate.acquire { acquired += 1 }
        let permits = (0..<5).map { _ in gate.acquire { acquired += 1 } }
        let seventh = gate.acquire { acquired += 1 }

        XCTAssertEqual(acquired, 6)

        let release = LNGTDAuctionGateRelease(host: gate)
        release.arm(p1)
        release.release()

        XCTAssertEqual(acquired, 7)

        // Release again
        release.release()

        // This should not free a second slot
        let eighth = gate.acquire { acquired += 1 }
        XCTAssertEqual(acquired, 7, "Double releasing the same permit should not admit another.")

        _ = permits
        _ = seventh
        _ = eighth
    }

    func test5_permitReleasedAfterTeardownStillFreesSlot() {
        // Teardown meaning: if we release an armed token via the host `endTask` directly or it gets released
        let gate = LNGTDAuctionGate()
        var acquired = 0

        let p1 = gate.acquire { acquired += 1 }
        let permits = (0..<5).map { _ in gate.acquire { acquired += 1 } }
        let seventh = gate.acquire { acquired += 1 }

        XCTAssertEqual(acquired, 6)

        // Simulate tearing down an object that holds the permit
        gate.endTask(p1)

        XCTAssertEqual(acquired, 7, "Permit manually ended directly should still free the slot.")

        _ = permits
        _ = seventh
    }

    func test6_fullCapPolicyIsLIFONewestWins() {
        let gate = LNGTDAuctionGate()
        var acquired = [Int]()

        let permits = (0..<6).map { _ in gate.acquire {} }

        // Queue 3 waiters
        let wait7 = gate.acquire { acquired.append(7) }
        let wait8 = gate.acquire { acquired.append(8) }
        let wait9 = gate.acquire { acquired.append(9) }

        XCTAssertTrue(acquired.isEmpty)

        gate.endTask(permits[0])
        XCTAssertEqual(acquired, [9], "Newest waiter (9) should win because it is the most recently visible slot.")

        gate.endTask(permits[1])
        XCTAssertEqual(acquired, [9, 8], "Next newest waiter (8) should win.")

        gate.endTask(permits[2])
        XCTAssertEqual(acquired, [9, 8, 7], "Oldest waiter (7) should win last.")

        _ = wait7
        _ = wait8
        _ = wait9
    }

    func test7_waiterCancelledBeforeTurnDoesNotConsumePermit() {
        let gate = LNGTDAuctionGate()
        var acquired = 0

        let permits = (0..<6).map { _ in gate.acquire { acquired += 1 } }

        let wait7 = gate.acquire { acquired += 1 }

        // Cancel waiter 7 while it's in the queue
        gate.endTask(wait7)

        let release = LNGTDAuctionGateRelease(host: gate)
        release.arm(permits[0])
        release.release()

        XCTAssertEqual(acquired, 6, "Cancelled waiter should have been removed from the queue and not acquired.")
    }

    // 4b. The gate is idempotent by itself, not only through the release wrapper.
    //
    // `endTask` is public protocol API. Case 4 releases through `LNGTDAuctionGateRelease`, which
    // guards its own double-release, so it says nothing about the gate. Counting permits without
    // tracking which tokens hold them means a second `endTask` for the same token frees a slot
    // that was never held — and seven auctions run against a cap of six.
    func test4b_theGateItselfIgnoresARepeatedRelease() {
        let gate = LNGTDAuctionGate()
        var acquired = 0

        let first = gate.acquire { acquired += 1 }
        let rest = (0..<5).map { _ in gate.acquire { acquired += 1 } }
        // TWO waiters, so the queue is not empty when the spurious release lands. With only one,
        // the queue is already drained by the legitimate release and a double release has nothing
        // to wrongly promote — the assertion passes whether or not the gate is idempotent.
        let waiters = (0..<2).map { _ in gate.acquire { acquired += 1 } }
        XCTAssertEqual(acquired, 6, "six run, two queue")

        gate.endTask(first)
        XCTAssertEqual(acquired, 7, "the newest waiter takes the freed permit")

        gate.endTask(first)
        gate.endTask(first)
        let extra = gate.acquire { acquired += 1 }

        XCTAssertEqual(
            acquired, 7,
            "repeated releases of an already-released token must not promote the second waiter"
        )

        _ = rest
        _ = waiters
        _ = extra
    }

    // 4c. A token the gate never granted cannot free a permit.
    func test4c_anUnknownTokenCannotFreeAPermit() {
        let gate = LNGTDAuctionGate()
        var acquired = 0

        let held = (0..<6).map { _ in gate.acquire { acquired += 1 } }
        XCTAssertEqual(acquired, 6)

        gate.endTask(LNGTDAuctionGateToken(rawValue: 9_999))
        let extra = gate.acquire { acquired += 1 }

        XCTAssertEqual(acquired, 6, "a foreign token must not open a seventh slot")

        _ = held
        _ = extra
    }
}
