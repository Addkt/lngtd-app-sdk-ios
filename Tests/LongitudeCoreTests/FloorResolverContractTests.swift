import XCTest
@testable import LongitudeCore

final class FloorResolverContractTests: XCTestCase {

    /// The one fixture case the resolver cannot reproduce by design. See
    /// `testStringReturningCaseIsSkippedDeliberately`.
    private static let skippedCase = "string_floor_value_returned_as_string"

    // MARK: - Fixture plumbing

    private func boolValue(_ value: JSONValue?) -> Bool {
        guard let value = value, case .bool(let flag) = value else { return false }
        return flag
    }

    /// JSON null maps to `.null`, NOT to nil. Returning nil would make the caller
    /// drop the key, converting "present holding null" into "absent" and changing
    /// which ladder tier wins — see `null_at_top_tier_does_not_fall_through`.
    private func floorValue(_ value: JSONValue) -> FloorValue? {
        switch value {
        case .number(let num): return .number(num)
        case .string(let str): return .string(str)
        case .null: return .null
        case .bool, .object, .array: return nil
        }
    }

    private func baseFloorInput(_ value: JSONValue) -> BaseFloorInput {
        switch value {
        case .number(let num): return .value(num)
        case .null: return .missing
        // A non-numeric baseFloor is `parseFloat(x) || 0` on the web, which is a
        // configured 0 rather than an absent floor.
        case .string, .bool, .object, .array: return .invalid
        }
    }

    private func parameters(_ value: JSONValue?) -> DynamicParametersState {
        guard let value = value else { return .missing }
        if value.isUnparseableSentinel { return .unparseable }
        guard let object = value.objectValue else { return .missing }

        var geo: [String: FloorValue]?
        if let geoObject = object["geo_floors"]?.objectValue {
            var parsed: [String: FloorValue] = [:]
            for (key, entry) in geoObject {
                if let floor = floorValue(entry) { parsed[key] = floor }
            }
            geo = parsed
        }

        return .valid(DynamicFloorParameters(
            useStaticFloor: boolValue(object["useStaticFloor"]),
            useHardBaseFloor: boolValue(object["useHardBaseFloor"]),
            geoFloors: geo
        ))
    }

    /// Substitutes the `{DC}` placeholder with the SDK's device-class spelling.
    /// The fixture was generated with the web spelling; see
    /// Tools/FloorContract/README.md for why the two cannot be identical.
    private func floorsMap(_ value: JSONValue?, deviceClass: String) -> FloorsMap {
        guard let value = value else { return .missing }
        if value.isUnparseableSentinel { return .unparseable }
        guard let object = value.objectValue else { return .missing }

        var parsed: [String: FloorValue] = [:]
        for (key, entry) in object {
            let resolvedKey = key.replacingOccurrences(of: "{DC}", with: deviceClass)
            if let floor = floorValue(entry) { parsed[resolvedKey] = floor }
        }
        return .entries(parsed)
    }

    private func request(for testCase: FloorContract.Case) -> FloorRequest {
        let deviceClass = testCase.input.deviceClass.mobile
        return FloorRequest(
            // A distinct auctionId per case, so the memo never masks a result.
            auctionId: testCase.name,
            platform: testCase.input.platform,
            country: testCase.input.country,
            deviceClass: deviceClass,
            section: testCase.input.section,
            sessionDepth: testCase.input.sessionDepth,
            uid: testCase.input.uid,
            baseFloor: baseFloorInput(testCase.input.baseFloor),
            dynamicFloorsEnabled: testCase.input.dynamicFloorsEnabled,
            dynamicFloorParameters: parameters(testCase.input.dynamicFloorParameters),
            floors: floorsMap(testCase.input.floors, deviceClass: deviceClass)
        )
    }

    // MARK: - The contract

    func testWebContract() throws {
        let contract = try FloorContract.load()
        let resolver = FloorResolver()
        var asserted = 0

        for testCase in contract.cases where testCase.name != Self.skippedCase {
            let result = resolver.resolve(request(for: testCase))

            guard let expected = testCase.expected.doubleValue else {
                XCTFail(
                    "Case '\(testCase.name)' has a non-numeric expectation but is "
                    + "not the deliberately skipped case. Either the fixture gained "
                    + "a new string-returning case or the skip list is stale."
                )
                continue
            }

            XCTAssertEqual(
                result, .value(expected),
                "Case '\(testCase.name)': \(testCase.why)"
            )
            asserted += 1
        }

        // A fixture-driven suite that silently iterates zero times is the single
        // most likely way this becomes worthless, so the count is pinned.
        XCTAssertEqual(asserted, 26, "expected exactly 26 asserted cases")
    }

    func testStringReturningCaseIsSkippedDeliberately() throws {
        let contract = try FloorContract.load()
        let skipped = contract.cases.first { $0.name == Self.skippedCase }
        XCTAssertNotNil(skipped, "the skipped case is missing from the fixture")

        throw XCTSkip(
            "The web ladder returns the String \"1.50\" here because its step-3 "
            + "lookup does no type check. A Double-typed resolver cannot reproduce "
            + "that, and schemas/app_config_v1.json constrains floors values to "
            + "numbers, so a published app config cannot contain one. Skipped "
            + "rather than coerced, so the divergence stays visible."
        )
    }

    // MARK: - Focused behaviour

