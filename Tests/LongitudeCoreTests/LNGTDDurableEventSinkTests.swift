import XCTest
@testable import LongitudeCore

/// Named `FakeEventTransport`, not `FakeTransport`.
///
/// A Swift test target is one module, and `ConfigFetchCoordinatorTests` already declares a
/// module-scope `FakeTransport`. The collision put forty compile errors into that file while
/// `git diff` showed it untouched.
final class FakeEventTransport: LNGTDEventTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPayloads: [Data] = []
    private var storedResults: [LNGTDEventTransportResult] = []
    private var defaultResult: LNGTDEventTransportResult = .success

    /// Runs inside `send`, before the result is returned — the only way to observe state
    /// *during* a send rather than after it.
    var duringSend: (@Sendable (Data) -> Void)?

    init(results: [LNGTDEventTransportResult] = [], default defaultResult: LNGTDEventTransportResult = .success) {
        self.storedResults = results
        self.defaultResult = defaultResult
    }

    var payloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storedPayloads
    }

    func setDefault(_ result: LNGTDEventTransportResult) {
        lock.lock()
        defaultResult = result
        lock.unlock()
    }

    func forget() {
        lock.lock()
        storedPayloads = []
        lock.unlock()
    }

    func send(payload: Data, endpoint: LNGTDEndpoint) async -> LNGTDEventTransportResult {
        lock.lock()
        storedPayloads.append(payload)
        let result = storedResults.isEmpty ? defaultResult : storedResults.removeFirst()
        let hook = duringSend
        lock.unlock()

        hook?(payload)
        return result
    }
}

final class FakeStoreReporter: LNGTDEventStoreReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailures: [LNGTDEventStoreError] = []
    private var storedSkipped = 0
    private var storedTrimmed = 0
    private var storedRefusals = 0

    var failures: [LNGTDEventStoreError] { withLock { storedFailures } }
    var skippedLines: Int { withLock { storedSkipped } }
    var trimmedRecords: Int { withLock { storedTrimmed } }
    var refusedAppends: Int { withLock { storedRefusals } }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func storeDidFail(reason: LNGTDEventStoreError) {
        withLock { storedFailures.append(reason) }
    }

    func storeDidSkipUnparseableLines(count: Int) {
        withLock { storedSkipped += count }
    }

    func storeDidTrimOldest(count: Int) {
        withLock { storedTrimmed += count }
    }

    func storeDidRefuseOversizedAppend() {
        withLock { storedRefusals += 1 }
    }
}

private enum FixtureError: Error {
    case notAJSONArray
    case notAJSONObject
    case noTimestamp
}

final class LNGTDDurableEventSinkTests: XCTestCase {
    private var tempDir = FileManager.default.temporaryDirectory
    private var store = LNGTDEventStore(baseDirectory: FileManager.default.temporaryDirectory)
    private var transport = FakeEventTransport()
    private var reporter = FakeStoreReporter()
    private var sink = LNGTDDurableEventSink(
        store: LNGTDEventStore(baseDirectory: FileManager.default.temporaryDirectory),
        transport: FakeEventTransport()
    )

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lngtd-events-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        reporter = FakeStoreReporter()
        store = LNGTDEventStore(baseDirectory: tempDir, reporter: reporter)
        transport = FakeEventTransport()
        sink = LNGTDDurableEventSink(store: store, transport: transport)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Fixtures

    /// `clock` is a closure, not a constant, so a test can advance time between creating an
    /// event and draining it.
    private func makeEvent(
        millis: Int64 = 1_000,
        appBundle: String = "com.example.app",
        name: LNGTDEventName = .appForeground
    ) -> LNGTDEvent {
        LNGTDEvent(
            event: name,
            clock: { TimeInterval(millis) / 1000.0 },
            details: LNGTDEvent.Details(
                deviceType: .phone,
                custom: LNGTDEventCustomDetails(platform: .ios, appBundle: appBundle)
            )
        )
    }

    private func objects(in payload: Data) throws -> [[String: Any]] {
        guard let array = try JSONSerialization.jsonObject(with: payload) as? [[String: Any]] else {
            throw FixtureError.notAJSONArray
        }
        return array
    }

    private func timestamps(in payload: Data) throws -> [Int64] {
        try objects(in: payload).map { object in
            guard let number = object["timestamp"] as? NSNumber else {
                throw FixtureError.noTimestamp
            }
            return number.int64Value
        }
    }

    // MARK: - Cases

    // 12.
    func test12_EventsReachDiskBeforeTheTransportIsInvoked() async {
        let storeUnderTest = store
        var observedDuringSend = -1
        let observed = NSLock()

        transport.duringSend = { _ in
            observed.lock()
            observedDuringSend = storeUnderTest.readAll().count
            observed.unlock()
        }

        await sink.send(.single(makeEvent()))

        XCTAssertEqual(
            observedDuringSend, 1,
            "the write has to have already happened; -1 means the hook never ran"
        )
    }

