import XCTest
@testable import LongitudeCore

/// Named for what it is, and named uniquely. `FakeTransport` is declared at module scope in
/// `ConfigFetchCoordinatorTests`; marking a second one `private` does not avoid the clash,
/// because the name still occupies the module namespace for redeclaration.
private final class SlotControllerFakeFetcher: LNGTDDemandFetching, @unchecked Sendable {
    var completion: ((LNGTDAuctionOutcome, [String: String]?, Double?) -> Void)?
    var stopped = false
    /// Counted so a test can tell "the auction was superseded and restarted" from "the
    /// superseding auction was silently swallowed by the runner's reentrancy guard".
    var fetchCallCount = 0

    func fetchDemand(completion: @escaping @Sendable (LNGTDAuctionOutcome, [String: String]?, Double?) -> Void) {
        fetchCallCount += 1
        self.completion = completion
    }

    func stopAutoRefresh() {
        stopped = true
    }
}

private final class FakeControllerDelegate: LNGTDSlotControllerDelegate, @unchecked Sendable {
    var floorsResolved: [String] = []
    struct GAMRequest {
        let plan: LongitudeSlotPlan
        let auctionId: String
        let targeting: [String: Any]
    }

    var gamRequests: [GAMRequest] = []
    var passthroughs: [(cause: PassthroughCause, targeting: [String: Any])] = []
    var bidsEmitted: [(auctionId: String, late: Bool)] = []
    var failuresEmitted: [LNGTDSlotFailure] = []

    func resolveFloor(auctionId: String) {
        floorsResolved.append(auctionId)
    }

    func requestGAM(plan: LongitudeSlotPlan, auctionId: String, targeting: [String: Any]) {
        gamRequests.append(GAMRequest(plan: plan, auctionId: auctionId, targeting: targeting))
    }

    func emitBid(auctionId: String, late: Bool) {
        bidsEmitted.append((auctionId, late))
    }

    func emitPassthrough(cause: PassthroughCause, targeting: [String: Any]) {
        passthroughs.append((cause, targeting))
    }

    func emitFailure(_ failure: LNGTDSlotFailure) {
        failuresEmitted.append(failure)
    }
}

final class LNGTDSlotControllerTests: XCTestCase {

    private var delegate: FakeControllerDelegate!
    private var fetcher: SlotControllerFakeFetcher!
    private var schedulerItems: [DispatchWorkItem] = []
    private var runner: LNGTDAuctionRunner!
    private var controller: LNGTDSlotController!

    private var idCounter = 1

    override func setUp() {
        super.setUp()
        delegate = FakeControllerDelegate()
        fetcher = SlotControllerFakeFetcher()
        schedulerItems = []
        idCounter = 1

        let scheduler: @Sendable (TimeInterval, DispatchWorkItem) -> Void = { [weak self] _, item in
            self?.schedulerItems.append(item)
        }

        runner = LNGTDAuctionRunner(fetcher: fetcher, timeout: 0.5, scheduler: scheduler)

        controller = LNGTDSlotController(
            generateAuctionId: { [weak self] in
                guard let self = self else { return "fallback" }
                let id = "id-\(self.idCounter)"
                self.idCounter += 1
                return id
            },
            runner: runner
        )
        controller.delegate = delegate
    }

    override func tearDown() {
        delegate = nil
        fetcher = nil
        schedulerItems = []
        runner = nil
        controller = nil
        super.tearDown()
    }

    private func createPlan() -> LongitudeSlotPlan {
        LongitudeSlotPlan(
            gamPath: "/123/test",
            sizes: nil,
            resolvedFloor: .value(1.5),
            uid: "uid",
            refreshSeconds: nil,
            lazyLoad: false
        )
    }

    func test9_longitudeResolutionRunsAuctionAndProducesTargeting() {
        controller.load(existingTargeting: ["foo": "bar", "hb_stale": "x"])
        XCTAssertEqual(delegate.floorsResolved.count, 1)
        let auctionId = delegate.floorsResolved[0]

        let plan = createPlan()
        controller.provideResolution(.longitude(plan))

        XCTAssertNotNil(fetcher.completion)
        fetcher.completion?(.success, ["hb_bidder": "rubicon"], 1.5)

        XCTAssertEqual(delegate.gamRequests.count, 1)
        let request = delegate.gamRequests[0]
        XCTAssertEqual(request.auctionId, auctionId)
        XCTAssertEqual(request.targeting["foo"] as? String, "bar")
        XCTAssertEqual(request.targeting["hb_bidder"] as? String, "rubicon")
        XCTAssertNil(request.targeting["hb_stale"])
    }

