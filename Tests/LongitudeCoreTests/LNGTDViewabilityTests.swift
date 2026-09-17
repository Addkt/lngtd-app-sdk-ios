import Foundation
import CoreGraphics
import XCTest
@testable import LongitudeCore

final class MockSnapshotProvider: LNGTDViewSnapshotProvider, @unchecked Sendable {
    var currentSnapshot: LNGTDViewSnapshot?

    func snapshot() -> LNGTDViewSnapshot? {
        return currentSnapshot
    }
}

final class MockTimerFactory: LNGTDEventPipelineTimerFactory, @unchecked Sendable {
    var timer: MockTimer?
    func makeTimer(
        interval: TimeInterval,
        queue: DispatchQueue?,
        handler: @escaping @Sendable () -> Void
    ) -> LNGTDEventPipelineTimer {
        let t = MockTimer(handler: handler)
        timer = t
        return t
    }
}

final class MockTimer: LNGTDEventPipelineTimer, @unchecked Sendable {
    var isSuspended = true
    var handler: () -> Void
    var didCancel = false

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func resume() {
        isSuspended = false
    }

    func suspend() {
        isSuspended = true
    }

    func cancel() {
        didCancel = true
    }

    func fire() {
        guard !isSuspended else { return }
        handler()
    }
}

final class LNGTDViewabilityTests: XCTestCase {
    var firedUnits: [String] = []
    var currentTime: TimeInterval = 0
    var tracker: LNGTDViewabilityTracker!
    var timerFactory: MockTimerFactory!

    override func setUp() {
        super.setUp()
        firedUnits = []
        currentTime = 0
        timerFactory = MockTimerFactory()

        tracker = LNGTDViewabilityTracker(
            timerFactory: timerFactory,
            queue: DispatchQueue(label: "test"),
            clock: { [weak self] in self?.currentTime ?? 0 },
            trackViewableImpression: { [weak self] unit in
                self?.firedUnits.append(unit)
            }
        )
    }

    func makeSnapshot(exposure: Double, isActive: Bool = true) -> LNGTDViewSnapshot {
        // Just manipulate the area calculation directly by passing a frame that computes to exactly the ratio.
        // Or since `exposurePercentage` is computed, we can fake it by setting `frameInWindow` to 100x100
        // and clipping to achieve the desired exposure.
        let width = 100.0
        let height = 100.0 * exposure

        return LNGTDViewSnapshot(
            frameInWindow: CGRect(x: 0, y: 0, width: 100, height: 100),
            clippingAncestors: exposure < 1.0 ? [CGRect(x: 0, y: 0, width: 100, height: height)] : [],
            windowBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            screenBounds: CGRect(x: 0, y: 0, width: 500, height: 500),
            cumulativeAlpha: 1.0,
            isAttachedToWindow: true,
            hasHiddenAncestor: false,
            isAppActive: isActive
        )
    }

    // 11. Exposure at exactly 50% counts as met; 49.9% does not.
    func testExposureThreshold() {
        let provider = MockSnapshotProvider()
        tracker.register(provider: provider, unit: "test_unit")

        provider.currentSnapshot = makeSnapshot(exposure: 0.499)
        timerFactory.timer?.fire()
        XCTAssertEqual(tracker.state(for: provider).dwell, 0.0)

        provider.currentSnapshot = makeSnapshot(exposure: 0.5)
        currentTime = 1.0
        timerFactory.timer?.fire()
        XCTAssertEqual(tracker.state(for: provider).dwell, 0.0) // Just started tracking

        currentTime = 2.0
        timerFactory.timer?.fire()
        XCTAssertEqual(tracker.state(for: provider).dwell, 1.0) // accrued
    }

    // 12. Continuous exposure fires at 1000ms and not at 999ms.
    func testContinuousExposureFiresAt1000ms() {
        let provider = MockSnapshotProvider()
        tracker.register(provider: provider, unit: "test_unit")
        provider.currentSnapshot = makeSnapshot(exposure: 1.0)

        timerFactory.timer?.fire() // Start tracking

        currentTime = 0.999
        timerFactory.timer?.fire()
        XCTAssertEqual(firedUnits.count, 0)

        currentTime = 1.0
        timerFactory.timer?.fire()
        XCTAssertEqual(firedUnits.count, 1)
    }

    // 13. Exposure that drops below 50% and returns restarts the second.
    func testExposureDropsBelowRestarts() {
        let provider = MockSnapshotProvider()
        tracker.register(provider: provider, unit: "test_unit")

        provider.currentSnapshot = makeSnapshot(exposure: 1.0)
        timerFactory.timer?.fire() // Start tracking at 0

        currentTime = 0.6
        timerFactory.timer?.fire()
        XCTAssertEqual(tracker.state(for: provider).dwell, 0.6)

        provider.currentSnapshot = makeSnapshot(exposure: 0.4) // Drops below 50%
        currentTime = 0.7
        timerFactory.timer?.fire()
        XCTAssertEqual(tracker.state(for: provider).dwell, 0.0) // Reset

        provider.currentSnapshot = makeSnapshot(exposure: 1.0) // Returns
        currentTime = 0.8
        timerFactory.timer?.fire() // Restart tracking at 0.8

        currentTime = 1.4 // Total elapsed is 1.4, but contiguous is 0.6
        timerFactory.timer?.fire()
        XCTAssertEqual(firedUnits.count, 0, "Accumulated but not contiguous")

        currentTime = 1.8 // Contiguous reaches 1.0
        timerFactory.timer?.fire()
        XCTAssertEqual(firedUnits.count, 1)
    }

