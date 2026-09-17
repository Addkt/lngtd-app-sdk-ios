import Foundation

public protocol LNGTDSlotControllerDelegate: AnyObject, Sendable {
    func resolveFloor(auctionId: String)
    func requestGAM(plan: LongitudeSlotPlan, auctionId: String, targeting: [String: Any])
    func emitBid(auctionId: String, late: Bool)
    func emitPassthrough(cause: PassthroughCause, targeting: [String: Any])
    func emitFailure(_ failure: LNGTDSlotFailure)
}

public final class LNGTDSlotController: @unchecked Sendable {
    private let reducer: LNGTDSlotReducer
    private let runner: LNGTDAuctionRunner
    private let lock = NSLock()

    private var state: LNGTDSlotState = .awaitingConfig
    private var latestExistingTargeting: [String: Any]?
    private var inFlightTargeting: [String: [String: String]] = [:]
    /// The auction the controller is currently driving. A superseded auction's completion must
    /// not move the state machine, and the reducer cannot tell — `.auctionCompleted` carries no
    /// id, so from its side a stale completion looks exactly like the live one.
    private var currentAuctionId: String?
    /// Auctions that actually produced a bid. Tracked separately from `inFlightTargeting`
    /// because that map is cleared once a GAM request consumes it, and because a late bid never
    /// enters it at all — inferring "was there a bid" from the targeting map got both wrong.
    private var auctionsWithBids: Set<String> = []

    public weak var delegate: LNGTDSlotControllerDelegate?

    public init(
        generateAuctionId: @escaping @Sendable () -> String = { UUID().uuidString },
        runner: LNGTDAuctionRunner
    ) {
        self.reducer = LNGTDSlotReducer(generateAuctionId: generateAuctionId)
        self.runner = runner
    }

    public func load(existingTargeting: [String: Any]?) {
        lock.lock()
        self.latestExistingTargeting = existingTargeting
        let (newState, effects) = reducer.reduce(state, .load)
        self.state = newState
        lock.unlock()

        handle(effects)
    }

    public func provideResolution(_ resolution: SlotResolution) {
        lock.lock()
        let (newState, effects) = reducer.reduce(state, .configResolved(resolution))
        self.state = newState
        lock.unlock()

        handle(effects)
    }

    public func gamLoaded() {
        lock.lock()
        let (newState, effects) = reducer.reduce(state, .gamLoaded)
        self.state = newState
        lock.unlock()
        handle(effects)
    }

    public func gamFailed() {
        lock.lock()
        let (newState, effects) = reducer.reduce(state, .gamFailed)
        self.state = newState
        lock.unlock()
        handle(effects)
    }

    public func impressionRecorded() {
        lock.lock()
        let (newState, effects) = reducer.reduce(state, .impressionRecorded)
        self.state = newState
        lock.unlock()
        handle(effects)
    }

    public func refreshDue() {
        lock.lock()
        let (newState, effects) = reducer.reduce(state, .refreshDue)
        self.state = newState
        lock.unlock()
        handle(effects)
    }

    public func teardown() {
        lock.lock()
        let (newState, effects) = reducer.reduce(state, .teardown)
        self.state = newState
        // Clean up targeting to avoid leaking memory on torn down slots
        self.latestExistingTargeting = nil
        self.inFlightTargeting.removeAll()
        self.currentAuctionId = nil
        self.auctionsWithBids.removeAll()
        lock.unlock()

        runner.teardown()
        handle(effects)
    }

