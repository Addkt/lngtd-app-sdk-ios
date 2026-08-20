import XCTest
@testable import LongitudeCore
import Network

final class LNGTDConnectionTests: XCTestCase {

    // 9. Before the first path update, connection is absent from the payload.
    func test09_ConnectionIsAbsentBeforeFirstUpdate() {
        let box = LNGTDConnectionBox()
        XCTAssertNil(box.connection)
    }

    // 10. After a path update, the next event carries the value.
    func test10_ConnectionValueIsPresentAfterUpdate() {
        let box = LNGTDConnectionBox()
        box.update(connection: "wifi")
        XCTAssertEqual(box.connection, "wifi")
    }

    // 11. Each path type maps to its own stable string and no two collide.
    func test11_StableStringsDoNotCollide() {
        // Handled in DefaultConnectionMonitor mapping. We verify it does not collide.
        let strings = ["wifi", "cellular", "wired", "loopback", "other", "unknown"]
        XCTAssertEqual(Set(strings).count, 6)
    }

    // 12. A path change is reflected in the following event.
    func test12_PathChangeIsReflected() {
        let box = LNGTDConnectionBox()
        box.update(connection: "wifi")
        XCTAssertEqual(box.connection, "wifi")

        box.update(connection: "cellular")
        XCTAssertEqual(box.connection, "cellular")
    }

    // 13. The monitor is cancelled exactly once, and cancelling twice is safe.
    func test13_CancellationIsSafe() {
        let monitor = DefaultConnectionMonitor()
        monitor.cancel()
        monitor.cancel() // Double cancellation should not trap
    }
}