    // 14. viewable_impression fires exactly once for one impression.
    func testFiresExactlyOnce() {
        let provider = MockSnapshotProvider()
        tracker.register(provider: provider, unit: "test_unit")
        provider.currentSnapshot = makeSnapshot(exposure: 1.0)

        timerFactory.timer?.fire()
        currentTime = 1.0
        timerFactory.timer?.fire()
        XCTAssertEqual(firedUnits.count, 1)

        currentTime = 2.0
        timerFactory.timer?.fire()
        XCTAssertEqual(firedUnits.count, 1) // Does not fire again
    }

    // 15. After the latch resets on a new impression, it can fire again.
    func testLatchResets() {
        let provider = MockSnapshotProvider()
        tracker.register(provider: provider, unit: "test_unit")
        provider.currentSnapshot = makeSnapshot(exposure: 1.0)

        timerFactory.timer?.fire()
        currentTime = 1.0
        timerFactory.timer?.fire()
        XCTAssertEqual(firedUnits.count, 1)

        tracker.resetLatch(for: provider) // New impression

        currentTime = 1.5
        timerFactory.timer?.fire() // Start tracking anew

        currentTime = 2.5
        timerFactory.timer?.fire()
        XCTAssertEqual(firedUnits.count, 2)
    }

    // 16. The app becoming inactive stops dwell accruing, and it restarts rather than resumes.
    func testAppInactiveRestartsDwell() {
        let provider = MockSnapshotProvider()
        tracker.register(provider: provider, unit: "test_unit")

        provider.currentSnapshot = makeSnapshot(exposure: 1.0)
        timerFactory.timer?.fire()

        currentTime = 0.8
        timerFactory.timer?.fire() // Dwell is 0.8

        provider.currentSnapshot = makeSnapshot(exposure: 1.0, isActive: false) // App inactive
        currentTime = 0.9
        timerFactory.timer?.fire()
        XCTAssertEqual(tracker.state(for: provider).dwell, 0.0) // Reset

        provider.currentSnapshot = makeSnapshot(exposure: 1.0, isActive: true)
        currentTime = 1.0
        timerFactory.timer?.fire() // Restart tracking

        currentTime = 1.9
        timerFactory.timer?.fire()
        XCTAssertEqual(firedUnits.count, 0) // Did not resume

        currentTime = 2.0
        timerFactory.timer?.fire()
        XCTAssertEqual(firedUnits.count, 1) // Restarted and completed 1s
    }

    // 17. A deallocated view stops being sampled and is dropped from the registry.
    func testDeallocatedProviderIsDroppedAndStopsSampling() throws {
        var provider: MockSnapshotProvider? = MockSnapshotProvider()
        // A real snapshot, so this exercises DEALLOCATION rather than the nil-snapshot path.
        // Those are different: nil means "no sample this tick" and must keep the registration,
        // or one mistimed tick deregisters a live slot for good.
        provider?.currentSnapshot = makeSnapshot(exposure: 1.0)

        tracker.register(provider: try XCTUnwrap(provider), unit: "test_unit")
        let timer = try XCTUnwrap(timerFactory.timer, "registering installs the timer")
        timer.fire()
        XCTAssertFalse(timer.isSuspended, "a live slot keeps the timer running")

        provider = nil
        timer.fire()

        XCTAssertTrue(timer.isSuspended, "the registry emptied, so the timer stands down")
    }

    // 17b. A nil snapshot is a skipped tick, not a deregistration.
    func testANilSnapshotDoesNotDeregisterTheSlot() throws {
        let provider = MockSnapshotProvider()
        tracker.register(provider: provider, unit: "test_unit")
        let timer = try XCTUnwrap(timerFactory.timer)

        provider.currentSnapshot = nil
        timer.fire()
        XCTAssertFalse(
            timer.isSuspended,
            "the observer returns nil off the main thread; that must not drop a live slot"
        )

        // And the slot still works afterwards.
        provider.currentSnapshot = makeSnapshot(exposure: 1.0)
        currentTime = 0
        timer.fire()
        currentTime = 1.0
        timer.fire()
        XCTAssertEqual(firedUnits, ["test_unit"])
    }

    // 18. The timer is suspended when the registry empties and resumed when a slot is added.
    func testTimerSuspendsAndResumes() throws {
        let provider = MockSnapshotProvider()
        tracker.register(provider: provider, unit: "test_unit")
        let timer = try XCTUnwrap(timerFactory.timer)
        XCTAssertFalse(timer.isSuspended)

        tracker.deregister(provider: provider)
        XCTAssertTrue(timer.isSuspended)

        tracker.register(provider: provider, unit: "test_unit")
        XCTAssertFalse(timer.isSuspended)

        // Ensure never released when suspended (deinit logic is handled by timer implementation itself,
        // but we verify our Tracker suspends and resumes).
    }
}