    private func handlePrimaryResult(_ result: LNGTDAuctionResult, auctionId: String) {
        lock.lock()

        // A superseded auction, whose completion must not drive the auction that replaced it.
        //
        // Unreachable today, and worth saying so rather than implying otherwise: `.startAuction`
        // tears the previous run down before starting the new one, so a stale completion is
        // already suppressed inside the runner before it reaches here. This guard becomes
        // load-bearing the moment runners are created per auction rather than shared — which is
        // the natural shape once 2d-4 caps in-flight auctions — because then nothing tears the
        // old one down. Kept because `.auctionCompleted` carries no auction id, so the reducer
        // can never make this distinction itself.
        guard auctionId == currentAuctionId else {
            let (newState, effects) = reducer.reduce(
                state, .lateAuctionCompleted(auctionId: auctionId)
            )
            self.state = newState
            inFlightTargeting[auctionId] = nil
            lock.unlock()
            handle(effects)
            return
        }

        inFlightTargeting[auctionId] = result.targetingKeywords
        if !(result.targetingKeywords ?? [:]).isEmpty {
            auctionsWithBids.insert(auctionId)
        }
        let input: LNGTDSlotInput
        // Enumerated, not defaulted: `LNGTDAuctionOutcome` is ours, so the compiler can hold
        // this complete, and a new outcome should force a decision here rather than quietly
        // becoming a failure.
        switch result.outcome {
        case .success, .noBids:
            // `noBids` is NOT a failure. The auction ran, the server answered, and nobody bid —
            // a normal outcome for most impressions. Calling it a failure would make the
            // failure rate track fill rate and bury the errors it exists to surface. It
            // proceeds to GAM exactly like a success, just with no keywords to merge.
            input = .auctionCompleted
        case .timeout:
            input = .auctionTimedOut
        case .networkError, .serverError, .invalidAccountId, .invalidConfigId,
             .invalidSize, .unrecognised:
            input = .auctionFailed
        }
        let (newState, effects) = reducer.reduce(state, input)
        self.state = newState
        lock.unlock()

        handle(effects)
    }

    private func handleLateResult(_ result: LNGTDAuctionResult, auctionId: String) {
        lock.lock()
        if !(result.targetingKeywords ?? [:]).isEmpty {
            auctionsWithBids.insert(auctionId)
        }
        let (newState, effects) = reducer.reduce(state, .lateAuctionCompleted(auctionId: auctionId))
        self.state = newState
        lock.unlock()

        handle(effects)
    }

    private func handle(_ effects: [LNGTDSlotEffect]) {
        for effect in effects {
            switch effect {
            case .resolveFloor(let auctionId):
                currentAuctionId = auctionId
                delegate?.resolveFloor(auctionId: auctionId)

            case .startAuction(let plan, let auctionId, _):
                // Abandon any auction still in flight before starting this one.
                //
                // The runner refuses a second `start` while one is running — that guard exists
                // because Prebid's `baseFetchDemand` has none and overlapping fetches on one
                // `AdUnit` drop or double-fire completions. Without this teardown a superseding
                // `load()` resolved its floor, moved to `.auctioning`, and then silently never
                // started: the slot wedged until the view went away.
                //
                // The superseded auction's late bid is lost with it. That is the honest
                // trade: there is one `AdUnit` per slot, the new fetch reuses it, and a result
                // arriving from a fetch we abandoned on a unit since reused is not something to
                // report as a bid.
                runner.teardown()
                runner.start(
                    onPrimary: { [weak self] result in
                        self?.handlePrimaryResult(result, auctionId: auctionId)
                    },
                    onLate: { [weak self] result in
                        self?.handleLateResult(result, auctionId: auctionId)
                    }
                )

            case .requestGAM(let plan, let auctionId):
                lock.lock()
                let keywords = inFlightTargeting[auctionId]
                let existing = latestExistingTargeting
                inFlightTargeting[auctionId] = nil // clean up once used
                lock.unlock()

                let merged = LNGTDTargeting.merge(existing: existing, auctionKeys: keywords)
                delegate?.requestGAM(plan: plan, auctionId: auctionId, targeting: merged)

            case .emitBid(let auctionId, let late):
                // Only when a bid actually existed.
                //
                // The reducer's `.auctionCompleted` emits this unconditionally, and `noBids`
                // routes through it — the auction ran and the server answered, which is a
                // completed auction, not a failure. But nobody bid, so emitting `bid` there
                // would put a row in the warehouse for a bid that never happened and make the
                // bid count track auction count. Non-empty keywords is precisely the signal
                // that there was something to report.
                lock.lock()
                let hadBid = auctionsWithBids.contains(auctionId)
                lock.unlock()
                if hadBid {
                    delegate?.emitBid(auctionId: auctionId, late: late)
                }

            case .emitPassthrough(let cause):
                lock.lock()
                let existing = latestExistingTargeting
                lock.unlock()

                let merged = LNGTDTargeting.merge(existing: existing, auctionKeys: nil)
                delegate?.emitPassthrough(cause: cause, targeting: merged)

            case .emitFailure(let failure):
                delegate?.emitFailure(failure)
            }
        }
    }
}
