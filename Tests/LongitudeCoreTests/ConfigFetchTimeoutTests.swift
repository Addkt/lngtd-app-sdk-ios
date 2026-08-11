import XCTest
@testable import LongitudeCore

/// The per-caller timeout is about **wall-clock behaviour**, so these tests measure
/// elapsed time. Asserting only on the returned outcome is not enough: the original
/// implementation returned `.failed(.timeout)` after waiting the full request
/// duration — 2.07s against a 0.15s budget — so an outcome-only assertion passed
/// while the timeout did nothing at all.
final class ConfigFetchTimeoutTests: XCTestCase {

    /// Counts invocations and can be made arbitrarily slow.
    private actor SlowTransport: ConfigTransport {
        private let delay: TimeInterval
        private var count = 0

        init(delay: TimeInterval) { self.delay = delay }

        func invocations() -> Int { count }

        func fetch(url: URL, ifNoneMatch etag: String?) async throws -> ConfigTransportResponse {
            count += 1
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return ConfigTransportResponse(
                statusCode: 200,
                etag: "etag-1",
                body: Data(#"{"schema":1,"ttl":3600,"platform":"ios","adUnits":{},"floors":{}}"#.utf8)
            )
        }
    }

    func testCallerIsReleasedWhenItsBudgetExpires() async {
        let transport = SlowTransport(delay: 2.0)
        let coordinator = ConfigFetchCoordinator(
            transport: transport, timeout: 0.15, clock: { 0 }
        )

        let start = ProcessInfo.processInfo.systemUptime
        let outcome = await coordinator.fetch(account: "a", section: "s", etag: nil)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        XCTAssertEqual(outcome, .failed(.timeout))
        XCTAssertLessThan(
            elapsed, 1.0,
            "caller blocked \(String(format: "%.3f", elapsed))s on a 0.15s budget"
        )
    }

    /// The timeout belongs to the caller's wait, not to the shared request. One
    /// impatient slot must not degrade the others: after caller A gives up, the fetch
    /// keeps running and caller B — who waits longer — still gets the config, from a
    /// single transport invocation.
    func testSharedRequestSurvivesACallerTimingOut() async {
        let transport = SlowTransport(delay: 0.4)
        let coordinator = ConfigFetchCoordinator(
            transport: transport, timeout: 0.05, clock: { 0 }
        )

        // Impatient caller: 50ms budget against a 400ms request.
        let impatient = await coordinator.fetch(account: "a", section: "s", etag: nil)
        XCTAssertEqual(impatient, .failed(.timeout))

        // A patient caller joining the same in-flight request.
        // Same coordinator, waiting long enough. The in-flight task from the first
        // call is still running, so this must join it rather than start a second.
        let joined = await coordinator.fetch(
            account: "a", section: "s", etag: nil, timeout: 2.0
        )

        switch joined {
        case .fetched(let record):
            XCTAssertEqual(record.etag, "etag-1")
        default:
            XCTFail("patient caller should have received the shared result, got \(joined)")
        }

        let invocations = await transport.invocations()
        XCTAssertEqual(
            invocations, 1,
            "the shared request must have been reused, not restarted"
        )
    }

    func testTimeoutIsClampedAtBothEnds() {
        XCTAssertEqual(
            ConfigFetchCoordinator(transport: SlowTransport(delay: 0), timeout: 10).timeout,
            3.0, "above the hard cap must clamp to 3.0"
        )
        XCTAssertGreaterThan(
            ConfigFetchCoordinator(transport: SlowTransport(delay: 0), timeout: -5).timeout,
            0, "a non-positive timeout must not mean wait forever"
        )
        XCTAssertEqual(
            ConfigFetchCoordinator(transport: SlowTransport(delay: 0), timeout: 1.5).timeout,
            1.5, "a value inside the range is untouched"
        )
    }
}
