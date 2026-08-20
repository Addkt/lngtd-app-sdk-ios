import XCTest
@testable import LongitudeCore

final class LNGTDEventTests: XCTestCase {

    /// One representative event, encoded. Shared so the assertions below can each make a
    /// single claim — the original single 72-line test asserted eight unrelated
    /// properties, so a failure told you the encoding was wrong without saying which part.
    private func encodedPageview() throws -> (top: [String: Any], details: [String: Any]) {
        let event = LNGTDEvent(
            event: .pageview,
            clock: { 1000 },  // 1000s -> 1_000_000 ms
            details: LNGTDEvent.Details(
                page: "Home",
                browser: .ios,
                deviceType: .phone,
                sessionDepth: 2,
                // platform has no default, so an event without one cannot be built.
                custom: LNGTDEventCustomDetails(platform: .ios, sessionId: "test-session-id")
            )
        )

        let data = try JSONEncoder().encode(event)
        guard let top = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let details = top["details"] as? [String: Any] else {
            throw XCTSkip("encoded event was not a JSON object with a details object")
        }
        return (top, details)
    }

    /// Parses a field that must be a JSON-encoded *string*, not an object.
    private func parseNestedJSONString(
        _ details: [String: Any], _ key: String
    ) throws -> [String: Any] {
        guard let value = details[key] else {
            throw XCTSkip("\(key) is missing")
        }
        guard let string = value as? String else {
            XCTFail("\(key) must be a JSON-encoded string, not \(type(of: value))")
            throw XCTSkip("\(key) was not a string")
        }
        guard let parsed = try JSONSerialization.jsonObject(with: Data(string.utf8))
                as? [String: Any] else {
            throw XCTSkip("\(key) did not contain a JSON object")
        }
        return parsed
    }

    func testTopLevelShape() throws {
        let (top, _) = try encodedPageview()
        XCTAssertEqual(Set(top.keys), ["event", "timestamp", "details"])
        XCTAssertEqual(top["event"] as? String, "pageview", "an app screen load is a pageview")

        guard let timestamp = top["timestamp"] as? NSNumber else {
            return XCTFail("timestamp must encode as a JSON number, not a string")
        }
        XCTAssertEqual(
            timestamp.int64Value, 1_000_000,
            "milliseconds since epoch; seconds would be a silent 1000x error"
        )
    }

    func testDetailsIsFlatAndUsesWireNames() throws {
        let (_, details) = try encodedPageview()

        XCTAssertEqual(details["page"] as? String, "Home")
        XCTAssertEqual(details["browser"] as? String, "ios", "lowercase literal")
        XCTAssertEqual(details["device_type"] as? String, "phone")

        // session_depth is a top-level details field; session_id lives in custom. Swapping
        // them is the natural instinct and would be wrong.
        XCTAssertEqual(details["session_depth"] as? Int, 2)
        XCTAssertNil(details["session_id"], "session_id belongs in custom, not details")

        // Flat: the only nested values are the two JSON-encoded strings.
        let nestedObjects = details.filter { $0.value is [String: Any] }
        XCTAssertTrue(
            nestedObjects.isEmpty,
            "details must be flat; found nested object(s): \(nestedObjects.keys.sorted())"
        )
    }

    func testCustomIsAnEncodedStringCarryingPlatform() throws {
        let (_, details) = try encodedPageview()
        let custom = try parseNestedJSONString(details, "custom")

        XCTAssertEqual(
            custom["platform"] as? String, "ios",
            "without platform the warehouse labels every app event as web"
        )
        XCTAssertEqual(custom["session_id"] as? String, "test-session-id")
    }

    func testExtraIsAnEncodedStringAndEmptyByChoice() throws {
        let (_, details) = try encodedPageview()
        let extra = try parseNestedJSONString(details, "extra")
        XCTAssertTrue(
            extra.isEmpty,
            "extra is sent empty on purpose: it is read with a comma-truncating regex"
        )
    }

