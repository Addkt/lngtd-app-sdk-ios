import XCTest
@testable import LongitudeCore

final class BundledConfigLoaderTests: XCTestCase {
    private var reporter: MockBundledReporter!
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        reporter = MockBundledReporter()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func createTempBundle(filename: String, contents: String) throws -> Bundle {
        let bundleURL = tempDir.appendingPathComponent("\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true, attributes: nil)

        let fileURL = bundleURL.appendingPathComponent(filename)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)

        guard let bundle = Bundle(url: bundleURL) else {
            throw NSError(domain: "Test", code: 1, userInfo: nil)
        }
        return bundle
    }

    func testLoaderReturnsNilAndNoFailureWhenMissing() {
        // Use a bundle that definitely doesn't have LNGTDConfig.json (the test bundle itself)
        let loader = BundledConfigLoader(bundle: Bundle(for: type(of: self)))
        loader.reporter = reporter

        let result = loader.load()
        XCTAssertNil(result)
        XCTAssertNil(reporter.lastReason)
    }

    func testValidBundledConfigLoadsAndReportsStaleUsable() throws {
        let json = """
        {
            "schema": 1,
            "ttl": 3600,
            "platform": "ios",
            "adUnits": {},
            "floors": {}
        }
        """
        let bundle = try createTempBundle(filename: "LNGTDConfig.json", contents: json)
        let loader = BundledConfigLoader(bundle: bundle)
        loader.reporter = reporter

        let result = try XCTUnwrap(loader.load())
        XCTAssertEqual(result.freshness, .staleUsable)
        XCTAssertEqual(result.config.schema, 1)
        XCTAssertNil(reporter.lastReason)
    }

    func testMalformedBundledConfigReturnsNilReportsAndLeavesFileInPlace() throws {
        let bundle = try createTempBundle(filename: "LNGTDConfig.json", contents: "invalid json")
        let loader = BundledConfigLoader(bundle: bundle)
        loader.reporter = reporter

        let result = loader.load()
        XCTAssertNil(result)
        XCTAssertEqual(reporter.lastReason, .undecodable)

        // Assert file is still there
        let fileURL = bundle.bundleURL.appendingPathComponent("LNGTDConfig.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }
}

private class MockBundledReporter: BundledConfigReporting {
    var lastReason: BundledConfigError?

    func bundledConfigDidFail(reason: BundledConfigError) {
        lastReason = reason
    }
}
