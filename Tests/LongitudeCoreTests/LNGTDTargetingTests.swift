import XCTest
@testable import LongitudeCore

final class LNGTDTargetingTests: XCTestCase {

    func test1_keysFromAuctionAppearInResult() {
        let existing: [String: Any]? = ["foo": "bar"]
        let auction: [String: String]? = ["hb_bidder": "rubicon"]

        let result = LNGTDTargeting.merge(existing: existing, auctionKeys: auction)

        XCTAssertEqual(result["foo"] as? String, "bar")
        XCTAssertEqual(result["hb_bidder"] as? String, "rubicon")
    }

    func test2_existingHbKeyIsRemoved() {
        let existing: [String: Any]? = ["hb_old": "value"]
        let auction: [String: String]? = ["new": "val"]

        let result = LNGTDTargeting.merge(existing: existing, auctionKeys: auction)

        XCTAssertNil(result["hb_old"])
        XCTAssertEqual(result["new"] as? String, "val")
    }

    func test3_existingNonHbKeyIsPreserved() {
        let existing: [String: Any]? = ["custom": "value"]
        let result = LNGTDTargeting.merge(existing: existing, auctionKeys: nil)

        XCTAssertEqual(result["custom"] as? String, "value")
    }

    func test4_inputDictionaryIsNotMutated() {
        var existing: [String: Any]? = ["hb_stale": "value", "keep": "this"]

        let result = LNGTDTargeting.merge(existing: existing, auctionKeys: ["hb_new": "new_val"])

        XCTAssertEqual(result["hb_new"] as? String, "new_val")
        XCTAssertNil(result["hb_stale"])
        XCTAssertEqual(result["keep"] as? String, "this")

        // Assert the original still holds its hb_ key
        XCTAssertEqual(
            existing?["hb_stale"] as? String, "value",
            "the caller's dictionary must come back untouched — a publisher may reuse it"
        )
    }

    func test5_nilInputsGiveEmptyResultNotNil() {
        let result = LNGTDTargeting.merge(existing: nil, auctionKeys: nil)
        XCTAssertTrue(result.isEmpty)
    }

    func test6_nilNewKeysWithExistingHbKeysStillStrips() {
        let existing: [String: Any]? = ["hb_stale": "old_val", "keep": "this"]

        let result = LNGTDTargeting.merge(existing: existing, auctionKeys: nil)

        XCTAssertNil(result["hb_stale"])
        XCTAssertEqual(result["keep"] as? String, "this")
    }

    func test7_newKeyStartingWithHbSurvives() {
        let existing: [String: Any]? = ["hb_old": "old"]
        let auction: [String: String]? = ["hb_new": "new"]

        let result = LNGTDTargeting.merge(existing: existing, auctionKeys: auction)

        XCTAssertNil(result["hb_old"])
        XCTAssertEqual(result["hb_new"] as? String, "new")
    }

    func test8_nonStringExistingValuesSurvive() {
        let existing: [String: Any]? = ["num": 42, "bool": true, "hb_old": "old"]

        let result = LNGTDTargeting.merge(existing: existing, auctionKeys: nil)

        XCTAssertEqual(result["num"] as? Int, 42)
        XCTAssertEqual(result["bool"] as? Bool, true)
        XCTAssertNil(result["hb_old"])
    }
}
