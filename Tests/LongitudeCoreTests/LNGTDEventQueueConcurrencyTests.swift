import XCTest
@testable import LongitudeCore

/// Handoff properties, split out so the trigger tests stay under `type_body_length`.
///
/// These cover the two things the delivered tests asserted in prose but not in code: that
/// batches reach the sink in order, and that the incremental byte accounting is exact.
final class LNGTDEventQueueConcurrencyTests: XCTestCase {

    // 15.
    func test15_EventsEnqueuedDuringAnInFlightSendAreNeitherLostNorDuplicated() async {
        // The first send yields six times before recording, so it is genuinely still in
        // flight while the events below are enqueued.
        let sink = FakeSink(descendingYields: 6)
        let queue = makeQueue(sink: sink)

        await queue.enqueue(makeQueueEvent(appBundle: "a"))
        await queue.flush()

        // Deliberately not awaiting the send: this is the overlap the case is about.
        await queue.enqueue(makeQueueEvent(appBundle: "b"))
        await queue.enqueue(makeQueueEvent(appBundle: "c"))
        await queue.flush()

        await queue.awaitPendingSends()

        XCTAssertEqual(sink.shapes, ["b1", "b2"])
        XCTAssertEqual(
            sink.markers, ["a", "b", "c"],
            "every enqueued event arrives exactly once — none lost behind the in-flight send, "
            + "none duplicated into two batches"
        )
    }

    // 16. Not in the brief: added because deleting the send chain entirely left all
    // fifteen delivered tests passing, so the ordering guarantee was unverified.
    func test16_BatchesReachTheSinkInTheOrderTheyWereProduced() async {
        // Send #1 yields eight times, #2 seven, and so on. The first batch is therefore
        // the slowest, so an implementation that fires sends independently records them in
        // roughly reverse order.
        let sink = FakeSink(descendingYields: 8)
        let queue = makeQueue(sink: sink)

        for marker in ["1", "2", "3", "4"] {
            await queue.enqueue(makeQueueEvent(appBundle: marker))
            await queue.flush()
        }
        await queue.awaitPendingSends()

        XCTAssertEqual(sink.shapes, ["b1", "b1", "b1", "b1"])
        XCTAssertEqual(
            sink.markers, ["1", "2", "3", "4"],
            "out-of-order batches would corrupt any funnel built from the event stream"
        )
    }

    // 17. Not in the brief: pins the arithmetic the incremental size accounting relies on.
    func test17_EncodedArraySizeIsBracketsPlusElementsPlusCommas() throws {
        // The queue tracks payload size incrementally rather than re-encoding the whole
        // pending array on every enqueue, which is O(n²). That is only exact if a JSON
        // array costs exactly two brackets plus n-1 commas — true for compact output.
        // Configuring the encoder with .prettyPrinted would inflate the real payload while
        // every budget check still passed, so the relationship is pinned here.
        let encoder = JSONEncoder()
        let events = (0..<5).map { makeQueueEvent(appBundle: "marker-\($0)") }

        let elementBytes = try events.reduce(0) { try $0 + encoder.encode($1).count }
        let arrayBytes = try encoder.encode(events).count

        XCTAssertEqual(
            arrayBytes, 2 + elementBytes + (events.count - 1),
            "compact JSON: two brackets and one comma between elements"
        )
    }

    // 18. Not in the brief: test17 pins the arithmetic in isolation but not that the queue's
    // running total actually agrees with it. Forgetting the brackets and commas is a ~51-byte
    // error on a 200000-byte budget, which no threshold test can see, so compare directly.
    func test18_TheRunningByteTotalEqualsARealEncodeOfPending() async throws {
        let sink = FakeSink()
        let queue = makeQueue(sink: sink)

        for index in 0..<12 {
            await queue.enqueue(makeQueueEvent(appBundle: "marker-\(index)"))
        }

        let tracked = await queue.pendingPayloadBytes()
        let actual = try JSONEncoder().encode(await queue.pendingEvents()).count

        XCTAssertEqual(
            tracked, actual,
            "the queue never re-encodes the pending array, so its running total has to be "
            + "exactly what an encode would produce"
        )
    }

    // 19. Not in the brief: an immediate event is measured as a bare object rather than as a
    // one-element array, and is still capped.
    func test19_TheCapIsCheckedAgainstTheBareObjectForImmediateEvents() async {
        let sink = FakeSink()
        let reporter = FakeReporter()
        let queue = makeQueue(sink: sink, reporter: reporter)

        // An immediate event is sent as a bare object, so it is measured without array
        // brackets — but it is still capped, and still dropped rather than posted.
        await queue.enqueue(
            makeQueueEvent(name: .pageview, appBundle: String(repeating: "C", count: 250_000))
        )
        await queue.awaitPendingSends()

        XCTAssertEqual(sink.shapes, [], "an oversized immediate event is dropped, not posted")
        XCTAssertEqual(reporter.reasons, [.oversized])
    }
}
