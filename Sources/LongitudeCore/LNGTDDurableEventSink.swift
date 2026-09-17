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
        store.append(lines: lines)

        switch payload {
        case .single(let event):
            let isTracking = event.details.custom.ifa != nil
            await deliver(body: lines[0], claiming: lines, endpoint: isTracking ? .tracking : .nonTracking)
        case .batch(let events):
            var trackingLines: [Data] = []
            var nonTrackingLines: [Data] = []

            for (index, event) in events.enumerated() {
                if event.details.custom.ifa != nil {
                    trackingLines.append(lines[index])
                } else {
                    nonTrackingLines.append(lines[index])
                }
            }

            if !trackingLines.isEmpty {
                await deliver(body: Self.assemble(trackingLines), claiming: trackingLines, endpoint: .tracking)
            }
            if !nonTrackingLines.isEmpty {
                await deliver(body: Self.assemble(nonTrackingLines), claiming: nonTrackingLines, endpoint: .nonTracking)
            }
        }
    }

    // MARK: - Drain

    /// Accumulates one endpoint's batch. `stopped` is per group on purpose — see `drain()`.
    private struct DrainGroup {
        var lines: [Data] = []
        var elementBytes = 0
        var stopped = false
    }

    public func drain() async {
        let stored = store.readAll()
        guard !stored.isEmpty else { return }

        var groups: [LNGTDEndpoint: DrainGroup] = [.tracking: DrainGroup(), .nonTracking: DrainGroup()]

        for line in stored {
            if Self.payloadBytes(count: 1, elementBytes: line.count) > maxPayloadBytes {
                reporter?.eventQueueDidDrop(.oversized)
                store.remove(records: [line])
                continue
            }

            // From the line's own bytes, never from the current ATT status: a record persisted
            // while authorised drains on a later launch that may have revoked, and vice versa.
            let endpoint: LNGTDEndpoint = Self.hasIfa(in: line) ? .tracking : .nonTracking
            guard var group = groups[endpoint], !group.stopped else { continue }

            let wouldExceed = group.lines.count + 1 > maxBatchSize
                || Self.payloadBytes(
                    count: group.lines.count + 1,
                    elementBytes: group.elementBytes + line.count
                ) > maxPayloadBytes

            if wouldExceed {
                // Stop only THIS endpoint on failure. 2e-4 stopped the whole drain, reasoning
                // that a dead connection dooms every remaining batch — which stopped being true
                // the moment there were two endpoints. `ld.lngtd.com` is blocked outright for an
                // ATT-denied user, so one stale tracking record would otherwise abort the drain
                // before a single non-tracking event went out: exactly what this endpoint exists
                // to deliver.
                if await deliver(
                    body: Self.assemble(group.lines), claiming: group.lines, endpoint: endpoint
                ) {
                    group.lines = [line]
                    group.elementBytes = line.count
                } else {
                    group.stopped = true
                }
            } else {
                group.lines.append(line)
                group.elementBytes += line.count
            }
            groups[endpoint] = group
        }

        for endpoint in [LNGTDEndpoint.tracking, .nonTracking] {
            guard let group = groups[endpoint], !group.stopped, !group.lines.isEmpty else { continue }
            _ = await deliver(
                body: Self.assemble(group.lines), claiming: group.lines, endpoint: endpoint
            )
        }
    }

    // MARK: - Private

    private static func hasIfa(in line: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let details = object["details"] as? [String: Any],
              let customJSON = details["custom"] as? String,
              let custom = (try? JSONSerialization.jsonObject(with: Data(customJSON.utf8))) as? [String: Any] else {
            return false
        }
        return custom["ifa"] != nil
    }

    /// Returns false when the records were left on disk for a later attempt.
    @discardableResult
    private func deliver(body: Data, claiming lines: [Data], endpoint: LNGTDEndpoint) async -> Bool {
        switch await transport.send(payload: body, endpoint: endpoint) {
        case .success, .rejected:
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