    func test10_passthroughResolutionRunsNoAuctionAndStripsTargeting() {
        controller.load(existingTargeting: ["keep": "yes", "hb_old": "val"])
        XCTAssertEqual(delegate.floorsResolved.count, 1)

        controller.provideResolution(.passthrough(.noConfig))

        XCTAssertNil(fetcher.completion)
        XCTAssertEqual(delegate.passthroughs.count, 1)
        let pt = delegate.passthroughs[0]
        XCTAssertEqual(pt.cause, .noConfig)
        XCTAssertEqual(pt.targeting["keep"] as? String, "yes")
        XCTAssertNil(pt.targeting["hb_old"])
    }

    func test11_auctionTimeoutProducesRequestReadyResultWithNoPrebidKeys() {
        controller.load(existingTargeting: ["hb_stale": "x", "foo": "bar"])
        controller.provideResolution(.longitude(createPlan()))

        XCTAssertEqual(schedulerItems.count, 1)
        schedulerItems[0].perform() // trigger timeout

        XCTAssertEqual(delegate.gamRequests.count, 1)
        let req = delegate.gamRequests[0]
        XCTAssertEqual(req.targeting["foo"] as? String, "bar")
        XCTAssertNil(req.targeting["hb_stale"])
        XCTAssertNil(req.targeting["hb_bidder"]) // no prebid keys
    }

    func test12_exactlyOneAuctionIdUsedForBothFloorResolutionAndAuction() {
        controller.load(existingTargeting: nil)
        XCTAssertEqual(delegate.floorsResolved.count, 1)
        let resolvedId = delegate.floorsResolved[0]

        controller.provideResolution(.longitude(createPlan()))
        fetcher.completion?(.success, ["hb_pb": "1.00"], 1.0)

        XCTAssertEqual(delegate.gamRequests.count, 1)
        XCTAssertEqual(delegate.gamRequests[0].auctionId, resolvedId)

        XCTAssertEqual(delegate.bidsEmitted.count, 1)
        XCTAssertEqual(delegate.bidsEmitted[0].auctionId, resolvedId)
        XCTAssertFalse(delegate.bidsEmitted[0].late)
    }

    func test13_lateAuctionResultIsReportedAndDoesNotAlterTargeting() {
        controller.load(existingTargeting: nil)
        let auctionId = delegate.floorsResolved[0]
        controller.provideResolution(.longitude(createPlan()))

        schedulerItems[0].perform() // timeout

        XCTAssertEqual(delegate.gamRequests.count, 1)
        let req = delegate.gamRequests[0]
        XCTAssertNil(req.targeting["hb_pb"])

        // late result arrives
        fetcher.completion?(.success, ["hb_pb": "2.00"], 2.0)

        // targeting should not be altered (no new GAM requests made)
        XCTAssertEqual(delegate.gamRequests.count, 1)

        // But it is still reported, as late.
        //
        // Exactly one bid, not two: the timeout itself emits none, because nobody bid inside
        // the budget. The late arrival is the first and only bid for this auction — which is
        // the whole point of keeping the late path, since otherwise a bidder that is
        // consistently just past the deadline contributes nothing to reporting at all.
        XCTAssertEqual(delegate.bidsEmitted.count, 1)
        XCTAssertEqual(delegate.bidsEmitted[0].auctionId, auctionId)
        XCTAssertTrue(delegate.bidsEmitted[0].late)
    }

