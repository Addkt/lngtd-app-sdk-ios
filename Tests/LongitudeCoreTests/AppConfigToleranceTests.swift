import XCTest
@testable import LongitudeCore

/// Decoding must be tolerant of junk in individual fields, because a bundled
/// `LNGTDConfig.json` is validated by nothing and one bad value must not cost the
/// whole document.
final class AppConfigToleranceTests: XCTestCase {

    private enum FixtureError: Error {
        case missing
        case unexpectedShape
    }

    private func mutatedFixture(
        _ mutate: (inout [String: Any]) -> Void
    ) throws -> AppConfig {
        guard let url = Bundle.module.url(
            forResource: "lambda_ct_app_response", withExtension: "json"
        ) else { throw FixtureError.missing }

        let data = try Data(contentsOf: url)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError.unexpectedShape
        }
        mutate(&json)
        return try JSONDecoder().decode(
            AppConfig.self, from: try JSONSerialization.data(withJSONObject: json)
        )
    }

    /// Replace one key on the `home_top` ad unit.
    private func withHomeTop(
        key: String, value: Any?
    ) throws -> AppConfig {
        try mutatedFixture { json in
            guard var adUnits = json["adUnits"] as? [String: Any],
                  var homeTop = adUnits["home_top"] as? [String: Any] else { return }
            if let value = value {
                homeTop[key] = value
            } else {
                homeTop.removeValue(forKey: key)
            }
            adUnits["home_top"] = homeTop
            json["adUnits"] = adUnits
        }
    }

    /// The regression this file exists for.
    ///
    /// `baseFloor` was originally decoded as `Double?`, which throws `typeMismatch`
    /// on a hand-authored `"0.25"` — and a throw anywhere discards the ENTIRE
    /// config: every ad unit, every floor. On a cold, offline first launch that is
    /// the difference between serving from bundled config and dropping straight to
    /// passthrough, caused by one character in a file no validator ever sees.
    func testNonNumericBaseFloorDoesNotDiscardTheConfig() throws {
        let config = try withHomeTop(key: "baseFloor", value: "0.25")

        XCTAssertEqual(config.adUnits.count, 2, "the other ad unit must survive")
        XCTAssertEqual(config.adUnits["home_top"]?.baseFloor, .invalid)
        // And the rest of the document is intact.
        XCTAssertEqual(config.floors["u_home_top"]?["default"], .number(0.25))
    }

    /// `.invalid` and `.missing` are different instructions to the auction: the web
    /// does `parseFloat(x) || 0`, so a present-but-junk floor is a configured 0,
    /// while an absent one means send no `imp.bidfloor` at all. PBS enforces a zero
    /// floor as a floor, so collapsing these changes bidding behaviour.
    func testAbsentAndNullBaseFloorAreMissingNotInvalid() throws {
        let absent = try withHomeTop(key: "baseFloor", value: nil)
        XCTAssertEqual(absent.adUnits["home_top"]?.baseFloor, .missing)

        let null = try withHomeTop(key: "baseFloor", value: NSNull())
        XCTAssertEqual(null.adUnits["home_top"]?.baseFloor, .missing)
    }

    func testNumericBaseFloorDecodesToValue() throws {
        let config = try withHomeTop(key: "baseFloor", value: 1.25)
        XCTAssertEqual(config.adUnits["home_top"]?.baseFloor, .value(1.25))

        // Integers in JSON must also land as a value, not fall through to .invalid.
        let integral = try withHomeTop(key: "baseFloor", value: 2)
        XCTAssertEqual(integral.adUnits["home_top"]?.baseFloor, .value(2))
    }

    /// A required field is still required — tolerance is per-field, not blanket.
    /// An ad unit without `uid` or `gamPath` cannot serve, so it must not decode.
    func testMissingRequiredAdUnitFieldsStillFail() throws {
        XCTAssertThrowsError(try withHomeTop(key: "uid", value: nil))
        XCTAssertThrowsError(try withHomeTop(key: "gamPath", value: nil))
    }
}