    private func makeRequest(
        auctionId: String,
        sessionDepth: Int = 0,
        uid: String = "unit_1",
        baseFloor: BaseFloorInput = .value(0.1),
        dynamicFloorsEnabled: Bool = true,
        parameters: DynamicParametersState = .missing,
        floors: FloorsMap = .missing
    ) -> FloorRequest {
        FloorRequest(
            auctionId: auctionId,
            platform: "ios",
            country: "US",
            deviceClass: "phone",
            section: "app",
            sessionDepth: sessionDepth,
            uid: uid,
            baseFloor: baseFloor,
            dynamicFloorsEnabled: dynamicFloorsEnabled,
            dynamicFloorParameters: parameters,
            floors: floors
        )
    }

    func testBucketBoundaries() {
        let resolver = FloorResolver()
        let floors = FloorsMap.entries([
            "ios_US_phone_app_A": .number(1.0),
            "ios_US_phone_app_B": .number(2.0),
            "ios_US_phone_app_C": .number(3.0)
        ])

        func floor(atDepth depth: Int) -> ResolvedFloor {
            resolver.resolve(makeRequest(
                auctionId: "bucket_\(depth)", sessionDepth: depth, floors: floors
            ))
        }

        XCTAssertEqual(floor(atDepth: 0), .value(1.0), "depth 0 is bucket A")
        XCTAssertEqual(floor(atDepth: 1), .value(2.0), "depth 1 is bucket B")
        XCTAssertEqual(floor(atDepth: 2), .value(2.0), "depth 2 is still bucket B")
        XCTAssertEqual(floor(atDepth: 3), .value(3.0), "depth 3 is bucket C")
        XCTAssertEqual(floor(atDepth: 10), .value(3.0), "depth > 2 is bucket C")
    }

    func testMemoShortCircuitsWithinOneUnit() {
        let resolver = FloorResolver()
        let first = resolver.resolve(makeRequest(
            auctionId: "auction_1", baseFloor: .value(1.5)
        ))
        XCTAssertEqual(first, .value(1.5))

        // Same auction and unit, completely different inputs: the memo wins.
        let second = resolver.resolve(makeRequest(
            auctionId: "auction_1",
            sessionDepth: 5,
            baseFloor: .value(9.9),
            floors: .entries(["ios_US_phone_app_C": .number(5.0)])
        ))
        XCTAssertEqual(second, .value(1.5), "memo must short-circuit re-resolution")
    }

    /// The memo must be scoped per unit, not per auction.
    ///
    /// On the web `_auctionFloors` is an instance member of a single BaseUnit, so
    /// it is implicitly per-unit. This resolver is shared across slots, so keying
    /// the cache on auctionId alone makes every slot in one auction collide on the
    /// first slot's floor — the 20-slot feed the plan calls out. The delegated
    /// implementation had exactly that bug, and the fixture loop could not catch it
    /// because it uses a distinct auctionId per case.
    func testMemoIsScopedPerUnit() {
        let resolver = FloorResolver()
        let auctionId = "one_auction_many_slots"

        let slotA = resolver.resolve(makeRequest(
            auctionId: auctionId, uid: "slot_a",
            floors: .entries(["ios_US_phone_app_A": .number(1.0)])
        ))
        let slotB = resolver.resolve(makeRequest(
            auctionId: auctionId, uid: "slot_b",
            floors: .entries(["ios_US_phone_app_A": .number(7.5)])
        ))

        XCTAssertEqual(slotA, .value(1.0))
        XCTAssertEqual(
            slotB, .value(7.5),
            "slot_b got slot_a's floor — the memo is keyed without uid"
        )
    }

    /// Presence-not-truthiness, asserted directly as well as via fixtures so the
    /// intent survives a fixture regeneration.
    func testFalsyValueAtTopTierDoesNotFallThrough() {
        for falsy in [FloorValue.number(0), .string(""), .null] {
            let resolver = FloorResolver()
            let result = resolver.resolve(makeRequest(
                auctionId: "falsy",
                baseFloor: .value(0.33),
                floors: .entries([
                    "ios_US_phone_app_A": falsy,
                    "ios_US": .number(1.0),
                    "US": .number(0.5),
                    "default": .number(0.25)
                ])
            ))
            XCTAssertEqual(
                result, .value(0.33),
                "\(falsy) on the most specific key must match and fall back to "
                + "baseFloor, not fall through to the ios_US tier"
            )
        }
    }

    func testMissingFloorIsDistinguishableFromResolvedZero() {
        let resolver = FloorResolver()

        let noFloor = resolver.resolve(makeRequest(
            auctionId: "none", baseFloor: .missing
        ))
        XCTAssertEqual(
            noFloor, .noFloor,
            "no baseFloor and no ladder match must be .noFloor, so the caller can "
            + "omit imp.bidfloor rather than send 0.0"
        )

        let geoZero = resolver.resolve(makeRequest(
            auctionId: "geo_zero",
            baseFloor: .missing,
            dynamicFloorsEnabled: false,
            parameters: .valid(DynamicFloorParameters(geoFloors: ["US": .number(0.0)]))
        ))
        XCTAssertEqual(
            geoZero, .value(0.0),
            "a geo_floors match of 0.0 is a configured floor, not an absent one"
        )

        let explicitZero = resolver.resolve(makeRequest(
            auctionId: "base_zero", baseFloor: .value(0.0)
        ))
        XCTAssertEqual(explicitZero, .value(0.0), "an explicit 0.0 baseFloor is a value")
    }
}
