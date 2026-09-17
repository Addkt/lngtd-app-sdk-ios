import XCTest
@testable import LongitudeCore

final class ConfigFetchCoordinatorTests: XCTestCase {

    // MARK: - Test 1: 200 returns .fetched
    func test200ReturnsFetchedWithBodyDecodedAndClockStamped() async {
        let transport = FakeTransport()
        transport.responseOverride = ConfigTransportResponse(
            statusCode: 200,
            etag: "my-etag",
            body: validAppConfigData()
        )
        let clock = FetchTestClock()
        clock.time = 12345.0

        let coordinator = ConfigFetchCoordinator(transport: transport, clock: clock.now)
        let outcome = await coordinator.fetch(account: "acc", section: "sec", etag: nil)

        if case .fetched(let record) = outcome {
            XCTAssertEqual(record.etag, "my-etag")
            XCTAssertEqual(record.fetchedAt, 12345.0)
            XCTAssertEqual(record.payload, validAppConfigData())
            XCTAssertNoThrow(try record.decodedPayload())
        } else {
            XCTFail("Expected .fetched, got \(outcome)")
        }
    }

    // MARK: - Test 2: Twenty concurrent callers produce exactly one transport invocation
    func testTwentyConcurrentCallersProduceOneRequest() async {
        let transport = FakeTransport()
        transport.delayNanoseconds = 100_000_000 // 0.1s ensures tasks overlap
        transport.responseOverride = ConfigTransportResponse(
            statusCode: 200,
            etag: "123",
            body: validAppConfigData()
        )

        let coordinator = ConfigFetchCoordinator(transport: transport)

        let outcomes = await withTaskGroup(of: ConfigFetchOutcome.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    return await coordinator.fetch(account: "a", section: "b", etag: nil)
                }
            }
            var results: [ConfigFetchOutcome] = []
            for await outcome in group {
                results.append(outcome)
            }
            return results
        }

        XCTAssertEqual(outcomes.count, 20)
        let invocations = await transport.state.getInvocations()
        XCTAssertEqual(invocations, 1)

        for outcome in outcomes {
            if case .fetched(let record) = outcome {
                XCTAssertEqual(record.etag, "123")
            } else {
                XCTFail("Expected .fetched, got \(outcome)")
            }
        }
    }

    // MARK: - Test 3: Advance clock past window issues second invocation
    func testAdvanceClockPastWindowIssuesSecondInvocation() async {
        let transport = FakeTransport()
        transport.responseOverride = ConfigTransportResponse(
            statusCode: 200,
            etag: nil,
            body: validAppConfigData()
        )
        let clock = FetchTestClock()
        let coordinator = ConfigFetchCoordinator(transport: transport, clock: clock.now)

        _ = await coordinator.fetch(account: "a", section: "b", etag: nil)
        let inv1 = await transport.state.getInvocations()
        XCTAssertEqual(inv1, 1)

        // Advance past 60s window
        clock.time = 61.0
        _ = await coordinator.fetch(account: "a", section: "b", etag: nil)

        let inv2 = await transport.state.getInvocations()
        XCTAssertEqual(inv2, 2)
    }

    // MARK: - Test 4: Failed fetch clears task
    func testFailedFetchClearsTask() async {
        let transport = FakeTransport()
        transport.responseOverride = ConfigTransportResponse(
            statusCode: 500,
            etag: nil,
            body: Data()
        )
        let clock = FetchTestClock()
        let coordinator = ConfigFetchCoordinator(transport: transport, clock: clock.now)

        let outcome1 = await coordinator.fetch(account: "a", section: "b", etag: nil)
        if case .failed = outcome1 { } else { XCTFail("first call should have failed, got \(outcome1)") }

        // Advance past window to verify failure cleared the task and a new fetch occurs
        clock.time = 61.0
        let outcome2 = await coordinator.fetch(account: "a", section: "b", etag: nil)
        if case .failed = outcome2 { } else { XCTFail("second call should have failed, got \(outcome2)") }

        let inv = await transport.state.getInvocations()
        XCTAssertEqual(inv, 2)
    }

    // MARK: - Test 5: If-None-Match sent verbatim
    func testIfNoneMatchSentVerbatim() async {
        let transport = FakeTransport()
        transport.responseOverride = ConfigTransportResponse(
            statusCode: 304,
            etag: nil,
            body: Data()
        )
        let coordinator = ConfigFetchCoordinator(transport: transport)

        _ = await coordinator.fetch(account: "a", section: "b", etag: "W/\"weak-etag\"")

        let reqs = await transport.state.getRequests()
        XCTAssertEqual(reqs.first?.etag, "W/\"weak-etag\"")
    }

    // MARK: - Test 6: 304 returns .notModified and no record
    func test304ReturnsNotModifiedAndNoRecord() async {
        let transport = FakeTransport()
        transport.responseOverride = ConfigTransportResponse(
            statusCode: 304,
            etag: nil,
            body: Data()
        )
        let coordinator = ConfigFetchCoordinator(transport: transport)

        let outcome = await coordinator.fetch(account: "a", section: "b", etag: "123")

        if case .notModified = outcome {
            // Success
        } else {
            XCTFail("Expected .notModified, got \(outcome)")
        }
    }

    // MARK: - Test 7: 200 undecodable returns .failed
    func test200UndecodableReturnsFailed() async {
        let transport = FakeTransport()
        transport.responseOverride = ConfigTransportResponse(
            statusCode: 200,
            etag: nil,
            body: Data("not json".utf8)
        )
        let coordinator = ConfigFetchCoordinator(transport: transport)

        let outcome = await coordinator.fetch(account: "a", section: "b", etag: nil)

        if case .failed(let err) = outcome {
            XCTAssertEqual(err, .decodeError)
        } else {
            XCTFail("Expected .failed(.decodeError)")
        }
    }

    // MARK: - Test 8: 500 returns .failed
    func test500ReturnsFailed() async {
        let transport = FakeTransport()
        transport.responseOverride = ConfigTransportResponse(
            statusCode: 500,
            etag: nil,
            body: Data()
        )
        let coordinator = ConfigFetchCoordinator(transport: transport)

        let outcome = await coordinator.fetch(account: "a", section: "b", etag: nil)

        if case .failed(let err) = outcome {
            XCTAssertEqual(err, .networkError(statusCode: 500))
        } else {
            XCTFail("Expected .failed(.networkError)")
        }
    }

    // MARK: - Test 9: First call never throttled
    ///
    /// Uses an injected clock starting at **0**, which is what "the beginning of a
    /// session" looks like. With the default `systemUptime` clock this test passes
    /// even against a broken throttle: uptime is a large number, so
    /// `now - (lastFetch ?? 0)` is far greater than the window and no throttle
    /// triggers regardless of whether the no-previous-fetch state is handled. At
    /// clock 0 the distinction is live, and the mutation that treats "never fetched"
    /// as "fetched at 0" fails here — which is the point, since that bug would add
    /// 60s of passthrough to every cold launch.
    func testFirstCallNeverThrottled() async {
        let transport = FakeTransport()
        transport.responseOverride = ConfigTransportResponse(
            statusCode: 200,
            etag: nil,
            body: validAppConfigData()
        )
        let clock = FetchTestClock()
        clock.time = 0
        let coordinator = ConfigFetchCoordinator(transport: transport, clock: clock.now)

        let outcome = await coordinator.fetch(account: "a", section: "b", etag: nil)
        if case .throttled = outcome {
            XCTFail("the first call of a session must never be throttled")
        }
        let invocations = await transport.state.getInvocations()
        XCTAssertEqual(invocations, 1, "the first call must reach the transport")
    }

    // MARK: - Test 10: Second call in window returns .throttled with no transport invocation
    func testSecondCallInWindowReturnsThrottledNoTransportInvocation() async {
        let transport = FakeTransport()
        transport.responseOverride = ConfigTransportResponse(
            statusCode: 200,
            etag: nil,
            body: validAppConfigData()
        )
        let clock = FetchTestClock()
        let coordinator = ConfigFetchCoordinator(transport: transport, clock: clock.now)

        _ = await coordinator.fetch(account: "a", section: "b", etag: nil)
        let inv1 = await transport.state.getInvocations()
        XCTAssertEqual(inv1, 1)

        let outcome = await coordinator.fetch(account: "a", section: "b", etag: nil)
        if case .throttled = outcome {
            // Success
        } else {
            XCTFail("Expected .throttled")
        }

        let inv2 = await transport.state.getInvocations()
        XCTAssertEqual(inv2, 1, "Transport should not be invoked again")
    }

    // MARK: - Test 11: 304 stamps throttle window
    func test304StampsThrottleWindow() async {
        let transport = FakeTransport()
        transport.responseOverride = ConfigTransportResponse(
            statusCode: 304,
            etag: nil,
            body: Data()
        )
        let clock = FetchTestClock()
        let coordinator = ConfigFetchCoordinator(transport: transport, clock: clock.now)

        _ = await coordinator.fetch(account: "a", section: "b", etag: "123")

        let outcome = await coordinator.fetch(account: "a", section: "b", etag: "123")
        if case .throttled = outcome {
            // Success
        } else {
            XCTFail("Expected .throttled after a 304")
        }
    }

    // MARK: - Test 12: Failure stamps throttle window
    func testFailureStampsThrottleWindow() async {
        let transport = FakeTransport()
        transport.responseOverride = ConfigTransportResponse(
            statusCode: 500,
            etag: nil,
            body: Data()
        )
        let clock = FetchTestClock()
        let coordinator = ConfigFetchCoordinator(transport: transport, clock: clock.now)

        _ = await coordinator.fetch(account: "a", section: "b", etag: nil)

        let outcome = await coordinator.fetch(account: "a", section: "b", etag: nil)
        if case .throttled = outcome {
            // Success
        } else {
            XCTFail("Expected .throttled after a 500 failure")
        }
    }

    // MARK: - Test 13: Caller timeout elapses gets .failed, shared request continues
    func testCallerTimeoutDoesNotCancelSharedRequest() async {
        let transport = FakeTransport()
        // Delay 0.6s to outlast the 0.3s timeout
        transport.delayNanoseconds = 600_000_000
        transport.responseOverride = ConfigTransportResponse(
            statusCode: 200,
            etag: nil,
            body: validAppConfigData()
        )

        let coordinator = ConfigFetchCoordinator(
            transport: transport,
            timeout: 0.3,
            clock: { 0 }
        )

        async let outcomeA = coordinator.fetch(account: "a", section: "b", etag: nil)
        async let outcomeB = {
            // B arrives 0.4s later. Its timeout starts then, so B's budget goes up to 0.7s absolute time.
            try? await Task.sleep(nanoseconds: 400_000_000)
            return await coordinator.fetch(account: "a", section: "b", etag: nil)
        }()

        let a = await outcomeA
        let b = await outcomeB

        if case .failed(let err) = a {
            XCTAssertEqual(err, .timeout, "Caller A should time out")
        } else {
            XCTFail("Expected A to timeout, got \(a)")
        }

        if case .fetched = b {
            // Success: transport finished at ~0.6s, B was waiting until ~0.7s.
        } else {
            XCTFail("Expected B to receive .fetched, got \(b)")
        }

        let invocations = await transport.state.getInvocations()
        XCTAssertEqual(invocations, 1)
    }

    // MARK: - Test 14: Timeout clamping
    func testTimeoutClamping() async {
        // Checking internal actor state to avoid multi-second real-world waits in tests
        let coordNeg = ConfigFetchCoordinator(transport: FakeTransport(), timeout: -1.0)
        let negTimeout = await coordNeg.timeout
        XCTAssertEqual(negTimeout, 0.001, "Negative timeout should be clamped to floor")

        let coordLarge = ConfigFetchCoordinator(transport: FakeTransport(), timeout: 10.0)
        let largeTimeout = await coordLarge.timeout
        XCTAssertEqual(largeTimeout, 3.0, "Timeouts above 3.0 should be clamped to 3.0")
    }

    // MARK: - Helpers

    private func validAppConfigData() -> Data {
        let json = """
        {
            "schema": 1,
            "platform": "ios",
            "ttl": 3600,
            "adUnits": {},
            "floors": {}
        }
        """
        return json.data(using: .utf8) ?? Data()
    }
}

