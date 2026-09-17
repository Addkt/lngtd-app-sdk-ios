import XCTest
import Foundation
@testable import LongitudeCore

final class LNGTDGuardTests: XCTestCase {

    private var mockSink: MockSink = MockSink()
    private var mockClock: MockClock = MockClock()
    private var breaker: LNGTDCircuitBreaker = LNGTDCircuitBreaker()

    override func setUp() {
        super.setUp()
        mockSink = MockSink()
        LNGTDGuard.sink = mockSink

        mockClock = MockClock()
        breaker = LNGTDCircuitBreaker(
            threshold: 5,
            window: 60,
            clock: { [weak mockClock] in mockClock?.now() ?? 0 }
        )
    }

    override func tearDown() {
        LNGTDGuard.sink = nil
        super.tearDown()
    }

    // 1. Success returns the body's value and records no failure.
    func testSuccessReturnsValueAndRecordsNoFailure() {
        let result = LNGTDGuard.run("testSuccess", breaker: breaker, fallback: "fallback") {
            return "success"
        }

        XCTAssertEqual(result, "success")
        XCTAssertTrue(mockSink.caughtFailures.isEmpty)
        XCTAssertFalse(breaker.isTripped)
    }

    // 2. A thrown Swift error returns fallback and records one failure.
    func testThrownSwiftErrorReturnsFallbackAndRecordsFailure() {
        struct DummyError: Error {}

        let result = LNGTDGuard.run("testSwiftError", breaker: breaker, fallback: "fallback") {
            throw DummyError()
            return "success"
        }

        XCTAssertEqual(result, "fallback")
        XCTAssertEqual(mockSink.caughtFailures.count, 1)
        XCTAssertFalse(breaker.isTripped)
    }

    // 3. A raised NSException returns fallback and records one failure.
    func testRaisedNSExceptionReturnsFallbackAndRecordsFailure() {
        let result = LNGTDGuard.run("testNSException", breaker: breaker, fallback: "fallback") {
            NSException(name: NSExceptionName("TestException"), reason: "TestReason", userInfo: nil).raise()
            return "success"
        }

        XCTAssertEqual(result, "fallback")
        XCTAssertEqual(mockSink.caughtFailures.count, 1)
        XCTAssertFalse(breaker.isTripped)
    }

    // 4. The failure reported to the sink distinguishes error from exception, and carries the exception's name and reason.
    func testFailureReportDistinguishesErrorAndException() {
        struct DummyError: Error {}

        LNGTDGuard.run("testError", breaker: breaker, fallback: ()) {
            throw DummyError()
        }

        LNGTDGuard.run("testException", breaker: breaker, fallback: ()) {
            NSException(name: NSExceptionName("CustomName"), reason: "CustomReason", userInfo: nil).raise()
        }

        XCTAssertEqual(mockSink.caughtFailures.count, 2)

        let firstFailure = mockSink.caughtFailures[0]
        if case .swiftError = firstFailure.failure {
            // expected
        } else {
            XCTFail("Expected swiftError")
        }

        let secondFailure = mockSink.caughtFailures[1]
        if case .exception(let name, let reason) = secondFailure.failure {
            XCTAssertEqual(name, "CustomName")
            XCTAssertEqual(reason, "CustomReason")
        } else {
            XCTFail("Expected exception")
        }
    }

    // 5. Four failures inside the window do not trip; the fifth does.
    func testFiveFailuresInWindowTripsBreaker() {
        struct DummyError: Error {}

        for _ in 1...4 {
            LNGTDGuard.run("op", breaker: breaker, fallback: ()) { throw DummyError() }
        }

        XCTAssertFalse(breaker.isTripped)
        XCTAssertTrue(mockSink.trippedOperations.isEmpty)

        // 5th failure
        LNGTDGuard.run("op", breaker: breaker, fallback: ()) { throw DummyError() }

        XCTAssertTrue(breaker.isTripped)
        XCTAssertEqual(mockSink.trippedOperations.count, 1)
    }

    // 6. Failures spread either side of the window do not trip.
    func testFailuresOutsideWindowDoNotTrip() {
        struct DummyError: Error {}

        for _ in 1...4 {
            LNGTDGuard.run("op", breaker: breaker, fallback: ()) { throw DummyError() }
        }

        XCTAssertFalse(breaker.isTripped)

        // Advance clock past the 60s window
        mockClock.currentTime = 61

        for _ in 1...4 {
            LNGTDGuard.run("op", breaker: breaker, fallback: ()) { throw DummyError() }
        }

        XCTAssertFalse(breaker.isTripped)
        XCTAssertTrue(mockSink.trippedOperations.isEmpty)
    }

    // 7. Once tripped, run returns fallback without executing body.
    func testTrippedBreakerBypassesBodyAndReturnsFallback() {
        struct DummyError: Error {}
        for _ in 1...5 {
            LNGTDGuard.run("op", breaker: breaker, fallback: ()) { throw DummyError() }
        }

        XCTAssertTrue(breaker.isTripped)

        var bodyExecuted = false
        let result = LNGTDGuard.run("op2", breaker: breaker, fallback: "fallback") {
            bodyExecuted = true
            return "success"
        }

        XCTAssertEqual(result, "fallback")
        XCTAssertFalse(bodyExecuted)
    }

