import XCTest
@testable import LongitudeCore

final class AppConfigTests: XCTestCase {

    // MARK: - Helpers

    private enum FixtureError: Error {
        case missing
        case notAnObject
    }

    /// No `subdirectory:` argument. `.copy` on a single file places it at the
    /// bundle root rather than preserving its source directory, so asking for
    /// "Fixtures" finds nothing — verified against the built bundle, which contains
    /// floor-contract.json and lambda_ct_app_response.json flat at the top level.
    private func loadFixture() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "lambda_ct_app_response", withExtension: "json"
        ) else {
            throw FixtureError.missing
        }
        return try Data(contentsOf: url)
    }

    private func decodeModifiedFixture(
        modifications: (inout [String: Any]) -> Void
    ) throws -> AppConfig {
        let data = try loadFixture()
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixtureError.notAnObject
        }
        modifications(&json)
        let modifiedData = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(AppConfig.self, from: modifiedData)
    }

    /// Mutate one ad unit in place. A helper rather than `as!` at each call site:
    /// `.swiftlint.yml` makes force casts an error, and a failed cast here should
    /// leave the fixture untouched so the assertion reports the real problem.
    private func mutateAdUnit(
        _ json: inout [String: Any], _ name: String,
        _ mutate: (inout [String: Any]) -> Void
    ) {
        guard var adUnits = json["adUnits"] as? [String: Any],
              var unit = adUnits[name] as? [String: Any] else { return }
        mutate(&unit)
        adUnits[name] = unit
        json["adUnits"] = adUnits
    }

    private func mutateGeo(
        _ json: inout [String: Any], _ mutate: (inout [String: Any]) -> Void
    ) {
        guard var geo = json["geo"] as? [String: Any] else { return }
        mutate(&geo)
        json["geo"] = geo
    }

    // MARK: - Parsing Tests

    func testFixtureDecodesSuccessfully() throws {
        let data = try loadFixture()
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(config.schema, 1)
        XCTAssertEqual(config.platform, "ios")
        XCTAssertEqual(config.ttl, 1800)
        XCTAssertEqual(config.version, "sn-app-2026.08.06.3")
    }

    func testAdUnitsDecodeCorrectly() throws {
        let data = try loadFixture()
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        let homeTopName = "home_top"
        guard let homeTop = config.adUnits[homeTopName] else {
            XCTFail("Missing 'home_top' ad unit")
            return
        }

        XCTAssertEqual(homeTop.uid, "u_home_top")
        XCTAssertNotEqual(
            homeTopName, homeTop.uid,
            "the slot name and uid are different strings — the slot name is what a "
            + "publisher writes in LNGTDBannerView(slot:), the uid is the reporting "
            + "and floors join key. Conflating them breaks floor lookup silently."
        )

        guard let intMain = config.adUnits["interstitial_main"] else {
            XCTFail("Missing 'interstitial_main' ad unit")
            return
        }
        XCTAssertEqual(intMain.uid, "u_int_main")
    }

    func testFloorsContainCorrectShapes() throws {
        let data = try loadFixture()
        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        guard let homeTopFloors = config.floors["u_home_top"] else {
            XCTFail("Missing floors for 'u_home_top'")
            return
        }

        XCTAssertEqual(homeTopFloors["default"], .number(0.25))

        // Assert the uppercase country and the `app` segment explicitly.
        // This is the shape the FloorResolver generates — the fixture previously carried
        // `ios_us_phone_section_A`, which could never match, and that must not come back.
        XCTAssertEqual(homeTopFloors["ios_US_phone_app_A"], .number(0.65))
        XCTAssertNil(homeTopFloors["ios_us_phone_section_A"], "Stale floor shape must not exist")
    }

    func testUnknownFieldsAreIgnored() throws {
        let config = try decodeModifiedFixture { json in
            json["unknownTopLevelField"] = "should be ignored"
            mutateAdUnit(&json, "home_top") { unit in
                unit["unknownPerAdUnitField"] = 123
            }
        }

        XCTAssertEqual(config.schema, 1)
        XCTAssertNotNil(config.adUnits["home_top"])
    }

    func testNullInNullableFieldsDecodesToNil() throws {
        let config = try decodeModifiedFixture { json in
            json["version"] = NSNull()
            json["_error"] = NSNull()
            mutateAdUnit(&json, "home_top") { unit in
                for key in [
                    "gpid", "prebidConfigId", "baseFloor", "timeoutMs",
                    "refresh", "lazyLoad", "video", "impOrtb"
                ] {
                    unit[key] = NSNull()
                }
            }
            mutateGeo(&json) { geo in
                for key in ["country", "continent", "regionState", "asn"] {
                    geo[key] = NSNull()
                }
            }
        }

        XCTAssertNil(config.version)
        XCTAssertTrue(config.isCacheable)

        let homeTop = try XCTUnwrap(config.adUnits["home_top"])
        XCTAssertNil(homeTop.gpid)
        XCTAssertNil(homeTop.prebidConfigId)
        // baseFloor is BaseFloorInput, not an Optional: a null is `.missing`, which
        // is a distinct instruction from `.invalid` (a configured 0). See
        // AppConfigToleranceTests.
        XCTAssertEqual(homeTop.baseFloor, .missing)
        XCTAssertNil(homeTop.timeoutMs)
        XCTAssertNil(homeTop.refresh)
        XCTAssertNil(homeTop.lazyLoad)
        XCTAssertNil(homeTop.video)
        XCTAssertNil(homeTop.impOrtb)

        let geo = try XCTUnwrap(config.geo)
        XCTAssertNil(geo.country)
        XCTAssertNil(geo.continent)
        XCTAssertNil(geo.regionState)
        XCTAssertNil(geo.asn)
    }

    func testInvalidSchemaFailsWithDistinctReason() throws {
        do {
            _ = try decodeModifiedFixture { json in
                json["schema"] = 2
            }
            XCTFail("Expected decoding to fail")
        } catch let AppConfig.AppConfigError.unsupportedSchema(schema) {
            XCTAssertEqual(schema, 2)
        } catch {
            XCTFail("Expected unsupportedSchema error, got: \(error)")
        }
    }

    func testInvalidPlatformFailsWithDistinctReason() throws {
        do {
            _ = try decodeModifiedFixture { json in
                json["platform"] = "android"
            }
            XCTFail("Expected decoding to fail")
        } catch let AppConfig.AppConfigError.unsupportedPlatform(platform) {
            XCTAssertEqual(platform, "android")
        } catch {
            XCTFail("Expected unsupportedPlatform error, got: \(error)")
        }
    }

    // MARK: - impOrtb Array Detection Tests

    func testImpOrtbArrayDetection() throws {
        let config = try decodeModifiedFixture { json in
            // An array three levels down — the depth the Lambda's recursive strip
            // handles, and the depth a shallow client check would miss.
            mutateAdUnit(&json, "home_top") { unit in
                unit["impOrtb"] = [
                    "level1": ["level2": ["level3": ["theArray": [1, 2, 3]]]]
                ]
            }
            mutateAdUnit(&json, "interstitial_main") { unit in
                unit["impOrtb"] = ["just": "a string", "and": 42]
            }
        }

        let homeTop = try XCTUnwrap(config.adUnits["home_top"])
        XCTAssertEqual(homeTop.impOrtbArrays(), ["level1.level2.level3.theArray"])

        let intMain = try XCTUnwrap(config.adUnits["interstitial_main"])
        XCTAssertTrue(
            intMain.impOrtbArrays().isEmpty,
            "an array-free impOrtb must report no paths"
        )
    }

    // MARK: - Error Flag Tests

    func testErrorFlagPreventsCaching() throws {
        let config = try decodeModifiedFixture { json in
            json["_error"] = true
            json["ttl"] = 0
        }
        XCTAssertFalse(config.isCacheable)

        let freshness = ConfigFreshness.classify(fetchedAt: 0, ttl: 0, isError: true, clock: { 0 })
        XCTAssertNotEqual(freshness, .fresh, "_error: true must never be fresh")
    }

    // MARK: - ConfigFreshness Tests

    private static let fetchedAt: TimeInterval = 10_000
    private static let twentyFourHours: TimeInterval = 86_400

    /// Classification at a given age, with the clock injected so nothing sleeps.
    private func freshness(
        age: TimeInterval, ttl: TimeInterval = 1800, isError: Bool = false
    ) -> ConfigFreshness {
        ConfigFreshness.classify(
            fetchedAt: Self.fetchedAt, ttl: ttl, isError: isError,
            clock: { Self.fetchedAt + age }
        )
    }

    func testFreshnessBoundaries() {
        let ttl: TimeInterval = 1800
        let day = Self.twentyFourHours

        XCTAssertEqual(freshness(age: 0), .fresh)
        XCTAssertEqual(freshness(age: ttl - 1), .fresh, "just inside ttl")
        XCTAssertEqual(freshness(age: ttl), .revalidate, "ttl is exclusive")
        XCTAssertEqual(freshness(age: ttl + 1000), .revalidate, "between ttl and 24h")
        XCTAssertEqual(freshness(age: day), .staleUsable, "24h is inclusive")
        XCTAssertEqual(freshness(age: day * 2), .staleUsable, "well past 24h")

        // Precedence when ttl exceeds 24h: the absolute 24h bound wins, so a
        // 30-hour-old config with a 48-hour ttl is staleUsable, not fresh. The
        // reasoning is that after a day the world may have moved on regardless of
        // what the payload claimed — recorded here because the plan's three bands
        // are ambiguous in this case.
        XCTAssertEqual(
            freshness(age: 30 * 3600, ttl: 48 * 3600), .staleUsable,
            "the 24h bound must override a longer ttl"
        )

        // ttl 0 is the Lambda's own failure path, paired with _error.
        XCTAssertNotEqual(freshness(age: 0, ttl: 0), .fresh, "ttl 0 is never fresh")
        XCTAssertNotEqual(freshness(age: 0, isError: true), .fresh, "_error is never fresh")
    }

    // MARK: - Geo Staleness Tests

    private func geo(
        age: TimeInterval, configCountry: String?, deviceRegion: String?
    ) -> GeoFreshness {
        GeoFreshness.resolve(
            fetchedAt: Self.fetchedAt, configCountry: configCountry,
            deviceRegion: deviceRegion, clock: { Self.fetchedAt + age }
        )
    }

    func testGeoStalenessBoundaries() {
        let hour: TimeInterval = 3600

        let fresh = geo(age: 10, configCountry: "US", deviceRegion: "GB")
        XCTAssertEqual(fresh.country, "US")
        XCTAssertEqual(fresh.source, .config)

        let stale = geo(age: hour + 1, configCountry: "US", deviceRegion: "GB")
        XCTAssertEqual(stale.country, "GB")
        XCTAssertEqual(stale.source, .device)

        // Stale geo with no device region still yields something usable rather than
        // nil-ing out the ladder — a nil country matches no floor key at all.
        let noDevice = geo(age: hour + 1, configCountry: "US", deviceRegion: nil)
        XCTAssertEqual(noDevice.country, "US")
        XCTAssertEqual(noDevice.source, .config)
    }

    /// A lowercase country silently matches no floor key and sends every unit to
    /// baseFloor — the exact failure the fixture's old `ios_us_...` key would have
    /// caused. Locale region identifiers are conventionally uppercase, but a
    /// publisher-supplied or persisted value need not be, so the guarantee has to be
    /// enforced rather than assumed.
    func testResolvedCountryIsAlwaysUppercased() {
        let hour: TimeInterval = 3600

        let fromDevice = geo(age: hour + 1, configCountry: "US", deviceRegion: "gb")
        XCTAssertEqual(fromDevice.country, "GB", "device region must be uppercased")

        let fromConfig = geo(age: 10, configCountry: "us", deviceRegion: nil)
        XCTAssertEqual(fromConfig.country, "US", "config country must be uppercased")
    }
}
