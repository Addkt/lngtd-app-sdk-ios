import XCTest
import Foundation
@testable import LongitudeCore

final class LNGTDSessionTests: XCTestCase {

    private var mockClock: MockClock!
    private var session: LNGTDSession!

    override func setUp() {
        super.setUp()
        mockClock = MockClock()
        session = LNGTDSession(clock: { [weak mockClock] in mockClock?.now() ?? 0 })
    }

    override func tearDown() {
        session = nil
        mockClock = nil
        super.tearDown()
    }

    // 1. A fresh session has depth 0 after the first trackScreenView, and referrer nil.
    func testFirstScreenView() {
        session.trackScreenView("Home")
        XCTAssertEqual(session.sessionDepth, 0)
        XCTAssertNil(session.referrer)
        XCTAssertEqual(session.page, "Home")
    }

    // 2. Depths 0, 1, 2, 3 map to buckets A, B, B, C via FloorRequest.depthBucket.
    func testDepthBuckets() {
        func bucket(for depth: Int) -> String {
            return FloorRequest(
                auctionId: "", platform: "", country: "", deviceClass: "", section: "",
                sessionDepth: depth, uid: "", baseFloor: .missing, dynamicFloorsEnabled: false,
                dynamicFloorParameters: .missing, floors: .missing
            ).depthBucket
        }

        XCTAssertEqual(bucket(for: 0), "A")
        XCTAssertEqual(bucket(for: 1), "B")
        XCTAssertEqual(bucket(for: 2), "B")
        XCTAssertEqual(bucket(for: 3), "C")
    }

    // 3. pageviewId changes on every screen view; sessionId does not.
    func testIdsOnScreenView() {
        let initialSessionId = session.sessionId
        let initialPageviewId = session.pageviewId

        session.trackScreenView("Screen1")
        let sessionId1 = session.sessionId
        let pageviewId1 = session.pageviewId

        XCTAssertEqual(initialSessionId, sessionId1)
        XCTAssertNotEqual(initialPageviewId, pageviewId1)

        session.trackScreenView("Screen2")
        let sessionId2 = session.sessionId
        let pageviewId2 = session.pageviewId

        XCTAssertEqual(sessionId1, sessionId2)
        XCTAssertNotEqual(pageviewId1, pageviewId2)
    }

    // 4. referrer is the previous screen name, and the same name twice behaves as you decided.
    func testReferrerAndRepeatedScreenNames() {
        session.trackScreenView("A")
        XCTAssertNil(session.referrer)
        XCTAssertEqual(session.page, "A")
        XCTAssertEqual(session.sessionDepth, 0)

        session.trackScreenView("B")
        XCTAssertEqual(session.referrer, "A")
        XCTAssertEqual(session.page, "B")
        XCTAssertEqual(session.sessionDepth, 1)

        // Tracking the same screen name again counts as a new pageview.
        session.trackScreenView("B")
        XCTAssertEqual(session.referrer, "B")
        XCTAssertEqual(session.page, "B")
        XCTAssertEqual(session.sessionDepth, 2)
    }

    // 5. Background 31 minutes then foreground: new sessionId, depth resets.
    func testBackground31MinutesResetsSession() {
        session.trackScreenView("A")
        session.trackScreenView("B")
        let id1 = session.sessionId
        XCTAssertEqual(session.sessionDepth, 1)

        session.didEnterBackground()
        mockClock.currentTime += (31 * 60)
        session.willEnterForeground()

        let id2 = session.sessionId
        XCTAssertNotEqual(id1, id2)
        XCTAssertEqual(session.sessionDepth, 0)
    }

    // 6. Background exactly 30 minutes: assert the boundary you chose, and comment which side is inclusive.
    func testBackgroundExactly30MinutesResetsSession() {
        // The boundary chosen is inclusive: exactly 30 minutes in the background expires the session.
        session.trackScreenView("A")
        let id1 = session.sessionId

        session.didEnterBackground()
        mockClock.currentTime += (30 * 60)
        session.willEnterForeground()

        let id2 = session.sessionId
        XCTAssertNotEqual(id1, id2)
    }

    // 7. Background 29:59 then foreground: same session, depth preserved.
    func testBackground29Mins59SecsPreservesSession() {
        session.trackScreenView("A")
        session.trackScreenView("B")
        let id1 = session.sessionId
        let depth1 = session.sessionDepth

        session.didEnterBackground()
        mockClock.currentTime += (30 * 60) - 1
        session.willEnterForeground()

        let id2 = session.sessionId
        XCTAssertEqual(id1, id2)
        XCTAssertEqual(session.sessionDepth, depth1)
    }

