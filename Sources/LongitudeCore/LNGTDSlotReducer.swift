import Foundation

/// Pure logic reducer for the ad slot state machine.
public struct LNGTDSlotReducer: Sendable {
    private let generateAuctionId: @Sendable () -> String

    public init(generateAuctionId: @escaping @Sendable () -> String) {
        self.generateAuctionId = generateAuctionId
    }

    public func reduce(
        _ state: LNGTDSlotState, _ input: LNGTDSlotInput
    ) -> (state: LNGTDSlotState, effects: [LNGTDSlotEffect]) {
        switch state {
        case .awaitingConfig:
            return reduceAwaitingConfig(input)
        case .resolvingFloor(let auctionId):
            return reduceResolvingFloor(auctionId, input)
        case .auctioning(let plan, let auctionId):
            return reduceAuctioning(plan, auctionId, input)
        case .requestingGAM(let plan, let auctionId):
            return reduceRequestingGAM(plan, auctionId, input)
        case .rendered(let plan, let auctionId):
            return reduceRendered(plan, auctionId, input)
        case .impressed(let plan, let auctionId):
            return reduceImpressed(plan, auctionId, input)
        case .passthrough(let cause):
            return reducePassthrough(cause, input)
        case .failed(let failure):
            return reduceFailed(failure, input)
        case .tornDown:
            return (.tornDown, [])
        }
    }

    private func reduceAwaitingConfig(_ input: LNGTDSlotInput) -> (LNGTDSlotState, [LNGTDSlotEffect]) {
        switch input {
        case .configResolved(.longitude(let plan)):
            let auctionId = generateAuctionId()
            return (
                .auctioning(plan: plan, auctionId: auctionId),
                [.startAuction(plan: plan, auctionId: auctionId, floor: plan.resolvedFloor)]
            )
        case .configResolved(.passthrough(let cause)):
            return (.passthrough(cause), [.emitPassthrough(cause: cause)])
        case .lateAuctionCompleted(let lateAuctionId):
            return (.awaitingConfig, [.emitBid(auctionId: lateAuctionId, late: true)])
        case .teardown:
            return (.tornDown, [])
        // No auction has started, so nothing about one can apply, and there is no creative to
        // impress or refresh. Enumerated rather than defaulted: a `default` here is how a slot
        // silently stalls, and it also makes the exhaustiveness test unable to fail.
        case .auctionCompleted, .auctionTimedOut, .auctionFailed,
             .gamLoaded, .gamFailed, .impressionRecorded, .refreshDue:
            return (.awaitingConfig, [])
        }
    }

    private func reduceResolvingFloor(
        _ auctionId: String, _ input: LNGTDSlotInput
    ) -> (LNGTDSlotState, [LNGTDSlotEffect]) {
        switch input {
        case .configResolved(.longitude(let plan)):
            return (
                .auctioning(plan: plan, auctionId: auctionId),
                [.startAuction(plan: plan, auctionId: auctionId, floor: plan.resolvedFloor)]
            )
        case .configResolved(.passthrough(let cause)):
            return (.passthrough(cause), [.emitPassthrough(cause: cause)])
        case .lateAuctionCompleted(let lateAuctionId):
            return (.resolvingFloor(auctionId: auctionId), [.emitBid(auctionId: lateAuctionId, late: true)])
        case .teardown:
            return (.tornDown, [])
        // Waiting on config for THIS auction id; nothing downstream can have happened yet.
        case .auctionCompleted, .auctionTimedOut, .auctionFailed,
             .gamLoaded, .gamFailed, .impressionRecorded, .refreshDue:
            return (.resolvingFloor(auctionId: auctionId), [])
        }
    }

    private func reduceAuctioning(
        _ plan: LongitudeSlotPlan, _ auctionId: String, _ input: LNGTDSlotInput
    ) -> (LNGTDSlotState, [LNGTDSlotEffect]) {
        switch input {
        case .auctionCompleted:
            return (.requestingGAM(plan: plan, auctionId: auctionId), [
                .emitBid(auctionId: auctionId, late: false),
                .requestGAM(plan: plan, auctionId: auctionId)
            ])
        case .auctionTimedOut, .auctionFailed:
            return (
                .requestingGAM(plan: plan, auctionId: auctionId),
                [.requestGAM(plan: plan, auctionId: auctionId)]
            )
        case .lateAuctionCompleted(let lateAuctionId):
            return (
                .auctioning(plan: plan, auctionId: auctionId),
                [.emitBid(auctionId: lateAuctionId, late: true)]
            )
        case .refreshDue:
            // Deferred refresh creates a queue of stale refreshes; dropping it means we rely on the host's timer or next trigger. Dropping chosen to keep pure logic simple.
            return (.auctioning(plan: plan, auctionId: auctionId), [])
        case .teardown:
            return (.tornDown, [])
        // The GAM request has not been made yet, and no creative exists to impress.
        case .configResolved, .gamLoaded, .gamFailed, .impressionRecorded:
            return (.auctioning(plan: plan, auctionId: auctionId), [])
        }
    }

