import Foundation

/// Why the queue discarded events.
///
/// One enum case per reason rather than one protocol method per reason: 2e-4 adds more of
/// them (disk full, batch too old, retries exhausted), and a method-per-reason protocol
/// makes each addition a breaking change for every consumer.
public enum LNGTDEventDropReason: Sendable, Equatable {
    /// The event alone exceeds the payload cap, so it can never fit any batch.
    case oversized
    /// The event could not be serialised at all.
    case unencodable
    /// The session is not sampled. Carries a count: reporting per event would flood the
    /// reporter with exactly the volume sampling exists to avoid.
    case notSampled(count: Int)
}

public protocol LNGTDEventQueueReporter: Sendable {
    func eventQueueDidDrop(_ reason: LNGTDEventDropReason)
}

public protocol LNGTDEventSink: Sendable {
    func send(_ payload: LNGTDEventPayload) async
}

/// The two body shapes the collector accepts. The distinction lives here rather than in
/// each sink so no sink has to re-derive it.
public enum LNGTDEventPayload: Sendable, Encodable {
    /// An immediate event, sent on its own as a bare JSON object.
    case single(LNGTDEvent)
    /// A queued batch, sent as a JSON array.
    case batch([LNGTDEvent])

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .single(let event):
            var container = encoder.singleValueContainer()
            try container.encode(event)
        case .batch(let events):
            var container = encoder.unkeyedContainer()
            for event in events {
                try container.encode(event)
            }
        }
    }
}