    // 8. Two background spells of 20 minutes each, foregrounded between: same session.
    func testTwoShortBackgroundSpellsPreservesSession() {
        let id1 = session.sessionId

        session.didEnterBackground()
        mockClock.currentTime += (20 * 60)
        session.willEnterForeground()

        mockClock.currentTime += 60 // 1 minute in foreground

        session.didEnterBackground()
        mockClock.currentTime += (20 * 60)
        session.willEnterForeground()

        let id2 = session.sessionId
        XCTAssertEqual(id1, id2)
    }

    // 9. Two hours in the foreground with no backgrounding: same session.
    func testTwoHoursInForegroundPreservesSession() {
        let id1 = session.sessionId

        mockClock.currentTime += (2 * 60 * 60)

        let id2 = session.sessionId
        XCTAssertEqual(id1, id2)
    }

    // 10. Foreground without a prior background does not start a new session or reset depth.
    func testForegroundWithoutBackgroundPreservesSession() {
        session.trackScreenView("A")
        session.trackScreenView("B")
        let id1 = session.sessionId
        let depth1 = session.sessionDepth

        session.willEnterForeground()

        let id2 = session.sessionId
        XCTAssertEqual(id1, id2)
        XCTAssertEqual(session.sessionDepth, depth1)
    }

    // 11. Sampling: rate 0 samples nothing, rate 1 samples everything, with an injected hash.
    func testSamplingBoundariesWithInjectedHash() {
        let sampler = LNGTDSampler(salt: "salt") { _ in return UInt64.max / 4 }

        let session1 = LNGTDSession(clock: { 0 })
        XCTAssertFalse(session1.isSampled(sampler: sampler, sampleRate: 0.0))

        let session2 = LNGTDSession(clock: { 0 })
        XCTAssertTrue(session2.isSampled(sampler: sampler, sampleRate: 1.0))
    }

    // 12. Sampling is stable for a given session id and salt across repeated calls.
    func testSamplingStability() {
        // We use a mock hash that returns a value below a 50% rate.
        let sampler = LNGTDSampler(salt: "salt") { _ in return UInt64.max / 4 }

        let decision1 = session.isSampled(sampler: sampler, sampleRate: 0.5)
        let decision2 = session.isSampled(sampler: sampler, sampleRate: 0.5)

        XCTAssertEqual(decision1, decision2)
    }

    // 13. A different salt changes the outcome for at least one session id.
    func testDifferentSaltChangesOutcome() {
        // We test the actual hash function (fnv1a) to prove salt reaches it.
        let sampler1 = LNGTDSampler(salt: "salt1")
        let sampler2 = LNGTDSampler(salt: "salt2")

        var foundDifference = false
        for _ in 0..<100 {
            let s = LNGTDSession(clock: { 0 })
            let decision1 = sampler1.isSampled(sessionId: s.sessionId, sampleRate: 0.5)
            let decision2 = sampler2.isSampled(sessionId: s.sessionId, sampleRate: 0.5)
            if decision1 != decision2 {
                foundDifference = true
                break
            }
        }

        XCTAssertTrue(foundDifference, "A different salt should eventually produce a different sampling decision.")
    }

    // 14. The decision does not change when sampleRate changes mid-session.
    func testMidSessionSampleRateChangeDoesNotFlipDecision() {
        let sampler = LNGTDSampler(salt: "salt") { _ in return UInt64.max / 4 }

        // Initial evaluation at 0.0 rate (so decision is false)
        let decision1 = session.isSampled(sampler: sampler, sampleRate: 0.0)
        XCTAssertFalse(decision1)

        // Next evaluation at 1.0 rate mid-session should still return false
        let decision2 = session.isSampled(sampler: sampler, sampleRate: 1.0)
        XCTAssertFalse(decision2)
    }

    // 15. A rate above 1 or below 0 is handled as you documented.
    func testOutOFRangeSampleRates() {
        let sampler = LNGTDSampler(salt: "salt") { _ in return UInt64.max / 4 }

        // Below 0 clamped to 0 (never sampled)
        let session1 = LNGTDSession(clock: { 0 })
        XCTAssertFalse(session1.isSampled(sampler: sampler, sampleRate: -0.5))

        // Above 1 clamped to 1 (always sampled)
        let session2 = LNGTDSession(clock: { 0 })
        XCTAssertTrue(session2.isSampled(sampler: sampler, sampleRate: 1.5))

        // Web-style 1-100 values (e.g. 50 meaning 50%) should be clamped to 1.
        let session3 = LNGTDSession(clock: { 0 })
        XCTAssertTrue(session3.isSampled(sampler: sampler, sampleRate: 50.0))
    }
}

// MARK: - Test Helpers

private class MockClock {
    var currentTime: TimeInterval = 0
    func now() -> TimeInterval {
        return currentTime
    }
}