    private func reduceRequestingGAM(
        _ plan: LongitudeSlotPlan, _ auctionId: String, _ input: LNGTDSlotInput
    ) -> (LNGTDSlotState, [LNGTDSlotEffect]) {
        switch input {
        case .gamLoaded:
            return (.rendered(plan: plan, auctionId: auctionId), [])
        case .gamFailed:
            // A terminal failure, NOT a passthrough.
            //
            // The delivered version mapped this to `.passthrough(.invalidGamPath)`, on the
            // reading that a creative which failed to load means the path is "practically
            // invalid". It does not: `invalidGamPath` is documented as the ad unit having no
            // usable `gamPath`, which is a config defect a publisher fixes. Here the config was
            // fine, the auction ran and the request went out — GAM simply did not fill.
            // Reporting that as a broken path sends support after the wrong thing.
            return (.failed(.gamNoFill), [.emitFailure(.gamNoFill)])
        case .lateAuctionCompleted(let lateAuctionId):
            return (
                .requestingGAM(plan: plan, auctionId: auctionId),
                [.emitBid(auctionId: lateAuctionId, late: true)]
            )
        case .refreshDue:
            // Dropped mid-request refresh to avoid dual inflight states.
            return (.requestingGAM(plan: plan, auctionId: auctionId), [])
        case .teardown:
            return (.tornDown, [])
        // The auction is already over — its result was used to build this request — and there is
        // no creative yet to impress or refresh.
        case .configResolved, .auctionCompleted, .auctionTimedOut, .auctionFailed,
             .impressionRecorded:
            return (.requestingGAM(plan: plan, auctionId: auctionId), [])
        }
    }

    private func reduceRendered(
        _ plan: LongitudeSlotPlan, _ auctionId: String, _ input: LNGTDSlotInput
    ) -> (LNGTDSlotState, [LNGTDSlotEffect]) {
        switch input {
        case .impressionRecorded:
            return (.impressed(plan: plan, auctionId: auctionId), [])
        case .lateAuctionCompleted(let lateAuctionId):
            return (
                .rendered(plan: plan, auctionId: auctionId),
                [.emitBid(auctionId: lateAuctionId, late: true)]
            )
        case .refreshDue:
            // Ignored because impression has not been counted yet.
            return (.rendered(plan: plan, auctionId: auctionId), [])
        case .teardown:
            return (.tornDown, [])
        case .configResolved, .auctionCompleted, .auctionTimedOut, .auctionFailed,
             .gamLoaded, .gamFailed:
            return (.rendered(plan: plan, auctionId: auctionId), [])
        }
    }

    private func reduceImpressed(
        _ plan: LongitudeSlotPlan, _ auctionId: String, _ input: LNGTDSlotInput
    ) -> (LNGTDSlotState, [LNGTDSlotEffect]) {
        switch input {
        case .refreshDue:
            let newAuctionId = generateAuctionId()
            return (.resolvingFloor(auctionId: newAuctionId), [.resolveFloor(auctionId: newAuctionId)])
        case .lateAuctionCompleted(let lateAuctionId):
            return (
                .impressed(plan: plan, auctionId: auctionId),
                [.emitBid(auctionId: lateAuctionId, late: true)]
            )
        case .teardown:
            return (.tornDown, [])
        case .configResolved, .auctionCompleted, .auctionTimedOut, .auctionFailed,
             .gamLoaded, .gamFailed, .impressionRecorded:
            return (.impressed(plan: plan, auctionId: auctionId), [])
        }
    }

    private func reduceFailed(
        _ failure: LNGTDSlotFailure, _ input: LNGTDSlotInput
    ) -> (LNGTDSlotState, [LNGTDSlotEffect]) {
        switch input {
        case .lateAuctionCompleted(let lateAuctionId):
            return (.failed(failure), [.emitBid(auctionId: lateAuctionId, late: true)])
        case .teardown:
            return (.tornDown, [])
        // A no-fill is terminal for this auction. A refresh is how the slot tries again, and
        // that is 2d-4's concern; it is dropped here rather than silently restarting a flow
        // whose GAM request already came back empty.
        case .configResolved, .auctionCompleted, .auctionTimedOut, .auctionFailed,
             .gamLoaded, .gamFailed, .impressionRecorded, .refreshDue:
            return (.failed(failure), [])
        }
    }

    private func reducePassthrough(
        _ cause: PassthroughCause, _ input: LNGTDSlotInput
    ) -> (LNGTDSlotState, [LNGTDSlotEffect]) {
        switch input {
        case .lateAuctionCompleted(let lateAuctionId):
            return (.passthrough(cause), [.emitBid(auctionId: lateAuctionId, late: true)])
        case .teardown:
            return (.tornDown, [])
        // Serving GMA direct. Longitude's flow is over for this slot, so no auction or render
        // input applies — but a late bid is still reported above, because a bidder that answers
        // after we gave up is exactly what we want to know.
        case .configResolved, .auctionCompleted, .auctionTimedOut, .auctionFailed,
             .gamLoaded, .gamFailed, .impressionRecorded, .refreshDue:
            return (.passthrough(cause), [])
        }
    }
}
