import XCTest
@testable import LongitudeCore

// MARK: - Doubles

/// Records what reached the sink, in arrival order.
///
/// `descendingYields` makes the *first* send the slowest: send #1 yields that many times,
/// #2 one fewer, and so on. An implementation that fires sends independently therefore
/// records them roughly in reverse, which is what the ordering test needs in order to fail.
final class FakeSink: LNGTDEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPayloads: [LNGTDEventPayload] = []
    private var yieldsRemaining: Int

    init(descendingYields: Int = 0) {
        self.yieldsRemaining = descendingYields
    }

    var payloads: [LNGTDEventPayload] {
        lock.lock()
        defer { lock.unlock() }
        return storedPayloads
    }

    /// Shape and size in one comparable value: `"s"` for a bare object, `"b7"` for a
    /// seven-event array. Lets a test state the whole expected traffic in one assertion.
    var shapes: [String] {
        payloads.map { payload in
            switch payload {
            case .single: return "s"
            case .batch(let events): return "b\(events.count)"
            }
        }
    }

    /// The `appBundle` marker of every event received, flattened in arrival order.
    var markers: [String] {
        payloads.flatMap { payload -> [String] in
            switch payload {
            case .single(let event): return [event.details.custom.appBundle].compactMap { $0 }
            case .batch(let events): return events.compactMap { $0.details.custom.appBundle }
            }
        }
    }

    func send(_ payload: LNGTDEventPayload) async {
        lock.lock()
        let yields = max(yieldsRemaining, 0)
        yieldsRemaining -= 1
        lock.unlock()

        for _ in 0..<yields {
            await Task.yield()
        }

        lock.lock()
        storedPayloads.append(payload)
        lock.unlock()
    }
}

final class FakeReporter: LNGTDEventQueueReporter, @unchecked Sendable {
    private let lock = NSLock()
    private var storedReasons: [LNGTDEventDropReason] = []

    var reasons: [LNGTDEventDropReason] {
        lock.lock()
        defer { lock.unlock() }
        return storedReasons
    }

    func eventQueueDidDrop(_ reason: LNGTDEventDropReason) {
        lock.lock()
        storedReasons.append(reason)
        lock.unlock()
    }
}

/// A settable clock. A captured `var` read from a `@Sendable` closure is a concurrency
/// hazard that only warns under stricter checking; a locked box is unambiguous.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TimeInterval

    init(_ now: TimeInterval = 0) {
        self.stored = now
    }

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
}

// MARK: - Shared fixtures

func makeQueueEvent(
    name: LNGTDEventName = .appForeground,
    appBundle: String = "com.example.app"
) -> LNGTDEvent {
    LNGTDEvent(
        event: name,
        details: LNGTDEvent.Details(
            deviceType: .phone,
            custom: LNGTDEventCustomDetails(platform: .ios, appBundle: appBundle)
        )
    )
}

func makeQueue(
    sink: FakeSink,
    reporter: FakeReporter? = nil,
    clock: TestClock = TestClock(),
    sampled: Bool = true
) -> LNGTDEventQueue {
    LNGTDEventQueue(
        sink: sink,
        reporter: reporter,
        clock: { clock.now },
        isSampled: { sampled }
    )
}

// MARK: - Triggers, batching and size limits

/// Every assertion here is exact rather than expectation-and-timeout, because sends are
/// deferred into a task and `awaitPendingSends()` drains them. The delivered tests used the
/// pattern "do the thing that must not send, install an expectation, do the thing that must
/// send" — which cannot work, since the first send's task runs *after* the expectation is
/// installed and fulfils it. That let the flush interval be changed from 5s to 4s with all
/// fifteen tests still passing.
final class LNGTDEventQueueTests: XCTestCase {

    // 1.
    func test01_FortyNineEventsDoNotFlush() async {
        let sink = FakeSink()
        let queue = makeQueue(sink: sink)

        for _ in 0..<49 {
            await queue.enqueue(makeQueueEvent())
        }
        await queue.awaitPendingSends()

        XCTAssertEqual(sink.shapes, [], "nothing may be sent before the queue reaches 50")
    }

