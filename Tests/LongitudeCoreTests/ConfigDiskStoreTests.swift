import XCTest
@testable import LongitudeCore

final class ConfigDiskStoreTests: XCTestCase {
    private var baseDirectory: URL!
    private var store: ConfigDiskStore!
    private var reporter: MockReporter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = ConfigDiskStore(baseDirectory: baseDirectory)
        reporter = MockReporter()
        store.reporter = reporter
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseDirectory)
        try super.tearDownWithError()
    }

    private func createDummyData(with extraKey: Bool = false) -> Data {
        let jsonStr = """
        {
            "schema": 1,
            "ttl": 3600,
            "platform": "ios",
            "adUnits": {},
            "floors": {}
            \(extraKey ? ",\"futureKey\": \"futureValue\"" : "")
        }
        """
        return Data(jsonStr.utf8)
    }

    func testLoadWhenNothingSavedReturnsNilAndNoFailure() {
        let record = store.read(account: "acc", section: "sec", platform: "ios")
        XCTAssertNil(record)
        XCTAssertNil(reporter.lastReason)
    }

    func testSaveThenLoadRoundTripsPerfectly() throws {
        let payload = createDummyData()
        let record = ConfigRecord(fetchedAt: 1000, etag: "W/123", payload: payload)

        store.write(record: record, account: "acc", section: "sec", platform: "ios")

        let loaded = try XCTUnwrap(store.read(account: "acc", section: "sec", platform: "ios"))
        XCTAssertEqual(loaded.fetchedAt, 1000)
        XCTAssertEqual(loaded.etag, "W/123")
        XCTAssertEqual(loaded.payload, payload)
    }

    func testSavingCreatesDirectory() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseDirectory.path))

        let record = ConfigRecord(fetchedAt: 1000, etag: nil, payload: createDummyData())
        store.write(record: record, account: "acc", section: "sec", platform: "ios")

        XCTAssertTrue(FileManager.default.fileExists(atPath: baseDirectory.path))
    }

    func testSavingWorksWhenDirectoryDeletedBetweenSaves() throws {
        let record = ConfigRecord(fetchedAt: 1000, etag: nil, payload: createDummyData())
        store.write(record: record, account: "acc", section: "sec", platform: "ios")
        XCTAssertTrue(FileManager.default.fileExists(atPath: baseDirectory.path))

        try FileManager.default.removeItem(at: baseDirectory)

        store.write(record: record, account: "acc", section: "sec", platform: "ios")
        XCTAssertTrue(FileManager.default.fileExists(atPath: baseDirectory.path))
    }

    func testScopingPreventsOverwrites() throws {
        let rec1 = ConfigRecord(fetchedAt: 1, etag: "1", payload: createDummyData())
        let rec2 = ConfigRecord(fetchedAt: 2, etag: "2", payload: createDummyData())

        store.write(record: rec1, account: "acc1", section: "sec", platform: "ios")
        store.write(record: rec2, account: "acc2", section: "sec", platform: "ios")

        let load1 = try XCTUnwrap(store.read(account: "acc1", section: "sec", platform: "ios"))
        let load2 = try XCTUnwrap(store.read(account: "acc2", section: "sec", platform: "ios"))

        XCTAssertEqual(load1.etag, "1")
        XCTAssertEqual(load2.etag, "2")

        let rec3 = ConfigRecord(fetchedAt: 3, etag: "3", payload: createDummyData())
        store.write(record: rec3, account: "acc1", section: "sec_b", platform: "ios")

        let load3 = try XCTUnwrap(store.read(account: "acc1", section: "sec_b", platform: "ios"))
        XCTAssertEqual(load3.etag, "3")

        // Original should still be unharmed
        let load1Again = try XCTUnwrap(store.read(account: "acc1", section: "sec", platform: "ios"))
        XCTAssertEqual(load1Again.etag, "1")
    }

    /// The account slug arrives from the publisher's own `Longitude.start` call, so
    /// it is untrusted input on a file path.
    ///
    /// Asserts the property (the file lands inside `baseDirectory`) rather than the
    /// encoding, so this keeps testing traversal even if the filename scheme changes.
    func testAccountSlugCannotEscapeDirectory() throws {
        let evilAccount = "../../evil"
        let record = ConfigRecord(fetchedAt: 1, etag: nil, payload: createDummyData())

        store.write(record: record, account: evilAccount, section: "sec", platform: "ios")

        let url = store.fileURL(account: evilAccount, section: "sec", platform: "ios")
        XCTAssertEqual(
            url.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL,
            baseDirectory.resolvingSymlinksInPath().standardizedFileURL,
            "the record must resolve to a direct child of the base directory"
        )

        // Exactly one file, and it is inside the base directory.
        let files = try FileManager.default.contentsOfDirectory(atPath: baseDirectory.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(files[0].contains(".."), "no traversal component survived")
        XCTAssertFalse(files[0].contains("/"), "no separator survived")

        // And it still round-trips, so sanitising did not make the record unreachable.
        let loaded = store.read(account: evilAccount, section: "sec", platform: "ios")
        XCTAssertEqual(loaded?.fetchedAt, 1)
    }

    /// Components are joined with `_`, so any scheme that leaves a literal `_` inside
    /// a component is not injective: `("x", "y_z")` and `("x_y", "z")` both flatten to
    /// `x_y_z`. One file, two publishers — whichever writes second serves its ad units
    /// to the other. Percent-encoding to alphanumerics is what prevents it, because
    /// `_` becomes `%5F` inside a component and survives only as the delimiter.
    ///
    /// The pair matters: an earlier version of this test used `y_app_z` / `x_app_y`,
    /// which collide only under a filename format carrying a literal `_app_` infix.
    /// Against the current format they are distinct even with a naive scheme, so the
    /// test passed while the vulnerability was reintroduced. Verified by mutation.
    func testUnderscoreInComponentsDoesNotCollide() throws {
        let first = ConfigRecord(fetchedAt: 111, etag: "a", payload: createDummyData())
        let second = ConfigRecord(fetchedAt: 222, etag: "b", payload: createDummyData())

        store.write(record: first, account: "x", section: "y_z", platform: "ios")
        store.write(record: second, account: "x_y", section: "z", platform: "ios")

        XCTAssertEqual(
            store.read(account: "x", section: "y_z", platform: "ios")?.fetchedAt, 111,
            "first record was overwritten by the second"
        )
        XCTAssertEqual(
            store.read(account: "x_y", section: "z", platform: "ios")?.fetchedAt, 222
        )

        let files = try FileManager.default.contentsOfDirectory(atPath: baseDirectory.path)
        XCTAssertEqual(files.count, 2, "the two records must occupy separate files")
    }

    func testCorruptFileReturnsNilReportsAndDeletes() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true, attributes: nil)
        let fileURL = store.fileURL(account: "acc", section: "sec", platform: "ios")
        try "invalid json".write(to: fileURL, atomically: true, encoding: .utf8)

        let loaded = store.read(account: "acc", section: "sec", platform: "ios")

        XCTAssertNil(loaded)
        XCTAssertEqual(reporter.lastReason, .corrupted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testValidJSONButNotRecordDeletesFile() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true, attributes: nil)
        let fileURL = store.fileURL(account: "acc", section: "sec", platform: "ios")
        try "{\"hello\":\"world\"}".write(to: fileURL, atomically: true, encoding: .utf8)

        let loaded = store.read(account: "acc", section: "sec", platform: "ios")

        XCTAssertNil(loaded)
        XCTAssertEqual(reporter.lastReason, .corrupted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testEnvelopeIsGoodButPayloadIsJunkDeletesFile() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true, attributes: nil)
        let fileURL = store.fileURL(account: "acc", section: "sec", platform: "ios")

        let payloadData = Data("not a config".utf8)
        let record = ConfigRecord(fetchedAt: 1, etag: nil, payload: payloadData)
        let data = try JSONEncoder().encode(record)
        try data.write(to: fileURL)

        let loaded = store.read(account: "acc", section: "sec", platform: "ios")
        XCTAssertNil(loaded)
        XCTAssertEqual(reporter.lastReason, .corrupted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testOversizedFileIsRejectedAndDeleted() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true, attributes: nil)
        let fileURL = store.fileURL(account: "acc", section: "sec", platform: "ios")

        // 1.5MB of data
        let largeData = Data(repeating: 0, count: 1_500_000)
        try largeData.write(to: fileURL)

        let loaded = store.read(account: "acc", section: "sec", platform: "ios")

        XCTAssertNil(loaded)
        XCTAssertEqual(reporter.lastReason, .oversized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDirectoryCarriesBackupExclusion() throws {
        let record = ConfigRecord(fetchedAt: 1, etag: nil, payload: createDummyData())
        store.write(record: record, account: "acc", section: "sec", platform: "ios")

        let values = try baseDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertTrue(values.isExcludedFromBackup == true)
    }

    func testForwardCompatibleFieldsSurviveRoundTripSinceDataIsUsed() throws {
        let payloadWithFuture = createDummyData(with: true)
        let record = ConfigRecord(fetchedAt: 1, etag: nil, payload: payloadWithFuture)

        store.write(record: record, account: "acc", section: "sec", platform: "ios")
        let loaded = try XCTUnwrap(store.read(account: "acc", section: "sec", platform: "ios"))

        XCTAssertEqual(loaded.payload, payloadWithFuture)
        let payloadString = try XCTUnwrap(String(data: loaded.payload, encoding: .utf8))
        XCTAssertTrue(payloadString.contains("futureKey"))
    }
}

private class MockReporter: ConfigDiskStoreReporting {
    var lastReason: ConfigDiskStoreError?

    func storeDidFail(reason: ConfigDiskStoreError) {
        lastReason = reason
    }
}