    func test14_secondStartSupersedingInFlightDiscardsOlderTargeting() {
        controller.load(existingTargeting: ["req": "first"])
        controller.provideResolution(.longitude(createPlan()))

        let firstCompletion = fetcher.completion

        // second start
        controller.load(existingTargeting: ["req": "second"])
        XCTAssertEqual(delegate.floorsResolved.count, 2)
        let secondAuctionId = delegate.floorsResolved[1]
        controller.provideResolution(.longitude(createPlan()))

        let secondCompletion = fetcher.completion

        // complete first auction
        firstCompletion?(.success, ["hb_first": "1"], 1.0)

        // it should be ignored by the reducer since state moved on.
        // It might emit a late bid depending on how reducer handles lateAuctionCompleted,
        // wait, actually because it's a completely NEW auction runner, the first auction runner's
        // result will trigger `handlePrimaryResult` which passes `.auctionCompleted` to the reducer,
        // which ignores it because state is `.auctioning(secondAuctionId)`. So NO gamRequest.
        XCTAssertTrue(delegate.gamRequests.isEmpty)

        // complete second auction
        secondCompletion?(.success, ["hb_second": "2"], 2.0)

        XCTAssertEqual(delegate.gamRequests.count, 1)
        let req = delegate.gamRequests[0]
        XCTAssertEqual(req.auctionId, secondAuctionId)
        XCTAssertEqual(req.targeting["req"] as? String, "second")
        XCTAssertEqual(req.targeting["hb_second"] as? String, "2")
        XCTAssertNil(req.targeting["hb_first"])
    }

    func test15_teardownMidAuctionProducesNothing() {
        controller.load(existingTargeting: nil)
        controller.provideResolution(.longitude(createPlan()))

        controller.teardown()

        fetcher.completion?(.success, ["hb_pb": "1.00"], 1.0)

        XCTAssertTrue(delegate.gamRequests.isEmpty)
        XCTAssertTrue(fetcher.stopped)
    }

    // 16. `noBids` is not a failure.
    //
    // The auction ran, the server answered, nobody bid. That is a normal outcome for most
    // impressions. Mapping it to `.auctionFailed` would make the failure rate track fill rate
    // and bury the errors the metric exists to surface — and it would stop the GAM request,
    // serving nothing where the publisher's own demand would have served.
    func test16_noBidsProceedsToGAMAndIsNotAFailure() {
        controller.load(existingTargeting: ["req": "keep"])
        controller.provideResolution(.longitude(createPlan()))

        fetcher.completion?(.noBids, nil, nil)

        XCTAssertEqual(delegate.gamRequests.count, 1, "no bids still requests GAM")
        XCTAssertEqual(delegate.failuresEmitted, [], "no bids is not a failure")
        XCTAssertEqual(
            delegate.bidsEmitted.count, 0,
            "and reports no bid, because there was none — the reducer's .auctionCompleted "
            + "emits one unconditionally, so this is the assertion that catches it"
        )
        let request = delegate.gamRequests[0]
        XCTAssertEqual(request.targeting["req"] as? String, "keep")
        XCTAssertNil(request.targeting["hb_pb"], "and carries no Prebid keys")
    }

    // 17. A superseded auction's completion must not drive the new auction.
    //
    // Asserts the behaviour, not a particular mechanism. Today the runner teardown in
    // `.startAuction` suppresses the stale completion; the controller's auction-id guard is a
    // second line that only becomes reachable when runners stop being shared. Either way the
    // observable rule is the same, which is what this pins.
    func test17_aSupersededAuctionCompletionDoesNotRequestGAM() {
        controller.load(existingTargeting: ["req": "first"])
        controller.provideResolution(.longitude(createPlan()))
        let staleCompletion = fetcher.completion

        controller.load(existingTargeting: ["req": "second"])
        controller.provideResolution(.longitude(createPlan()))

        staleCompletion?(.success, ["hb_stale": "1"], 1.0)

        XCTAssertTrue(
            delegate.gamRequests.isEmpty,
            "the superseded auction must not produce a request for the auction that replaced it"
        )
    }

    // 18. A superseding load actually starts its auction.
    //
    // The runner refuses a second `start` while one is in flight, because Prebid's
    // baseFetchDemand has no reentrancy guard. Without tearing the old run down first, a
    // superseding load resolved its floor, moved to `.auctioning`, and then silently never
    // fetched — the slot wedged until the view went away.
    func test18_aSupersedingLoadStartsANewAuction() {
        controller.load(existingTargeting: nil)
        controller.provideResolution(.longitude(createPlan()))
        let fetchesAfterFirst = fetcher.fetchCallCount

        controller.load(existingTargeting: nil)
        controller.provideResolution(.longitude(createPlan()))

        XCTAssertEqual(
            fetcher.fetchCallCount, fetchesAfterFirst + 1,
            "the superseding auction has to actually run, not be swallowed by the guard"
        )
    }
}