    // 8. Once tripped, further calls do not grow the failure count (by ensuring sink is not called for bypassed execution).
    func testTrippedBreakerDoesNotAccumulateMoreFailures() {
        struct DummyError: Error {}
        for _ in 1...5 {
            LNGTDGuard.run("op", breaker: breaker, fallback: ()) { throw DummyError() }
        }

        let initialCaughtCount = mockSink.caughtFailures.count
        XCTAssertEqual(initialCaughtCount, 5)

        LNGTDGuard.run("op2", breaker: breaker, fallback: ()) { throw DummyError() }

        // Sink should not receive new caught errors since the body was never run
        XCTAssertEqual(mockSink.caughtFailures.count, initialCaughtCount)
    }

    /// An entry ageing out of the window must not discard the entries newer than it.
    ///
    /// This is what distinguishes a real sliding window from "clear the whole list
    /// once the oldest entry is stale" — an easy mistake (`removeAll()` instead of
    /// `removeAll(where:)`) that the spread-apart-failures test above cannot detect,
    /// because under both implementations that scenario simply fails to trip.
    ///
    /// Timeline: failures at t=0, 30, 40, 50, 70, 71. At t=71 the cutoff is 11, so
    /// t=0 has aged out but 30/40/50/70/71 are all still inside the window — five
    /// failures, so it must trip. An implementation that drops everything when the
    /// oldest entry expires is left holding two and never trips.
    func testAgeingOutOneEntryDoesNotDiscardNewerOnes() {
        struct DummyError: Error {}

        for time in [0.0, 30, 40, 50, 70, 71] {
            mockClock.currentTime = time
            LNGTDGuard.run("op", breaker: breaker, fallback: ()) { throw DummyError() }
        }

        XCTAssertTrue(
            breaker.isTripped,
            "five failures inside a 60s window must trip; if this fails, stale "
            + "entries are being removed wholesale rather than individually"
        )
    }

    // 9. guardDidTripBreaker fires exactly once, on the transition.
    func testGuardDidTripBreakerFiresExactlyOnce() {
        struct DummyError: Error {}

        // Ten failing operations through the real guard: the 5th trips and the rest
        // are bypassed, so the sink must see exactly one trip event. Driving this
        // through `run` is the point — the original version of this test called
        // breaker.recordFailure() and then fired mockSink itself, so its assertion
        // was satisfied by the test's own code and it could not have detected the
        // guard reporting a trip on every failure.
        for _ in 1...10 {
            LNGTDGuard.run("op", breaker: breaker, fallback: ()) { throw DummyError() }
        }

        XCTAssertTrue(breaker.isTripped)
        XCTAssertEqual(mockSink.trippedOperations.count, 1)
    }

    // 10. A guarded body that itself calls run does not deadlock.
    func testReentrantGuardCallsDoNotDeadlock() {
        let result = LNGTDGuard.run("outer", breaker: breaker, fallback: "outerFallback") {
            let innerResult = LNGTDGuard.run("inner", breaker: breaker, fallback: "innerFallback") {
                return "innerSuccess"
            }
            return "outerSuccess-\(innerResult)"
        }

        XCTAssertEqual(result, "outerSuccess-innerSuccess")
    }

    // 11. Concurrent recording from multiple queues reaches the right count.
    func testConcurrentRecording() {
        let expectation = XCTestExpectation(description: "Concurrent tasks complete")
        let iterations = 100

        let concurrentBreaker = LNGTDCircuitBreaker(
            threshold: iterations + 1, // High threshold so it never trips and bypasses
            window: 60,
            clock: { [weak mockClock] in mockClock?.now() ?? 0 }
        )

        struct DummyError: Error {}

        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: iterations) { _ in
                LNGTDGuard.run("concurrent", breaker: concurrentBreaker, fallback: ()) {
                    throw DummyError()
                }
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)

        XCTAssertEqual(mockSink.caughtFailures.count, iterations)
        XCTAssertFalse(concurrentBreaker.isTripped)
    }
}

// MARK: - Test Helpers

private class MockClock {
    var currentTime: TimeInterval = 0
    func now() -> TimeInterval {
        return currentTime
    }
}

private class MockSink: LNGTDGuardEventSink {
    private let lock = NSLock()
    var caughtFailures: [(operation: String, failure: LNGTDGuardFailure)] = []
    var trippedOperations: [String] = []

    func guardDidCatch(operation: String, failure: LNGTDGuardFailure) {
        lock.lock(); defer { lock.unlock() }
        caughtFailures.append((operation, failure))
    }

    func guardDidTripBreaker(operation: String) {
        lock.lock(); defer { lock.unlock() }
        trippedOperations.append(operation)
    }
}
