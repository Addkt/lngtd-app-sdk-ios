import XCTest
@testable import LongitudeCore

/// Named distinctly. A Swift test target is one module, and `FakeTransport`,
/// `FakeEventTransport` and `PipelineFakeTransport` are all already declared in it — the
/// delivered file redeclared the third, which shadowed it and broke every 2e-5 pipeline test.
///
/// This conforms to the real `LNGTDEventTransport`: `send(payload: Data)` returning an
/// `LNGTDEventTransportResult`. The delivered double declared
/// `send(_: LNGTDEventPayload) -> Result<Void, Error>`, which is not a protocol this package
/// has, so all thirteen tests were written against an API that does not exist.
final class PageviewFakeTransport: LNGTDEventTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPayloads: [Data] = []

    var payloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storedPayloads
    }

    func send(payload: Data) async -> LNGTDEventTransportResult {
        lock.lock()
        storedPayloads.append(payload)
        lock.unlock()
        return .success
    }
}

/// Settable clock shared by the session and the queue.
final class PageviewTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TimeInterval

    init(_ now: TimeInterval = 1_000) { stored = now }

    var now: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }

    func advance(by seconds: TimeInterval) { now += seconds }
}

/// Holds the sample rate the way `Longitude` does: a synchronously readable box, because the
/// queue's sampling gate is a sync closure while the rate arrives from an actor.
final class PageviewRateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Double

    init(_ rate: Double) { stored = rate }

    var rate: Double {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

private enum PageviewFixtureError: Error {
    case notAJSONObject
    case missingDetails
    case missingCustom
}

final class LNGTDPageviewTests: XCTestCase {

    private var tempDir = FileManager.default.temporaryDirectory
    private let clock = PageviewTestClock()

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lngtd-pageview-\(UUID().uuidString)")
        clock.now = 1_000
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Fixtures

    private struct SUT {
        let pipeline: LNGTDEventPipeline
        let transport: PageviewFakeTransport
        let session: LNGTDSession
        let rateBox: PageviewRateBox
    }

    private func makeSUT(sampleRate: Double = 1.0, salt: String = "TestSalt") -> SUT {
        let transport = PageviewFakeTransport()
        let session = LNGTDSession(clock: { [clock] in clock.now })
        let sampler = LNGTDSampler(salt: salt)
        let rateBox = PageviewRateBox(sampleRate)

        let pipeline = LNGTDEventPipeline(
            store: LNGTDEventStore(baseDirectory: tempDir),
            transport: transport,
            backgroundHost: nil,
            session: session,
            isSampled: { session.isSampled(sampler: sampler, sampleRate: rateBox.rate) },
            clock: { [clock] in clock.now }
        )
        return SUT(pipeline: pipeline, transport: transport, session: session, rateBox: rateBox)
    }

    /// Drains the pipeline's fire-and-forget work, then the queue's send chain. A pageview is an
    /// immediate event so it needs no tick, but it still leaves asynchronously.
    private func settle(_ sut: SUT) async {
        await sut.pipeline.quiesce()
        await sut.pipeline.queue.awaitPendingSends()
    }

    /// A pageview is sent as a bare object, so the payload parses as a single JSON object.
    private func object(in payload: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw PageviewFixtureError.notAJSONObject
        }
        return object
    }

    private func details(in payload: Data) throws -> [String: Any] {
        guard let details = try object(in: payload)["details"] as? [String: Any] else {
            throw PageviewFixtureError.missingDetails
        }
        return details
    }

    /// `custom` is a JSON-encoded *string* nested in `details`, per 2e-2.
    private func custom(in payload: Data) throws -> [String: Any] {
        guard let raw = try details(in: payload)["custom"] as? String,
              let parsed = try JSONSerialization.jsonObject(with: Data(raw.utf8))
                as? [String: Any] else {
            throw PageviewFixtureError.missingCustom
        }
        return parsed
    }

    // MARK: - Cases

    // 1.
    func test01_AScreenViewEmitsOnePageviewAsABareObject() async throws {
        let sut = makeSUT()

        sut.pipeline.trackScreenView("Home")
        await settle(sut)

        XCTAssertEqual(sut.transport.payloads.count, 1)
        let payload = sut.transport.payloads[0]
        XCTAssertEqual(payload.first, UInt8(ascii: "{"), "pageview is immediate: a bare object")
        XCTAssertEqual(try object(in: payload)["event"] as? String, "pageview")
    }

    // 2.
    func test02_TheFirstScreenViewIsDepthZero() async throws {
        let sut = makeSUT()

        sut.pipeline.trackScreenView("Home")
        await settle(sut)

        let details = try details(in: sut.transport.payloads[0])
        XCTAssertEqual(details["page"] as? String, "Home")
        XCTAssertEqual(
            details["session_depth"] as? Int, 0,
            "zero-based, matching config.js:397-418 — the web reports 0 on the first pageview"
        )
    }

    // 3.
    func test03_TheFirstScreenViewHasNoReferrer() async throws {
        let sut = makeSUT()

        sut.pipeline.trackScreenView("Home")
        await settle(sut)

        XCTAssertNil(try details(in: sut.transport.payloads[0])["referrer_url"])
    }

    // 4.
    func test04_ASecondScreenViewCarriesDepthOneAndTheFirstAsReferrer() async throws {
        let sut = makeSUT()

        sut.pipeline.trackScreenView("Home")
        sut.pipeline.trackScreenView("Feed")
        await settle(sut)

        XCTAssertEqual(sut.transport.payloads.count, 2)
        let second = try details(in: sut.transport.payloads[1])
        XCTAssertEqual(second["page"] as? String, "Feed")
        XCTAssertEqual(second["session_depth"] as? Int, 1)
        XCTAssertEqual(
            second["referrer_url"] as? String, "Home",
            "the referrer is the previous screen, captured before it was overwritten"
        )
    }

    // 5.
    func test05_TwoViewsInOneSessionShareTheSessionId() async throws {
        let sut = makeSUT()

        sut.pipeline.trackScreenView("Home")
        sut.pipeline.trackScreenView("Feed")
        await settle(sut)

        let first = try custom(in: sut.transport.payloads[0])["session_id"] as? String
        let second = try custom(in: sut.transport.payloads[1])["session_id"] as? String
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    // 6.
    func test06_EachViewHasItsOwnPageviewId() async throws {
        let sut = makeSUT()

        sut.pipeline.trackScreenView("Home")
        sut.pipeline.trackScreenView("Feed")
        await settle(sut)

        let first = try custom(in: sut.transport.payloads[0])["pageview_id"] as? String
        let second = try custom(in: sut.transport.payloads[1])["pageview_id"] as? String
        XCTAssertNotNil(first)
        XCTAssertNotEqual(first, second, "a pageview id identifies one screen view, not a session")
    }

    // 7.
    func test07_AnUnsampledSessionEmitsNothing() async throws {
        let sut = makeSUT(sampleRate: 0.0)

        sut.pipeline.trackScreenView("Home")
        sut.pipeline.trackScreenView("Feed")
        await settle(sut)

        XCTAssertEqual(
            sut.transport.payloads.count, 0,
            "an immediate event is still gated by sampling — being immediate is about latency"
        )
    }

    // 8.
    func test08_AThirtyOneMinuteBackgroundStartsANewSession() async throws {
        let sut = makeSUT()

        sut.pipeline.trackScreenView("Home")
        sut.pipeline.trackScreenView("Feed")
        await settle(sut)
        let before = try custom(in: sut.transport.payloads[1])["session_id"] as? String

        sut.session.didEnterBackground()
        clock.advance(by: 31 * 60)
        sut.session.willEnterForeground()

        sut.pipeline.trackScreenView("Home")
        await settle(sut)

        let after = try custom(in: sut.transport.payloads[2])["session_id"] as? String
        XCTAssertNotNil(after)
        XCTAssertNotEqual(before, after, "31 minutes suspended expires the session")

        let details = try details(in: sut.transport.payloads[2])
        XCTAssertEqual(details["session_depth"] as? Int, 0, "depth restarts with the new session")
        XCTAssertNil(details["referrer_url"], "and so does the referrer chain")
    }

    // 9.
    func test09_ATwentyNineMinuteBackgroundPreservesTheSession() async throws {
        let sut = makeSUT()

        sut.pipeline.trackScreenView("Home")
        await settle(sut)
        let before = try custom(in: sut.transport.payloads[0])["session_id"] as? String

        sut.session.didEnterBackground()
        clock.advance(by: 29 * 60)
        sut.session.willEnterForeground()

        sut.pipeline.trackScreenView("Feed")
        await settle(sut)

        XCTAssertEqual(try custom(in: sut.transport.payloads[1])["session_id"] as? String, before)
        XCTAssertEqual(try details(in: sut.transport.payloads[1])["session_depth"] as? Int, 1)
    }

    // 10. The test that fails if the cached decision outlives the session.
    func test10_TheSamplingDecisionIsReEvaluatedForANewSession() async throws {
        // A sampler whose answer depends only on how many times it has been asked, so the second
        // session necessarily decides differently from the first. If `resetSession()` kept the
        // cached decision, the second session would inherit `true` and emit — which is what
        // per-install rather than per-session sampling looks like.
        let asked = PageviewRateBox(0)
        let flipping = LNGTDSampler(salt: "flip", hash: { _ in
            asked.rate += 1
            // First call hashes low (sampled at 0.5), second hashes high (not sampled).
            return asked.rate == 1 ? 0 : UInt64.max
        })

        let transport = PageviewFakeTransport()
        let session = LNGTDSession(clock: { [clock] in clock.now })
        let pipeline = LNGTDEventPipeline(
            store: LNGTDEventStore(baseDirectory: tempDir),
            transport: transport,
            backgroundHost: nil,
            session: session,
            isSampled: { session.isSampled(sampler: flipping, sampleRate: 0.5) },
            clock: { [clock] in clock.now }
        )
        let sut = SUT(
            pipeline: pipeline, transport: transport, session: session, rateBox: asked
        )

        pipeline.trackScreenView("Home")
        await settle(sut)
        XCTAssertEqual(transport.payloads.count, 1, "first session sampled in")

        session.didEnterBackground()
        clock.advance(by: 31 * 60)
        session.willEnterForeground()

        pipeline.trackScreenView("Feed")
        await settle(sut)

        XCTAssertEqual(
            transport.payloads.count, 1,
            "the new session must get its own decision, not inherit the old one"
        )
        XCTAssertEqual(asked.rate, 2, "the sampler was consulted a second time")
    }

    // 11.
    func test11_RateZeroSamplesNothingAndRateOneSamplesEverything() async throws {
        let none = makeSUT(sampleRate: 0.0)
        none.pipeline.trackScreenView("Home")
        await settle(none)
        XCTAssertEqual(none.transport.payloads.count, 0)

        let all = makeSUT(sampleRate: 1.0)
        all.pipeline.trackScreenView("Home")
        await settle(all)
        XCTAssertEqual(all.transport.payloads.count, 1)
    }

    // 12.
    func test12_TheVeryFirstScreenViewUsesTheSeededRate() async throws {
        // The rate box is seeded from the bundled config before any screen view happens, so a
        // bundled rate of 0.0 must suppress the very first pageview of a cold launch. If the gate
        // defaulted to 1.0 while waiting for the network, this would emit — and at a low rate the
        // first session of every launch would be sampled in, biasing the sample toward first
        // sessions with nothing surfacing an error.
        let sut = makeSUT(sampleRate: 0.0)

        sut.pipeline.trackScreenView("Home")
        await settle(sut)

        XCTAssertEqual(sut.transport.payloads.count, 0)
    }

    // 13.
    func test13_TrackScreenViewBeforeStartIsANoOp() async throws {
        // The pipeline exists but `start()` has not been called: no timer, no launch drain. A
        // screen view must still be safe, and must not lose the event.
        let sut = makeSUT()

        sut.pipeline.trackScreenView("Home")
        await settle(sut)

        XCTAssertEqual(sut.transport.payloads.count, 1, "no crash, and the pageview still leaves")
    }
}