    /// The reason app fields go in `custom` rather than `extra`.
    ///
    /// `extra` is read downstream with `REGEXP_EXTRACT(extra, "key:([^,]*|$)")`, which
    /// truncates at the first comma. Device models contain commas — `iPhone14,2` is the
    /// real identifier for an iPhone 13 — so the same value in `extra` would arrive as
    /// `iPhone14` and nobody would notice.
    func testCommaInCustomSurvivesRoundTrip() throws {
        let event = LNGTDEvent(
            event: .pageview,
            details: LNGTDEvent.Details(
                deviceType: .phone,
                custom: LNGTDEventCustomDetails(platform: .ios, deviceModel: "iPhone14,2")
            )
        )

        let data = try JSONEncoder().encode(event)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let details = json["details"] as? [String: Any] else {
            return XCTFail("could not decode the encoded event")
        }
        let custom = try parseNestedJSONString(details, "custom")

        XCTAssertEqual(
            custom["device_model"] as? String, "iPhone14,2",
            "the comma must survive; truncation here is the bug extra suffers from"
        )
    }

    /// The timestamp is the moment the event happened, not the moment it was encoded.
    ///
    /// This needs a clock that **advances**. The bundled encoding test uses a constant
    /// clock, which cannot distinguish stamping at init from stamping at encode — both
    /// produce the same number — so it does not actually test this property despite being
    /// labelled for it.
    ///
    /// It matters because 2e-4 drains events from disk on the next launch. An encoder that
    /// restamped would relabel every recovered event as happening at launch, compressing
    /// a night of impressions into one spike at 09:00 and losing the real distribution.
    func testTimestampIsStampedAtCreationNotAtEncoding() throws {
        var now: TimeInterval = 1000
        let advancingClock: () -> TimeInterval = { now }

        let event = LNGTDEvent(
            event: .impression,
            clock: advancingClock,
            details: LNGTDEvent.Details(
                deviceType: .phone,
                custom: LNGTDEventCustomDetails(platform: .ios)
            )
        )

        // An hour passes between the event happening and it being sent.
        now = 4600

        let data = try JSONEncoder().encode(event)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = json["timestamp"] as? NSNumber else {
            return XCTFail("could not read the encoded timestamp")
        }

        XCTAssertEqual(
            timestamp.int64Value, 1_000_000,
            "the event must carry its creation time (1000s), not the encode time (4600s)"
        )
    }

    /// `missing_adapter` is retired: it is a Prebid.js client-adapter concept and this SDK
    /// is server-to-server only, so it could never fire meaningfully.
    ///
    /// `LNGTDEventName` is an open RawRepresentable, so the *type* cannot forbid the
    /// string — which is why the taxonomy is enumerable and this asserts against that
    /// list rather than against constructibility.
    func testRetiredAndMisspelledNamesAreNotKnown() {
        XCTAssertFalse(
            LNGTDEventName(rawValue: "missing_adapter").isKnown,
            "missing_adapter is retired and must not be in the taxonomy"
        )
        XCTAssertFalse(
            LNGTDEventName(rawValue: "page_view").isKnown,
            "a misspelling must not pass as known — it would land in the warehouse as an "
            + "event no report counts"
        )
        XCTAssertTrue(LNGTDEventName.pageview.isKnown)
        XCTAssertTrue(LNGTDEventName.paidEvent.isKnown)

        // The three immediate names must all be in the taxonomy, or the queue in 2e-3
        // would branch on a name the SDK cannot emit.
        for name in [LNGTDEventName.impression, .viewableImpression, .pageview] {
            XCTAssertTrue(name.isKnown, "\(name.rawValue) must be known")
        }
    }

    func testImmediateFlags() {
        // 10. pageview, impression and viewable_impression are flagged immediate; a sample of others are not.
        XCTAssertTrue(LNGTDEventName.pageview.isImmediate)
        XCTAssertTrue(LNGTDEventName.impression.isImmediate)
        XCTAssertTrue(LNGTDEventName.viewableImpression.isImmediate)

        XCTAssertFalse(LNGTDEventName.adClick.isImmediate)
        XCTAssertFalse(LNGTDEventName.appForeground.isImmediate)
        XCTAssertFalse(LNGTDEventName.fullscreenPresent.isImmediate)
    }
}
