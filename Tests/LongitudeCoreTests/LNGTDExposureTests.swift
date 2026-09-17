import CoreGraphics
import XCTest
@testable import LongitudeCore

final class LNGTDExposureTests: XCTestCase {

    // 1. A fully on-screen view is 100% exposed.
    func testFullyOnScreenViewIsFullyExposed() {
        let snapshot = LNGTDViewSnapshot(
            frameInWindow: CGRect(x: 10, y: 10, width: 100, height: 100),
            clippingAncestors: [],
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            screenBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            cumulativeAlpha: 1.0,
            isAttachedToWindow: true,
            hasHiddenAncestor: false,
            isAppActive: true
        )
        XCTAssertEqual(snapshot.exposurePercentage, 1.0, accuracy: 0.01, "Should be 100% exposed")
    }

    // 2. A view half outside the window is 50%.
    func testHalfOutsideWindow() {
        let snapshot = LNGTDViewSnapshot(
            frameInWindow: CGRect(x: 0, y: 450, width: 100, height: 100),
            clippingAncestors: [],
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            screenBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            cumulativeAlpha: 1.0,
            isAttachedToWindow: true,
            hasHiddenAncestor: false,
            isAppActive: true
        )
        XCTAssertEqual(snapshot.exposurePercentage, 0.5, accuracy: 0.01, "Should be 50% exposed")
    }

    // 3. A clipping ancestor cropping half the view gives 50%.
    func testClippingAncestorCrops() {
        let snapshot = LNGTDViewSnapshot(
            frameInWindow: CGRect(x: 0, y: 0, width: 100, height: 100),
            clippingAncestors: [
                CGRect(x: 0, y: 0, width: 100, height: 50)
            ],
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            screenBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            cumulativeAlpha: 1.0,
            isAttachedToWindow: true,
            hasHiddenAncestor: false,
            isAppActive: true
        )
        XCTAssertEqual(snapshot.exposurePercentage, 0.5, accuracy: 0.01, "Should be 50% exposed")
    }

    // 4. A non-clipping ancestor smaller than the view does not reduce exposure.
    // (Non-clipping ancestors are not passed into clippingAncestors).
    func testNonClippingAncestorDoesNotReduce() {
        let snapshot = LNGTDViewSnapshot(
            frameInWindow: CGRect(x: 0, y: 0, width: 100, height: 100),
            clippingAncestors: [], // It wouldn't be in the list
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            screenBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            cumulativeAlpha: 1.0,
            isAttachedToWindow: true,
            hasHiddenAncestor: false,
            isAppActive: true
        )
        XCTAssertEqual(snapshot.exposurePercentage, 1.0, accuracy: 0.01, "Should be 100% exposed")
    }

    // 5. Two nested clipping ancestors both apply.
    func testNestedClippingAncestorsBothApply() {
        let snapshot = LNGTDViewSnapshot(
            frameInWindow: CGRect(x: 0, y: 0, width: 100, height: 100),
            clippingAncestors: [
                CGRect(x: 0, y: 0, width: 100, height: 80),
                CGRect(x: 0, y: 0, width: 50, height: 100)
            ], // Intersection is 50x80 = 4000
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            screenBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            cumulativeAlpha: 1.0,
            isAttachedToWindow: true,
            hasHiddenAncestor: false,
            isAppActive: true
        )
        XCTAssertEqual(snapshot.exposurePercentage, 0.4, accuracy: 0.01, "Should be 40% exposed")
    }

    // 6. isAttachedToWindow == false gives 0.
    func testNotAttachedToWindowGivesZero() {
        let snapshot = LNGTDViewSnapshot(
            frameInWindow: CGRect(x: 0, y: 0, width: 100, height: 100),
            clippingAncestors: [],
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            screenBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            cumulativeAlpha: 1.0,
            isAttachedToWindow: false,
            hasHiddenAncestor: false,
            isAppActive: true
        )
        XCTAssertEqual(snapshot.exposurePercentage, 0.0, accuracy: 0.01, "Should be 0% exposed")
    }

    // 7. A hidden ancestor gives 0.
    func testHiddenAncestorGivesZero() {
        let snapshot = LNGTDViewSnapshot(
            frameInWindow: CGRect(x: 0, y: 0, width: 100, height: 100),
            clippingAncestors: [],
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            screenBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            cumulativeAlpha: 1.0,
            isAttachedToWindow: true,
            hasHiddenAncestor: true,
            isAppActive: true
        )
        XCTAssertEqual(snapshot.exposurePercentage, 0.0, accuracy: 0.01, "Should be 0% exposed")
    }

    // 8. Cumulative alpha below 0.5 gives 0; at exactly 0.5 it does not.
    func testCumulativeAlphaRules() {
        let snap1 = LNGTDViewSnapshot(
            frameInWindow: CGRect(x: 0, y: 0, width: 100, height: 100),
            clippingAncestors: [],
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            screenBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            cumulativeAlpha: 0.49,
            isAttachedToWindow: true,
            hasHiddenAncestor: false,
            isAppActive: true
        )
        XCTAssertEqual(snap1.exposurePercentage, 0.0, accuracy: 0.01, "Below 0.5 gives 0")

        let snap2 = LNGTDViewSnapshot(
            frameInWindow: CGRect(x: 0, y: 0, width: 100, height: 100),
            clippingAncestors: [],
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            screenBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            cumulativeAlpha: 0.5,
            isAttachedToWindow: true,
            hasHiddenAncestor: false,
            isAppActive: true
        )
        XCTAssertEqual(snap2.exposurePercentage, 1.0, accuracy: 0.01, "Exactly 0.5 does not give 0")
    }

    // 9. A zero-area view gives 0 and does not crash.
    func testZeroAreaViewGivesZeroAndDoesNotCrash() {
        let snapshot = LNGTDViewSnapshot(
            frameInWindow: .zero,
            clippingAncestors: [],
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            screenBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            cumulativeAlpha: 1.0,
            isAttachedToWindow: true,
            hasHiddenAncestor: false,
            isAppActive: true
        )
        XCTAssertEqual(snapshot.exposurePercentage, 0.0, accuracy: 0.01, "Zero area should not crash and return 0")
    }

    // 10. The screen bounds clip independently of the window bounds.
    func testScreenBoundsClipIndependently() {
        let snapshot = LNGTDViewSnapshot(
            frameInWindow: CGRect(x: 0, y: 0, width: 100, height: 100),
            clippingAncestors: [],
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            screenBounds: CGRect(x: 0, y: 0, width: 50, height: 500),
            cumulativeAlpha: 1.0,
            isAttachedToWindow: true,
            hasHiddenAncestor: false,
            isAppActive: true
        )
        XCTAssertEqual(snapshot.exposurePercentage, 0.5, accuracy: 0.01, "Screen bounds should clip independently")
    }
}
