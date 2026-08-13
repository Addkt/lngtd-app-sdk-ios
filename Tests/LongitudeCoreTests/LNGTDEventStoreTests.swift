import XCTest
@testable import LongitudeCore

/// Store-level properties the sink tests cannot reach.
///
/// Three of these exist because mutation testing showed the sink tests passing while the
/// property was broken: a corrupt line mid-file, `remove` matching by position rather than by
/// bytes, and the oversized-append refusal. The sink tests only ever append at the end, so
/// "remove the first N" and "remove exactly these" coincide there by accident.
final class LNGTDEventStoreTests: XCTestCase {
    private var tempDir = FileManager.default.temporaryDirectory
    private var reporter = FakeStoreReporter()
    private var store = LNGTDEventStore(baseDirectory: FileManager.default.temporaryDirectory)

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lngtd-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        reporter = FakeStoreReporter()
        store = LNGTDEventStore(baseDirectory: tempDir, reporter: reporter)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Minimal well-formed records. These do not need to be real events — the store stores
    /// opaque JSON objects and never decodes them into `LNGTDEvent`, which is the whole point
    /// of the byte-oriented design.
    private func record(_ id: String) -> Data {
        Data("{\"id\":\"\(id)\"}".utf8)
    }

    private func ids(_ lines: [Data]) -> [String] {
        lines.compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                return nil
            }
            return object["id"] as? String
        }
    }

    // 25.
    func test25_ACorruptLineInTheMiddleDoesNotHideTheLinesAfterIt() throws {
        var file = Data()
        for piece in [record("a"), Data("{not json".utf8), record("b"), record("c")] {
            file.append(piece)
            file.append(UInt8(ascii: "\n"))
        }
        try file.write(to: store.storeFileURL)

        XCTAssertEqual(
            ids(store.readAll()), ["a", "b", "c"],
            "a bad line must cost one record, not every record after it"
        )
        XCTAssertEqual(reporter.skippedLines, 1)
    }

    // 26.
    func test26_RemoveTakesTheNamedRecordsNotTheFirstOnes() {
        store.append(lines: [record("a"), record("b"), record("c")])

        store.remove(records: [record("b")])

        XCTAssertEqual(
            ids(store.readAll()), ["a", "c"],
            "matching by position instead of by bytes would have removed \"a\" — which is how "
            + "a concurrent append gets a record deleted before it was ever sent"
        )
    }

    // 27.
    func test27_RemoveIsAMultisetOperation() {
        // Two identical events encode to identical bytes, so removing one has to leave the
        // other. Removing "every line equal to this one" would silently drop a real event.
        store.append(lines: [record("dup"), record("dup"), record("other")])

        store.remove(records: [record("dup")])

        XCTAssertEqual(ids(store.readAll()), ["dup", "other"])
    }

    // 28.
    func test28_AnAppendLargerThanTheWholeCapIsRefusedRatherThanTrimmed() {
        let small = LNGTDEventStore(baseDirectory: tempDir, reporter: reporter, maxRecords: 2)
        small.append(lines: [record("keep-a"), record("keep-b")])

        small.append(lines: [record("x"), record("y"), record("z")])

        XCTAssertEqual(
            ids(small.readAll()), ["keep-a", "keep-b"],
            "trimming to fit an append that can never fit would discard good records and "
            + "still fail, leaving the store empty for nothing"
        )
        XCTAssertEqual(reporter.refusedAppends, 1)
        XCTAssertEqual(reporter.trimmedRecords, 0)
    }

    // 29.
    func test29_AppendingAfterATruncatedFinalLineKeepsTheGoodRecords() throws {
        // A real append cannot rewrite the file, so a record interrupted mid-write stays as a
        // partial final line and the next append lands after it. The reader has to tolerate a
        // corrupt line in the middle for that to be survivable — which is why case 25 matters
        // and why a whole-file atomic rewrite would make both cases unreachable.
        var file = Data()
        file.append(record("first"))
        file.append(UInt8(ascii: "\n"))
        file.append(Data("{\"id\":\"trunc".utf8))
        try file.write(to: store.storeFileURL)

        store.append(lines: [record("second")])

        XCTAssertEqual(ids(store.readAll()), ["first", "second"])
    }
}