// MARK: - Fakes

actor FakeTransportState {
    var invocations = 0
    var requests: [(url: URL, etag: String?)] = []

    func addInvocation(url: URL, etag: String?) {
        invocations += 1
        requests.append((url, etag))
    }

    func getInvocations() -> Int { return invocations }
    func getRequests() -> [(url: URL, etag: String?)] { return requests }
}

final class FakeTransport: ConfigTransport, @unchecked Sendable {
    let state = FakeTransportState()

    var responseOverride: ConfigTransportResponse?
    var errorOverride: Error?

    var delayNanoseconds: UInt64 = 0

    func fetch(url: URL, ifNoneMatch etag: String?) async throws -> ConfigTransportResponse {
        await state.addInvocation(url: url, etag: etag)

        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }

        if let errorOverride = errorOverride {
            throw errorOverride
        }

        if let responseOverride = responseOverride {
            return responseOverride
        }

        return ConfigTransportResponse(
            statusCode: 200,
            etag: nil,
            body: Data(#"{"schema":1,"platform":"ios","ttl":3600,"adUnits":{},"floors":{}}"#.utf8)
        )
    }
}

final class FetchTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _time: TimeInterval = 0

    var time: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _time
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _time = newValue
        }
    }

    func now() -> TimeInterval {
        return time
    }
}
