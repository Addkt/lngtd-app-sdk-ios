import Foundation

/// The durable half of the event path: the sink `LNGTDEventQueue` hands its batches to.
///
/// 2e-3's queue decides *when* to flush and then forgets the batch — no retry, no
/// persistence, no waiting for an acknowledgement. Everything that makes delivery survive
/// the app being killed lives here.
public actor LNGTDDurableEventSink: LNGTDEventSink {
    private let store: LNGTDEventStore
    private let transport: LNGTDEventTransport
    private let reporter: LNGTDEventQueueReporter?

    /// The same limits as `LNGTDEventQueue`, because a drained payload has to satisfy the
    /// collector exactly as a live one does.
    private let maxBatchSize = 50
    private let maxPayloadBytes = 200_000

    /// One encoder, and it must stay compact: `.prettyPrinted` output contains literal
    /// newlines, which would silently destroy the one-event-per-line file format.
    private let encoder = JSONEncoder()

    public init(
        store: LNGTDEventStore,
        transport: LNGTDEventTransport,
        reporter: LNGTDEventQueueReporter? = nil
    ) {
        self.store = store
        self.transport = transport
        self.reporter = reporter
    }

    // MARK: - LNGTDEventSink

    /// This and `drain()` are **not** mutually exclusive, and do not need to be.
    ///
    /// An actor releases its isolation at every suspension point, so a `drain()` parked on
    /// `await transport.send` lets a `send` run to completion in the middle of it. What makes
    /// that safe is `LNGTDEventStore.remove(records:)` matching by bytes with multiset
    /// semantics: each caller removes exactly the records it claimed, so an append arriving
    /// between a drain's read and its remove is neither swept up nor sent twice. Serialising
    /// the two would only add latency to the live path.
    public func send(_ payload: LNGTDEventPayload) async {
        guard let lines = encode(payload) else { return }

        // 1. Disk first, before the POST — not on failure.
        //
        // The window persistence exists to cover is the app being killed *during* the send,
        // and only a write that already happened covers it. One append per batch on a
        // healthy network is the price; do not "optimise" this to write-only-on-failure.
        store.append(lines: lines)

        let body: Data
        switch payload {
        case .single:
            // Still bare-object shaped on the live path; only a persisted-and-drained
            // immediate event changes shape. See `drain()`.
            body = lines[0]
        case .batch:
            body = Self.assemble(lines)
        }

        // 2. POST. 3. Remove on a delivered outcome. 4. Leave it on a failure.
        await deliver(body: body, claiming: lines)
    }

    // MARK: - Drain

    /// Sends everything on disk. Called at launch, and by 2e-5 on backgrounding.
    ///
    /// A persisted immediate event is, by definition, no longer immediate, so it is re-sent
    /// inside an array with everything else rather than tagging lines to preserve its
    /// bare-object shape. The collector accepts an array either way; the shape change is a
    /// decision, not an accident.
    public func drain() async {
        let stored = store.readAll()
        guard !stored.isEmpty else { return }

        var batch: [Data] = []
        var batchElementBytes = 0

        for line in stored {
            // A line that cannot fit a payload on its own would otherwise be assembled into
            // an over-cap POST — the exact outcome 2e-3's oversized guard rejects. Such a
            // line can only reach disk from an older build, so drop it rather than letting
            // the two layers disagree.
            if Self.payloadBytes(count: 1, elementBytes: line.count) > maxPayloadBytes {
                reporter?.eventQueueDidDrop(.oversized)
                store.remove(records: [line])
                continue
            }

            let wouldExceed = batch.count + 1 > maxBatchSize
                || Self.payloadBytes(
                    count: batch.count + 1,
                    elementBytes: batchElementBytes + line.count
                ) > maxPayloadBytes

            if wouldExceed {
                // Stop at the first failure. If the connection is down, the remaining
                // batches are equally doomed, and firing them costs a metered connection
                // real bytes for a guaranteed rejection. They stay on disk for next time.
                guard await deliver(body: Self.assemble(batch), claiming: batch) else { return }
                batch = [line]
                batchElementBytes = line.count
            } else {
                batch.append(line)
                batchElementBytes += line.count
            }
        }

        if !batch.isEmpty {
            _ = await deliver(body: Self.assemble(batch), claiming: batch)
        }
    }

    // MARK: - Private

    /// Returns false when the records were left on disk for a later attempt.
    @discardableResult
    private func deliver(body: Data, claiming lines: [Data]) async -> Bool {
        switch await transport.send(payload: body) {
        case .success, .rejected:
            // A 4xx is removed as well as a 2xx. It is not a success, but it will be
            // rejected again: retaining it would re-POST a permanently refused payload on
            // every launch while the file grew without bound. 2e-3's oversized guard exists
            // to keep a 413 out of this path, and the two decisions have to agree.
            store.remove(records: lines)
            return true
        case .failed:
            return false
        }
    }

    private func encode(_ payload: LNGTDEventPayload) -> [Data]? {
        do {
            switch payload {
            case .single(let event):
                return [try encoder.encode(event)]
            case .batch(let events):
                let lines = try events.map { try encoder.encode($0) }
                return lines.isEmpty ? nil : lines
            }
        } catch {
            // Unreachable while every field on `LNGTDEvent` is a String, Int or enum, but
            // reported rather than swallowed so it matches the queue's `.unencodable`
            // handling — a silent return here would look identical to a successful send.
            reporter?.eventQueueDidDrop(.unencodable)
            return nil
        }
    }

    /// Two brackets plus `count - 1` commas plus the elements — the same identity
    /// `LNGTDEventQueue.arrayBytes` relies on, pinned by
    /// `test17_EncodedArraySizeIsBracketsPlusElementsPlusCommas`.
    private static func payloadBytes(count: Int, elementBytes: Int) -> Int {
        count == 0 ? 2 : 2 + elementBytes + (count - 1)
    }

    /// Builds the array payload by joining pre-encoded lines. Assembling JSON by hand is
    /// normally a smell; here it is assembling an array from already-encoded elements, which
    /// is exactly what an encoder does — and it is what keeps the stored bytes, and so the
    /// original timestamps, untouched.
    private static func assemble(_ lines: [Data]) -> Data {
        var payload = Data()
        payload.reserveCapacity(payloadBytes(count: lines.count, elementBytes: lines.reduce(0) { $0 + $1.count }))
        payload.append(UInt8(ascii: "["))
        for (index, line) in lines.enumerated() {
            if index > 0 {
                payload.append(UInt8(ascii: ","))
            }
            payload.append(line)
        }
        payload.append(UInt8(ascii: "]"))
        return payload
    }
}