    // 13.
    func test13_ADeliveredResponseRemovesTheRecords() async {
        transport.setDefault(.success)

        await sink.send(.single(makeEvent()))

        XCTAssertEqual(store.readAll().count, 0)
    }

    // 14.
    func test14_A4xxAlsoRemovesTheRecords() async {
        transport.setDefault(.rejected)

        await sink.send(.single(makeEvent()))
        transport.forget()
        await sink.drain()

        XCTAssertEqual(store.readAll().count, 0)
        XCTAssertEqual(
            transport.payloads.count, 0,
            "retaining a 4xx would re-POST a permanently rejected payload on every launch"
        )
    }

    // 15.
    func test15_ATransportFailureRetainsTheRecords() async {
        transport.setDefault(.failed)
        await sink.send(.single(makeEvent()))

        XCTAssertEqual(store.readAll().count, 1)

        transport.setDefault(.success)
        transport.forget()
        await sink.drain()

        XCTAssertEqual(transport.payloads.count, 1, "the retained record is re-sent")
        XCTAssertEqual(store.readAll().count, 0)
    }

    // 16.
    func test16_DrainRebuildsAPayloadFromStoredLines() async throws {
        transport.setDefault(.failed)
        await sink.send(.single(makeEvent(millis: 1_000)))
        await sink.send(.single(makeEvent(millis: 2_000)))

        transport.setDefault(.success)
        transport.forget()
        await sink.drain()

        XCTAssertEqual(transport.payloads.count, 1, "both stored events go in one payload")
        XCTAssertEqual(try timestamps(in: transport.payloads[0]), [1_000, 2_000])
    }

    // 17.
    func test17_DrainedEventsKeepTheirOriginalTimestamps() async throws {
        // A clock that moves. A constant clock produces the same number whether the timestamp
        // survives or is re-stamped on the way out, so it cannot fail this test — the exact
        // trap that made the 2e-2 timestamp test vacuous.
        var now: Int64 = 1_000
        let event = LNGTDEvent(
            event: .impression,
            clock: { TimeInterval(now) / 1000.0 },
            details: LNGTDEvent.Details(
                deviceType: .phone,
                custom: LNGTDEventCustomDetails(platform: .ios)
            )
        )

        transport.setDefault(.failed)
        await sink.send(.single(event))

        // The app is killed overnight and relaunches twelve hours later.
        now = 43_201_000

        transport.setDefault(.success)
        transport.forget()
        await sink.drain()

        XCTAssertEqual(
            try timestamps(in: transport.payloads[0]), [1_000],
            "a recovered event must report when it happened, not when it was recovered"
        )
    }

    // 18.
    func test18_ATruncatedFinalLineIsSkippedAndTheRestSurvives() async throws {
        let encoder = JSONEncoder()
        var file = Data()
        for millis in [1_000, 2_000] as [Int64] {
            file.append(try encoder.encode(makeEvent(millis: millis)))
            file.append(UInt8(ascii: "\n"))
        }
        // An append interrupted mid-write: a partial record with no terminating newline.
        file.append(Data("{\"event\":\"impres".utf8))
        try file.write(to: store.storeFileURL)

        await sink.drain()

        XCTAssertEqual(transport.payloads.count, 1)
        XCTAssertEqual(
            try timestamps(in: transport.payloads[0]), [1_000, 2_000],
            "one truncated byte must not cost the complete records before it"
        )
        XCTAssertEqual(reporter.skippedLines, 1)
    }

    // 19.
    func test19_AStringFieldContainingANewlineRoundTrips() async throws {
        transport.setDefault(.failed)
        await sink.send(.single(makeEvent(appBundle: "first\nsecond")))

        transport.setDefault(.success)
        transport.forget()
        await sink.drain()

        // Assert the parsed value, not the presence of an escape sequence: the claim is that
        // the record survived the line-oriented file, not that JSONEncoder escapes newlines.
        let custom = try objects(in: transport.payloads[0])[0]["details"] as? [String: Any]
        let customJSON = custom?["custom"] as? String ?? ""
        guard let parsed = try JSONSerialization.jsonObject(with: Data(customJSON.utf8))
                as? [String: Any] else {
            throw FixtureError.notAJSONObject
        }
        XCTAssertEqual(parsed["app_bundle"] as? String, "first\nsecond")
    }

    // 20.
    func test20_TheAssembledPayloadParsesBackAsAnOrderedArray() async throws {
        transport.setDefault(.failed)
        for millis in [1_000, 2_000, 3_000] as [Int64] {
            await sink.send(.single(makeEvent(millis: millis)))
        }

        transport.setDefault(.success)
        transport.forget()
        await sink.drain()

        XCTAssertEqual(
            try timestamps(in: transport.payloads[0]), [1_000, 2_000, 3_000],
            "hand-assembled brackets and commas must produce a real, ordered JSON array"
        )
    }