    // 2.
    func test02_FiftiethEventFlushesExactlyFifty() async {
        let sink = FakeSink()
        let queue = makeQueue(sink: sink)

        for _ in 0..<50 {
            await queue.enqueue(makeQueueEvent())
        }
        await queue.awaitPendingSends()

        XCTAssertEqual(sink.shapes, ["b50"], "one batch of exactly 50, never 49 or 51")
    }

    // 3.
    func test03_FiftyFirstEventStartsTheNextBatch() async {
        let sink = FakeSink()
        let queue = makeQueue(sink: sink)

        for _ in 0..<51 {
            await queue.enqueue(makeQueueEvent())
        }
        await queue.awaitPendingSends()
        XCTAssertEqual(sink.shapes, ["b50"], "the 51st must not join the flushed batch")

        await queue.flush()
        await queue.awaitPendingSends()
        XCTAssertEqual(sink.shapes, ["b50", "b1"], "the 51st is the sole member of the next batch")
    }

    // 4.
    func test04_FlushIntervalIsFiveSecondsNotLess() async {
        let clock = TestClock(0)
        let sink = FakeSink()
        let queue = makeQueue(sink: sink, clock: clock)

        await queue.enqueue(makeQueueEvent())

        clock.now = 4.999
        await queue.tick()
        await queue.awaitPendingSends()
        XCTAssertEqual(sink.shapes, [], "4999ms must not flush; the interval is 5000ms")

        clock.now = 5.000
        await queue.tick()
        await queue.awaitPendingSends()
        XCTAssertEqual(sink.shapes, ["b1"], "5000ms must flush")
    }

    // 5.
    func test05_TickOnAnEmptyQueueSendsNothing() async {
        let clock = TestClock(0)
        let sink = FakeSink()
        let queue = makeQueue(sink: sink, clock: clock)

        clock.now = 5.0
        await queue.tick()
        await queue.awaitPendingSends()

        XCTAssertEqual(sink.shapes, [], "an empty tick must not post an empty array")
    }

    // 6.
    func test06_CrossingThePayloadCapFlushesFirst() async {
        let sink = FakeSink()
        let queue = makeQueue(sink: sink)
        let big = String(repeating: "A", count: 90_000)

        await queue.enqueue(makeQueueEvent(appBundle: big))
        await queue.enqueue(makeQueueEvent(appBundle: big))
        await queue.awaitPendingSends()
        XCTAssertEqual(sink.shapes, [], "two ~90KB events still fit under 200000 bytes")

        await queue.enqueue(makeQueueEvent(appBundle: big))
        await queue.awaitPendingSends()
        XCTAssertEqual(sink.shapes, ["b2"], "the third flushes the pending two rather than joining them")

        await queue.flush()
        await queue.awaitPendingSends()
        XCTAssertEqual(
            sink.shapes, ["b2", "b1"],
            "the event that crossed the cap starts the next batch; it must not be dropped"
        )
    }

    // 7.
    func test07_ThePayloadCapCountsUTF8BytesNotCharacters() async {
        let sink = FakeSink()
        let queue = makeQueue(sink: sink)

        // "é" is one Character and one UTF-16 code unit, but two UTF-8 bytes. Two of these
        // events are ~190000 characters (under the cap) and ~380000 bytes (over it), so an
        // implementation using String.count or .utf16.count would not flush here.
        let multiByte = String(repeating: "é", count: 95_000)

        await queue.enqueue(makeQueueEvent(appBundle: multiByte))
        await queue.enqueue(makeQueueEvent(appBundle: multiByte))
        await queue.awaitPendingSends()

        XCTAssertEqual(sink.shapes, ["b1"], "the cap is bytes: 380000 bytes exceeds 200000")
    }

    // 8.
    func test08_AnOversizedEventIsDroppedAndReportedWithoutLooping() async {
        let sink = FakeSink()
        let reporter = FakeReporter()
        let queue = makeQueue(sink: sink, reporter: reporter)

        await queue.enqueue(makeQueueEvent(appBundle: String(repeating: "B", count: 250_000)))
        await queue.awaitPendingSends()

        XCTAssertEqual(sink.shapes, [], "an event that fits no batch must not be sent at all")
        XCTAssertEqual(reporter.reasons, [.oversized], "reported once, not once per retry")

        // The queue must still be usable: a "flush then retry the append" implementation
        // would have looped or wedged here.
        await queue.enqueue(makeQueueEvent(appBundle: "after"))
        await queue.flush()
        await queue.awaitPendingSends()
        XCTAssertEqual(sink.shapes, ["b1"])
        XCTAssertEqual(sink.markers, ["after"])
    }

