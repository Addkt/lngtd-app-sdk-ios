import XCTest
@testable import LongitudeCore

/// Tests the fixture harness itself, before any resolver exists.
///
/// Resource bundling is the classic SwiftPM trap — a missing `resources:` entry
/// gives a nil `Bundle.module.url`, and a fixture-driven test suite that silently
/// finds zero cases passes while asserting nothing. These tests exist so that
/// failure mode cannot happen quietly.
final class FloorContractFixtureTests: XCTestCase {
    func testFixtureLoadsFromTestBundle() throws {
        let contract = try FloorContract.load()
        XCTAssertFalse(contract.cases.isEmpty, "fixture decoded but contains no cases")
    }

    func testFixtureHasTheExpectedCaseCount() throws {
        let contract = try FloorContract.load()
        // Pinned so that a truncated or partially regenerated fixture is a test
        // failure rather than a quietly smaller suite.
        XCTAssertEqual(contract.cases.count, 27)
    }

    func testCaseNamesAreUnique() throws {
        let names = try FloorContract.load().cases.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "duplicate case names")
    }

    func testEveryLadderTierIsRepresented() throws {
        let tiers = Set(try FloorContract.load().cases.map(\.ladderTier))
        for expected in [
            "full", "platform_country", "country", "default",
            "baseFloor", "gated", "geo_floors", "hard_base",
        ] {
            XCTAssertTrue(tiers.contains(expected), "no case covers tier \(expected)")
        }
    }

    func testProvenanceIsRecorded() throws {
        let source = try FloorContract.load().source
        XCTAssertEqual(source.function, "BaseUnit.prototype.getFloorForEnv")
        // 64 hex chars. If this is empty the generator did not hash the source,
        // which means drift detection is not actually wired up.
        XCTAssertEqual(source.fileSha256.count, 64)
        XCTAssertEqual(source.functionBodySha256.count, 64)
    }

    /// The single case where the web ladder returns a String rather than a
    /// number. app_config_v1.json constrains floors values to numbers so this
    /// cannot reach a published app config, but the fixture records the web truth
    /// and the resolver suite must skip it by name rather than coerce.
    func testStringReturningCaseIsPresentAndLabelled() throws {
        let contract = try FloorContract.load()
        let nonNumeric = contract.cases.filter { $0.expectedJSType != "number" }
        XCTAssertEqual(nonNumeric.count, 1)
        XCTAssertEqual(nonNumeric.first?.name, "string_floor_value_returned_as_string")
        XCTAssertEqual(nonNumeric.first?.expected.stringValue, "1.50")
    }

    /// The deviceClass spellings must differ between runtimes, because base.js
    /// hardcodes mobile/desktop while the SDK must emit phone/tablet. If these
    /// ever match, the contract has been flattened and the {DC} substitution is
    /// no longer testing anything.
    func testDeviceClassSpellingsDifferPerRuntime() throws {
        for c in try FloorContract.load().cases {
            XCTAssertNotEqual(
                c.input.deviceClass.web, c.input.deviceClass.mobile,
                "case \(c.name) has identical web/mobile deviceClass spellings"
            )
        }
    }
}
