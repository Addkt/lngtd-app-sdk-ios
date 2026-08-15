import XCTest
@testable import LongitudeCore

final class EndpointRoutingFakeTransport: LNGTDEventTransport, @unchecked Sendable {
    struct Capture {
        let data: Data
        let endpoint: LNGTDEndpoint
    }

    private let lock = NSLock()
    private var storedPayloads: [Capture] = []

    /// Per-endpoint results, so one endpoint can be blocked while the other works. That is not
    /// a hypothetical: iOS blocks `ld.lngtd.com` outright for an ATT-denied user while
    /// `notrack.lngtd.com` stays reachable, which is the entire reason the second endpoint
    /// exists. A double that always succeeds cannot express it.
    var resultsByEndpoint: [LNGTDEndpoint: LNGTDEventTransportResult] = [:]

    var payloads: [Capture] {
        lock.lock()
        defer { lock.unlock() }
        return storedPayloads
    }

    func send(payload: Data, endpoint: LNGTDEndpoint) async -> LNGTDEventTransportResult {
        lock.lock()
        storedPayloads.append(Capture(data: payload, endpoint: endpoint))
        let result = resultsByEndpoint[endpoint] ?? .success
        lock.unlock()
        return result
    }
}

final class LNGTDEndpointRoutingTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lngtd-routing-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private enum RoutingFixtureError: Error {
        case noPayloadForEndpoint
    }

    private func payload(
        from transport: EndpointRoutingFakeTransport, at endpoint: LNGTDEndpoint
    ) throws -> Data {
        guard let match = transport.payloads.first(where: { $0.endpoint == endpoint }) else {
            throw RoutingFixtureError.noPayloadForEndpoint
        }
        return match.data
    }

    /// Pulls `device_model` out of one encoded event. `custom` is a JSON-encoded *string*
    /// nested in `details`, per 2e-2.
    private func deviceModel(in event: [String: Any]) throws -> String {
        guard let details = event["details"] as? [String: Any],
              let customJSON = details["custom"] as? String,
              let custom = try JSONSerialization.jsonObject(with: Data(customJSON.utf8))
                as? [String: Any],
              let model = custom["device_model"] as? String else {
            throw RoutingFixtureError.noPayloadForEndpoint
        }
        return model
    }

    private func makeEvent(ifa: String? = nil, ifaType: String? = nil, model: String? = nil) -> LNGTDEvent {
        LNGTDEvent(
            event: .pageview,
            details: LNGTDEvent.Details(
                deviceType: .phone,
                custom: LNGTDEventCustomDetails(
                    platform: .ios,
                    deviceModel: model,
                    ifa: ifa,
                    ifaType: ifaType,
                    attStatus: ifa != nil ? "authorized" : "denied"
                )
            )
        )
    }

    private func objects(in payload: Data) throws -> [[String: Any]] {
        if payload.first == UInt8(ascii: "[") {
            guard let array = try JSONSerialization.jsonObject(with: payload) as? [[String: Any]] else {
                throw URLError(.cannotParseResponse)
            }
            return array
        } else {
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                throw URLError(.cannotParseResponse)
            }
            return [object]
        }
    }

    // 1. A payload carrying an ifa goes to the tracking endpoint.
    func test01_PayloadWithIfaRoutesToTracking() async {
        let transport = EndpointRoutingFakeTransport()
        let sink = LNGTDDurableEventSink(store: LNGTDEventStore(baseDirectory: tempDir), transport: transport)

        await sink.send(.single(makeEvent(ifa: "AABBCCDD-1234-5678-ABCD-0123456789AB")))

        XCTAssertEqual(transport.payloads.count, 1)
        XCTAssertEqual(transport.payloads[0].endpoint, .tracking)
    }

    // 2. A payload with no ifa goes to the non-tracking endpoint.
    func test02_PayloadWithoutIfaRoutesToNonTracking() async {
        let transport = EndpointRoutingFakeTransport()
        let sink = LNGTDDurableEventSink(store: LNGTDEventStore(baseDirectory: tempDir), transport: transport)

        await sink.send(.single(makeEvent(ifa: nil)))

        XCTAssertEqual(transport.payloads.count, 1)
        XCTAssertEqual(transport.payloads[0].endpoint, .nonTracking)
    }

    // 3. A payload whose ifa is absent but which contains the string ifa_type still routes as non-tracking
    func test03_SubstringMatchDoesNotRouteToTracking() async {
        let transport = EndpointRoutingFakeTransport()
        let sink = LNGTDDurableEventSink(store: LNGTDEventStore(baseDirectory: tempDir), transport: transport)

        // This includes "ifa_type" as a string value but not the key `ifa` itself
        await sink.send(.single(makeEvent(ifa: nil, model: "iPhone-with-ifa_type-string")))

        XCTAssertEqual(transport.payloads.count, 1)
        XCTAssertEqual(transport.payloads[0].endpoint, .nonTracking)
    }

    // 4. A mixed batch is split into two payloads, one per endpoint, losing no events.
    func test04_MixedBatchIsSplit() async throws {
        let transport = EndpointRoutingFakeTransport()
        let sink = LNGTDDurableEventSink(store: LNGTDEventStore(baseDirectory: tempDir), transport: transport)

        let batch = [
            makeEvent(ifa: nil),
            makeEvent(ifa: "some-idfa"),
            makeEvent(ifa: nil)
        ]

        await sink.send(.batch(batch))

        XCTAssertEqual(transport.payloads.count, 2)

        let trackingCount = try objects(in: try payload(from: transport, at: .tracking)).count
        let nonTrackingCount = try objects(in: try payload(from: transport, at: .nonTracking)).count

        XCTAssertEqual(trackingCount, 1)
        XCTAssertEqual(nonTrackingCount, 2)
    }

    // 5. Neither resulting payload contains events from the other group.
    func test05_ResultingPayloadsDoNotMixEvents() async throws {
        let transport = EndpointRoutingFakeTransport()
        let sink = LNGTDDurableEventSink(store: LNGTDEventStore(baseDirectory: tempDir), transport: transport)

        await sink.send(.batch([
            makeEvent(ifa: nil, model: "non-tracking-model"),
            makeEvent(ifa: "some-idfa", model: "tracking-model")
        ]))

        let trackingPayload = try payload(from: transport, at: .tracking)
        let nonTrackingPayload = try payload(from: transport, at: .nonTracking)

        let trackingEvents = try objects(in: trackingPayload)
        let nonTrackingEvents = try objects(in: nonTrackingPayload)

        XCTAssertEqual(
            try trackingEvents.map { try deviceModel(in: $0) }, ["tracking-model"],
            "the tracking payload must hold only the tracking event"
        )
        XCTAssertEqual(
            try nonTrackingEvents.map { try deviceModel(in: $0) }, ["non-tracking-model"],
            "and the non-tracking payload only the other"
        )
    }

    // 6. A drain of stored lines routes each line by its own content, not by a single decision for the whole file.
    func test06_DrainRoutesEachLineByContent() async throws {
        let transport = EndpointRoutingFakeTransport()
        let store = LNGTDEventStore(baseDirectory: tempDir)
        let sink = LNGTDDurableEventSink(store: store, transport: transport)

        let encoder = JSONEncoder()
        let line1 = try encoder.encode(makeEvent(ifa: nil, model: "m1"))
        let line2 = try encoder.encode(makeEvent(ifa: "idfa", model: "m2"))
        store.append(lines: [line1, line2])

        await sink.drain()

        XCTAssertEqual(transport.payloads.count, 2)
    }

    // 7. Routing ignores current ATT status entirely: an IDFA-free payload still goes to the non-tracking endpoint even when the status says authorised.
    func test07_RoutingIgnoresATTStatus() async throws {
        let transport = EndpointRoutingFakeTransport()
        let sink = LNGTDDurableEventSink(store: LNGTDEventStore(baseDirectory: tempDir), transport: transport)

        let event = LNGTDEvent(
            event: .pageview,
            details: LNGTDEvent.Details(
                deviceType: .phone,
                custom: LNGTDEventCustomDetails(
                    platform: .ios,
                    ifa: nil,
                    attStatus: "authorized" // ATT status says authorized but no IFA is present
                )
            )
        )

        await sink.send(.single(event))

        XCTAssertEqual(transport.payloads[0].endpoint, .nonTracking)
    }

    // 8. The tracking endpoint's fallback is unchanged from 2e-4, and the non-tracking path behaves as you decided.
    func test08_FallbackBehaviour() async throws {
        let transport = URLSessionEventTransport()
        let mirror = Mirror(reflecting: transport)

        let fallback = mirror.children.first(where: { $0.label == "fallbackURL" })?.value as? URL
        XCTAssertEqual(fallback?.host, "it.lngtd.com")

        // I chose to give the non-tracking path no fallback, and it handles failure gracefully inside send().
        // We verify the nonTrackingURL exists.
        let nonTracking = mirror.children.first(where: { $0.label == "nonTrackingURL" })?.value as? URL
        XCTAssertEqual(nonTracking?.host, "notrack.lngtd.com")
    }

    // 9. Regression: a blocked tracking endpoint must not abandon the non-tracking batch.
    //
    // The delivered drain used one `guard await deliver(...) else { return }` for both groups,
    // inheriting 2e-4's reasoning that a dead connection dooms every remaining batch. With two
    // endpoints that is false: iOS blocks ld.lngtd.com outright for an ATT-denied user while
    // notrack.lngtd.com stays reachable. One stale tracking record on disk would then abort the
    // drain before a single non-tracking event went out — precisely what this endpoint exists
    // to deliver. No existing test caught it.
    func test09_ABlockedTrackingEndpointDoesNotAbandonNonTrackingEvents() async throws {
        let store = LNGTDEventStore(baseDirectory: tempDir)
        let encoder = JSONEncoder()

        // Enough tracking records to force a mid-loop flush (the batch cap is 50), which is the
        // only path the early return was on.
        var lines: [Data] = []
        for index in 0..<60 {
            lines.append(try encoder.encode(makeEvent(ifa: "IDFA-\(index)", ifaType: "idfa")))
        }
        for index in 0..<3 {
            lines.append(try encoder.encode(makeEvent(model: "iPhone14,\(index)")))
        }
        store.append(lines: lines)

        let transport = EndpointRoutingFakeTransport()
        transport.resultsByEndpoint = [.tracking: .failed, .nonTracking: .success]
        let sink = LNGTDDurableEventSink(store: store, transport: transport)

        await sink.drain()

        let nonTracking = transport.payloads.filter { $0.endpoint == .nonTracking }
        guard nonTracking.count == 1 else {
            return XCTFail(
                "the non-tracking batch must still go out when the tracking endpoint is "
                + "blocked; got \(nonTracking.count) payloads"
            )
        }
        XCTAssertEqual(try objects(in: nonTracking[0].data).count, 3)

        // And the tracking records stay on disk for a later attempt rather than being dropped.
        XCTAssertEqual(store.readAll().count, 60)
    }
}
