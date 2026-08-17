import Foundation

/// Why a slot stopped after it had already gone through Longitude.
///
/// Deliberately NOT a sixth `PassthroughCause`. `PassthroughCause` answers "why are we not
/// serving through Longitude", decided *before* any request goes out, and its five cases exist
/// because each one leads to a different support answer. A GAM request that came back empty is
/// the opposite situation: the config was fine, the auction ran, the request went out. Folding
/// it into `.invalidGamPath` would tell a publisher their `gamPath` is broken when it is not.
public enum LNGTDSlotFailure: Equatable, Sendable {
    /// GAM answered without a creative. Nothing here is misconfigured.
    case gamNoFill
}

public enum LNGTDSlotState: Equatable, Sendable {
    case awaitingConfig
    case resolvingFloor(auctionId: String)
    case auctioning(plan: LongitudeSlotPlan, auctionId: String)
    case requestingGAM(plan: LongitudeSlotPlan, auctionId: String)
    case rendered(plan: LongitudeSlotPlan, auctionId: String)
    case impressed(plan: LongitudeSlotPlan, auctionId: String)
    case passthrough(PassthroughCause)
    /// Terminal. GAM answered and did not fill; this is not a passthrough.
    case failed(LNGTDSlotFailure)
    case tornDown
}

public enum LNGTDSlotInput: Equatable, Sendable {
    case configResolved(SlotResolution)
    case auctionCompleted
    case auctionTimedOut
    case auctionFailed
    case gamLoaded
    case gamFailed
    case impressionRecorded
    case refreshDue
    case lateAuctionCompleted(auctionId: String)
    case teardown
}

public enum LNGTDSlotEffect: Equatable, Sendable {
    case resolveFloor(auctionId: String)
    case startAuction(plan: LongitudeSlotPlan, auctionId: String, floor: ResolvedFloor)
    case requestGAM(plan: LongitudeSlotPlan, auctionId: String)
    case emitBid(auctionId: String, late: Bool)
    case emitPassthrough(cause: PassthroughCause)
    case emitFailure(LNGTDSlotFailure)
}