    // 21.
    func test21_TheRecordCapTrimsTheOldest() async throws {
        let small = LNGTDEventStore(baseDirectory: tempDir, reporter: reporter, maxRecords: 4)
        let smallSink = LNGTDDurableEventSink(store: small, transport: transport)
        transport.setDefault(.failed)

        for millis in [1_000, 2_000, 3_000, 4_000] as [Int64] {
            await smallSink.send(.single(makeEvent(millis: millis)))
        }
        XCTAssertEqual(small.readAll().count, 4)
        XCTAssertEqual(reporter.trimmedRecords, 0)

        await smallSink.send(.single(makeEvent(millis: 5_000)))

        XCTAssertEqual(small.readAll().count, 4, "the cap holds")
        XCTAssertEqual(reporter.trimmedRecords, 1)

        transport.setDefault(.success)
        transport.forget()
        await smallSink.drain()

        XCTAssertEqual(
            try timestamps(in: transport.payloads[0]), [2_000, 3_000, 4_000, 5_000],
            "the oldest record went, not the newest: a full store must not stop accepting"
        )
    }

    // 22.
    func test22_TheByteCapTrimsTheOldest() async throws {
        let padding = String(repeating: "A", count: 400)

        // Derived from a measured record rather than guessed: room for exactly two, so the
        // third has to trim. A hardcoded byte cap silently stops testing anything the moment
        // a field is added to the envelope.
        let sample = try JSONEncoder().encode(makeEvent(millis: 1_000, appBundle: padding))
        let recordCost = sample.count + 1

        let small = LNGTDEventStore(
            baseDirectory: tempDir, reporter: reporter, maxBytes: recordCost * 2
        )
        let smallSink = LNGTDDurableEventSink(store: small, transport: transport)
        transport.setDefault(.failed)

        for millis in [1_000, 2_000, 3_000] as [Int64] {
            await smallSink.send(.single(makeEvent(millis: millis, appBundle: padding)))
        }

        XCTAssertGreaterThan(
            reporter.trimmedRecords, 0,
            "a cap sized for two records cannot hold three"
        )

        transport.setDefault(.success)
        transport.forget()
        await smallSink.drain()

        let kept = try timestamps(in: transport.payloads[0])
        XCTAssertEqual(kept.last, 3_000, "the newest record is the one that must survive")
        XCTAssertFalse(kept.contains(1_000), "the oldest was trimmed to make room")
    }

    // 23.
    func test23_DrainSplitsStoredEventsIntoBatchesOfFifty() async throws {
        let encoder = JSONEncoder()
        let lines = try (0..<120).map { try encoder.encode(makeEvent(millis: Int64($0))) }
        store.append(lines: lines)

        await sink.drain()

        XCTAssertEqual(transport.payloads.count, 3)
        XCTAssertEqual(
            try transport.payloads.map { try objects(in: $0).count }, [50, 50, 20],
            "a drained payload has to satisfy the same 50-event cap as a live one"
        )
    }

    // 24.
    func test24_ADrainOverlappingALiveSendDeliversEverythingExactlyOnce() async throws {
        // Identity comes from `appBundle`, a string carried through unchanged — NOT from the
        // timestamp. `LNGTDEvent` computes its timestamp as `Int64(clock() * 1000)`, so
        // feeding it 1001ms as 1.001s yields 1000: binary floating point collapses adjacent
        // millisecond values, and a duplicate-detection test keyed on them reports collisions
        // that the code under test never caused.
        let encoder = JSONEncoder()
        let stored = try (0..<100).map { try encoder.encode(makeEvent(appBundle: "stored-\($0)")) }
        store.append(lines: stored)

        async let draining: Void = sink.drain()
        async let sending: Void = sink.send(.single(makeEvent(appBundle: "live")))
        _ = await (draining, sending)

        var delivered: [String] = []
        for payload in transport.payloads {
            let objects: [[String: Any]]
            if payload.first == UInt8(ascii: "[") {
                objects = try self.objects(in: payload)
            } else {
                guard let object = try JSONSerialization.jsonObject(with: payload)
                        as? [String: Any] else {
                    throw FixtureError.notAJSONObject
                }
                objects = [object]
            }

            for object in objects {
                guard let details = object["details"] as? [String: Any],
                      let customJSON = details["custom"] as? String,
                      let custom = try JSONSerialization.jsonObject(with: Data(customJSON.utf8))
                        as? [String: Any],
                      let bundle = custom["app_bundle"] as? String else {
                    throw FixtureError.notAJSONObject
                }
                delivered.append(bundle)
            }
        }

        XCTAssertEqual(delivered.count, 101, "100 stored plus 1 live, none lost")
        XCTAssertEqual(Set(delivered).count, 101, "and none delivered twice")
        XCTAssertEqual(store.readAll().count, 0, "everything delivered leaves nothing behind")
    }
}