/// Decides *when* to flush and *what goes in a batch*. Nothing else.
///
/// An actor rather than a lock plus a serial queue: the state here is a handful of
/// properties mutated from both the main thread (screen views, delegate callbacks) and
/// background threads, which is what actor isolation is for, and it keeps the work off
/// main without a queue to own.
public actor LNGTDEventQueue {
    /// `logging.js:262`. A batch never exceeds this.
    static let maxQueueSize = 50
    /// `logging.js:263`, in seconds.
    static let flushInterval: TimeInterval = 5.0
    /// `logging.js:264`, measured here as UTF-8 bytes — see `encodedSize(of:)`.
    static let maxPayloadBytes = 200_000

    private let sink: LNGTDEventSink
    private let reporter: LNGTDEventQueueReporter?
    private let clock: () -> TimeInterval
    private let isSampled: () -> Bool

    /// One encoder, not one per measurement. The size measured here has to be the size the
    /// transport actually sends, so 2e-4 must keep this configuration: `.prettyPrinted` or
    /// `.sortedKeys` downstream would silently invalidate every budget check below.
    private let encoder = JSONEncoder()

    private var pending: [LNGTDEvent] = []

    /// Σ of the encoded size of each event in `pending`, maintained incrementally.
    ///
    /// Re-encoding the whole pending array on every enqueue is O(n²) — for a batch of
    /// fifty ~700-byte events that is roughly 900KB of JSON encoding per batch, all of it
    /// thrown away. `arrayBytes(count:elementBytes:)` recovers the exact payload size from
    /// this sum.
    private var pendingElementBytes = 0

    private var sendTask: Task<Void, Never>?
    private var unsampledDropCount = 0
    private var lastFlushTime: TimeInterval

    public init(
        sink: LNGTDEventSink,
        reporter: LNGTDEventQueueReporter? = nil,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        isSampled: @escaping @Sendable () -> Bool
    ) {
        self.sink = sink
        self.reporter = reporter
        self.clock = clock
        self.isSampled = isSampled
        self.lastFlushTime = clock()
    }

    public func enqueue(_ event: LNGTDEvent) {
        // Sampling is decided per session and gates everything, immediate events included:
        // being immediate is about latency, not about bypassing sampling. Dropped before
        // entering the queue so an unsampled session costs no memory.
        guard isSampled() else {
            unsampledDropCount += 1
            return
        }

        // Unreachable today: every field on `LNGTDEvent` is a String, Int or enum, so the
        // encoder cannot throw, and no test here can force this branch — a mutation to
        // `?? 0` survives the suite. It is kept because the branch becomes live the moment
        // a Double joins the envelope: `JSONEncoder` throws on NaN and infinity by default,
        // and paid-event value arrives as a Double in 2f. At that point `?? 0` would treat
        // an unserialisable event as weightless and queue it, where it would break the
        // whole batch's serialisation and take up to 49 good events down with it.
        guard let eventBytes = encodedSize(of: event) else {
            reporter?.eventQueueDidDrop(.unencodable)
            return
        }

        if event.event.isImmediate {
            // An immediate event goes as a bare object, so its own encoded size *is* the
            // payload size — no brackets to account for.
            if eventBytes > Self.maxPayloadBytes {
                reporter?.eventQueueDidDrop(.oversized)
            } else {
                send(.single(event))
            }
            return
        }

        // An event that alone exceeds the cap can never fit any batch. Dropping it is the
        // only terminating choice: "flush, then retry the append" would flush an empty
        // queue forever. Reported so it is visible rather than silent.
        if Self.arrayBytes(count: 1, elementBytes: eventBytes) > Self.maxPayloadBytes {
            reporter?.eventQueueDidDrop(.oversized)
            return
        }

        let proposedBytes = Self.arrayBytes(
            count: pending.count + 1,
            elementBytes: pendingElementBytes + eventBytes
        )
        if proposedBytes > Self.maxPayloadBytes {
            flushPending()
            pending = [event]
            pendingElementBytes = eventBytes
            return
        }

        pending.append(event)
        pendingElementBytes += eventBytes

        // A deliberate divergence from `logging.js:284`, which flushes on *reaching* fifty
        // BEFORE pushing the new item, so the web holds a full batch until a 51st event
        // arrives. Here the fiftieth event flushes immediately. A batch is capped at fifty
        // either way — the only thing the collector sees — but this never holds a full
        // batch, so a crash loses at most 49 events instead of 50. Do not "correct" it back.
        if pending.count >= Self.maxQueueSize {
            flushPending()
        }
    }

    /// Drives the interval flush. An explicit method rather than a `Timer` so tests can
    /// advance time instead of waiting; the GAM layer owns the real timer.
    public func tick() {
        let now = clock()
        guard now - lastFlushTime >= Self.flushInterval else { return }
        flushPending()
        reportUnsampledDrops()
        // Advanced even when nothing was pending, which matches the web's `setInterval`:
        // the window runs from the last tick, not from the oldest pending event. Worst
        // case an event waits one full interval.
        lastFlushTime = now
    }

    /// Sends whatever is pending. The GAM layer calls this from `willResignActive`;
    /// `UIApplication` is deliberately not observed here, so this target still builds for
    /// the macOS host.
    public func flush() {
        flushPending()
        reportUnsampledDrops()
        lastFlushTime = clock()
    }

    private func flushPending() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        pendingElementBytes = 0
        lastFlushTime = clock()
        send(.batch(batch))
    }

    /// The queue's contract ends here.
    ///
    /// It does not retry, does not persist and does not wait for an acknowledgement.
    /// Durability is 2e-4, which wraps the sink and writes the batch to disk before the
    /// POST; two layers each half-owning delivery is how a batch gets sent twice or
    /// dropped silently.
    ///
    /// Sends are chained rather than fired independently so batches reach the sink in the
    /// order they were produced — out-of-order arrival would corrupt any funnel built from
    /// the event stream. The chain is unbounded on purpose: a sink that never completes
    /// accumulates one task per batch. Backpressure belongs with the transport in 2e-4,
    /// not here.
    private func send(_ payload: LNGTDEventPayload) {
        let previous = sendTask
        let sink = self.sink
        sendTask = Task {
            _ = await previous?.value
            await sink.send(payload)
        }
    }

    /// UTF-8 bytes, which is what `JSONEncoder` already hands back as `Data`.
    ///
    /// The web measures `JSON.stringify(data).length` (`logging.js:336`) — UTF-16 code
    /// units — and app payloads carrying device models and localised app names diverge
    /// from that. Bytes is stricter than the web and never looser, so it cannot produce a
    /// payload the collector would reject. `String.count` and `.utf16.count` are both
    /// wrong; the same mistake was found and fixed in the config Lambda's 30KB guard.
    private func encodedSize(of event: LNGTDEvent) -> Int? {
        try? encoder.encode(event).count
    }

    /// Exact encoded size of a JSON array: two brackets plus `count - 1` commas plus the
    /// elements. Exact only for compact output, which
    /// `test18_EncodedArraySizeIsBracketsPlusElementsPlusCommas` pins.
    private static func arrayBytes(count: Int, elementBytes: Int) -> Int {
        count == 0 ? 2 : 2 + elementBytes + (count - 1)
    }

    private func reportUnsampledDrops() {
        guard unsampledDropCount > 0 else { return }
        reporter?.eventQueueDidDrop(.notSampled(count: unsampledDropCount))
        unsampledDropCount = 0
    }

    /// Test seam. Sends are deferred into `sendTask`, so a test that asserts on the sink
    /// straight after `enqueue` or `flush` races the send. Awaiting the tail of the chain
    /// awaits the whole chain, which makes those assertions exact instead of
    /// expectation-and-timeout — the same seam as `ConfigStore.awaitPendingRevalidation()`.
    func awaitPendingSends() async {
        _ = await sendTask?.value
    }

    /// Test seams. The running total is only trustworthy if it equals what an actual encode
    /// of `pending` would produce, and the difference between a correct and an incorrect
    /// total is ~51 bytes out of 200000 — far too small for any threshold test to notice.
    /// These let one test compare the two numbers directly.
    func pendingPayloadBytes() -> Int {
        Self.arrayBytes(count: pending.count, elementBytes: pendingElementBytes)
    }

    func pendingEvents() -> [LNGTDEvent] {
        pending
    }
}
