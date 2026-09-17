import XCTest
import CoreGraphics
@testable import LongitudeCore

final class LNGTDLazyLoadTests: XCTestCase {

    private func createSnapshot(frame: CGRect, isAttached: Bool = true, hasHidden: Bool = false) -> LNGTDViewSnapshot {
        return LNGTDViewSnapshot(
            frameInWindow: frame,
            clippingAncestors: [],
            windowBounds: CGRect(x: 0, y: 0, width: 320, height: 480),
            screenBounds: CGRect(x: 0, y: 0, width: 320, height: 480),
            cumulativeAlpha: 1.0,
            isAttachedToWindow: isAttached,
            hasHiddenAncestor: hasHidden,
            isAppActive: true
        )
    }

    func test8_slotFullyOnScreenLoads() {
        let snapshot = createSnapshot(frame: CGRect(x: 10, y: 10, width: 300, height: 50))
        XCTAssertTrue(LNGTDLazyLoad.shouldLoad(snapshot: snapshot, marginPoints: 100))
    }

    func test9_slotBeyondMarginDoesNotLoad() {
        // Window is 0..480. Expanded by 100 is -100..580.
        // Frame at y = 600 is entirely beyond the margin.
        let snapshot = createSnapshot(frame: CGRect(x: 0, y: 600, width: 320, height: 50))
        XCTAssertFalse(LNGTDLazyLoad.shouldLoad(snapshot: snapshot, marginPoints: 100))
    }

    func test10_slotExactlyAtMarginLoads() {
        // The boundary is inclusive.
        // Window 480 height. Margin 100 -> expanded height goes to 580.
        // Frame starts at exactly 580. It should touch the boundary and load.
        let snapshot = createSnapshot(frame: CGRect(x: 0, y: 580, width: 320, height: 50))
        XCTAssertTrue(
            LNGTDLazyLoad.shouldLoad(snapshot: snapshot, marginPoints: 100),
            "Boundary is inclusive; a slot exactly at the margin should load."
        )

        let justBeyond = createSnapshot(frame: CGRect(x: 0, y: 581, width: 320, height: 50))
        XCTAssertFalse(
            LNGTDLazyLoad.shouldLoad(snapshot: justBeyond, marginPoints: 100),
            "A slot 1 point beyond the margin should not load."
        )
    }

    func test11_slotNotAttachedToWindowDoesNotLoad() {
        let snapshot = createSnapshot(frame: CGRect(x: 10, y: 10, width: 300, height: 50), isAttached: false)
        XCTAssertFalse(LNGTDLazyLoad.shouldLoad(snapshot: snapshot, marginPoints: 100))
    }

    func test12_zeroAreaSlotDoesNotLoad() {
        let snapshot = createSnapshot(frame: CGRect(x: 10, y: 10, width: 0, height: 0))
        XCTAssertFalse(LNGTDLazyLoad.shouldLoad(snapshot: snapshot, marginPoints: 100))
    }

    func test13_marginIsInPoints() {
        // A slot 100 points below the viewport with a 200-point margin loads,
        // and with a 50-point margin does not.
        let frame = CGRect(x: 0, y: 580, width: 320, height: 50) // 100 points below the 480 bottom
        let snapshot = createSnapshot(frame: frame)

        XCTAssertTrue(
            LNGTDLazyLoad.shouldLoad(snapshot: snapshot, marginPoints: 200),
            "Loads because 100 <= 200 points."
        )

        XCTAssertFalse(
            LNGTDLazyLoad.shouldLoad(snapshot: snapshot, marginPoints: 50),
            "Does not load because 100 > 50 points."
        )
    }
}