    // 9.
    func test09_AnImmediateEventIsSentAtOnceAsABareObject() async throws {
        let sink = FakeSink()
        let queue = makeQueue(sink: sink)

        await queue.enqueue(makeQueueEvent(name: .pageview))
        await queue.awaitPendingSends()

        XCTAssertEqual(sink.shapes, ["s"], "an immediate event does not wait for a batch")

        let data = try JSONEncoder().encode(sink.payloads[0])
        XCTAssertTrue(
            try JSONSerialization.jsonObject(with: data) is [String: Any],
            "an immediate event goes as a bare object, not a one-element array"
        )
    }

    // 10.
    func test10_ABatchEncodesAsAJSONArray() async throws {
        let sink = FakeSink()
        let queue = makeQueue(sink: sink)

        await queue.enqueue(makeQueueEvent())
        await queue.flush()
        await queue.awaitPendingSends()

        XCTAssertEqual(sink.shapes, ["b1"])

        let data = try JSONEncoder().encode(sink.payloads[0])
        XCTAssertTrue(
            try JSONSerialization.jsonObject(with: data) is [Any],
            "a batch goes as an array even when it holds a single event"
        )
    }

    // 11.
    func test11_AnImmediateEventLeavesThePendingBatchAlone() async {
        let sink = FakeSink()
        let queue = makeQueue(sink: sink)

        await queue.enqueue(makeQueueEvent(name: .appForeground, appBundle: "queued"))
        await queue.enqueue(makeQueueEvent(name: .pageview, appBundle: "immediate"))
        await queue.awaitPendingSends()

        XCTAssertEqual(sink.shapes, ["s"], "the immediate event must not drag the batch with it")
        XCTAssertEqual(sink.markers, ["immediate"])

        await queue.flush()
        await queue.awaitPendingSends()
        XCTAssertEqual(sink.shapes, ["s", "b1"])
        XCTAssertEqual(
            sink.markers, ["immediate", "queued"],
            "the immediate event must not also have entered the batch"
        )
    }

    // 12.
    func test12_AnUnsampledSessionSendsNothingAndIsReportedOnce() async {
        let sink = FakeSink()
        let reporter = FakeReporter()
        let queue = makeQueue(sink: sink, reporter: reporter, sampled: false)

        await queue.enqueue(makeQueueEvent(name: .appForeground))
        await queue.enqueue(makeQueueEvent(name: .pageview))
        await queue.flush()
        await queue.awaitPendingSends()

        XCTAssertEqual(sink.shapes, [], "an unsampled session sends nothing, immediate included")
        XCTAssertEqual(
            reporter.reasons, [.notSampled(count: 2)],
            "counted and reported once, not once per dropped event"
        )
    }

    // 13.
    func test13_ABatchPreservesInsertionOrder() async {
        let sink = FakeSink()
        let queue = makeQueue(sink: sink)

        for marker in ["1", "2", "3", "4"] {
            await queue.enqueue(makeQueueEvent(appBundle: marker))
        }
        await queue.flush()
        await queue.awaitPendingSends()

        XCTAssertEqual(sink.markers, ["1", "2", "3", "4"], "events are time-ordered facts")
    }

    // 14.
    func test14_ASecondFlushWithNothingPendingSendsNothing() async {
        let sink = FakeSink()
        let queue = makeQueue(sink: sink)

        await queue.enqueue(makeQueueEvent())
        await queue.flush()
        await queue.awaitPendingSends()
        XCTAssertEqual(sink.shapes, ["b1"])

        await queue.flush()
        await queue.awaitPendingSends()
        XCTAssertEqual(sink.shapes, ["b1"], "flush emptied the queue; the second must be a no-op")
    }
}
