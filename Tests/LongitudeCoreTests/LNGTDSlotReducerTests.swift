import XCTest
@testable import LongitudeCore

final class LNGTDSlotReducerTests: XCTestCase {
    private let samplePlan = LongitudeSlotPlan(
        gamPath: "/123/test",
        sizes: [[320, 50]],
        resolvedFloor: .value(1.0),
        uid: "test_uid",
        refreshSeconds: 30,
        lazyLoad: false
    )

    private func makeReducer(auctionId: String = "test_a1") -> LNGTDSlotReducer {
        var id = auctionId
        return LNGTDSlotReducer {
            let current = id
            id = current + "_next"
            return current
        }
    }

    // 1. The happy path in order: config resolved to `.longitude` → auction → GAM → rendered → impressed
    func test1_happyPathInOrder() {
        let reducer = makeReducer(auctionId: "a1")
        var state: LNGTDSlotState = .awaitingConfig
        var effects: [LNGTDSlotEffect] = []

        (state, effects) = reducer.reduce(state, .configResolved(.longitude(samplePlan)))
        XCTAssertEqual(state, .auctioning(plan: samplePlan, auctionId: "a1"))
        XCTAssertEqual(effects, [.startAuction(plan: samplePlan, auctionId: "a1", floor: .value(1.0))])

        (state, effects) = reducer.reduce(state, .auctionCompleted)
        XCTAssertEqual(state, .requestingGAM(plan: samplePlan, auctionId: "a1"))
        XCTAssertEqual(effects, [
            .emitBid(auctionId: "a1", late: false),
            .requestGAM(plan: samplePlan, auctionId: "a1")
        ])

        (state, effects) = reducer.reduce(state, .gamLoaded)
        XCTAssertEqual(state, .rendered(plan: samplePlan, auctionId: "a1"))
        XCTAssertEqual(effects, [])

        (state, effects) = reducer.reduce(state, .impressionRecorded)
        XCTAssertEqual(state, .impressed(plan: samplePlan, auctionId: "a1"))
        XCTAssertEqual(effects, [])
    }

    // 2. Starting an auction emits a fresh auction id, and a second auction emits a different one.
    func test2_startingAuctionEmitsFreshIds() {
        var counter = 1
        let reducer = LNGTDSlotReducer {
            let id = "a\(counter)"
            counter += 1
            return id
        }

        let (state1, effects1) = reducer.reduce(.awaitingConfig, .configResolved(.longitude(samplePlan)))
        XCTAssertEqual(state1, .auctioning(plan: samplePlan, auctionId: "a1"))
        XCTAssertEqual(effects1, [.startAuction(plan: samplePlan, auctionId: "a1", floor: .value(1.0))])

        let (state2, effects2) = reducer.reduce(.impressed(plan: samplePlan, auctionId: "a1"), .refreshDue)
        XCTAssertEqual(state2, .resolvingFloor(auctionId: "a2"))
        XCTAssertEqual(effects2, [.resolveFloor(auctionId: "a2")])
    }

    // 3. `.passthrough(.killSwitch)` from `awaitingConfig` goes straight to passthrough and emits an event.
    func test3_passthroughKillSwitchFromAwaitingConfig() {
        let reducer = makeReducer()
        let (state, effects) = reducer.reduce(.awaitingConfig, .configResolved(.passthrough(.killSwitch)))

        XCTAssertEqual(state, .passthrough(.killSwitch))
        XCTAssertEqual(effects, [.emitPassthrough(cause: .killSwitch)])
    }

    // 4. Each `PassthroughCause` is carried distinctly.
    func test4_eachPassthroughCauseDistinct() {
        let reducer = makeReducer()
        let causes: [PassthroughCause] = [
            .noConfig, .killSwitch, .unknownSlot, .invalidGamPath, .unsupportedConfig
        ]

        for cause in causes {
            let (state, effects) = reducer.reduce(.awaitingConfig, .configResolved(.passthrough(cause)))
            XCTAssertEqual(state, .passthrough(cause))
            XCTAssertEqual(effects, [.emitPassthrough(cause: cause)])
        }
    }

    // 5. An auction timeout moves on to `requestingGAM` rather than stalling.
    func test5_auctionTimeoutMovesToRequestingGAM() {
        let reducer = makeReducer()
        let startState = LNGTDSlotState.auctioning(plan: samplePlan, auctionId: "a1")
        let (state, effects) = reducer.reduce(startState, .auctionTimedOut)

        XCTAssertEqual(state, .requestingGAM(plan: samplePlan, auctionId: "a1"))
        XCTAssertEqual(effects, [.requestGAM(plan: samplePlan, auctionId: "a1")])
    }

    // 6. A late completion after a timeout does not change state.
    func test6_lateCompletionDoesNotChangeState() {
        let reducer = makeReducer()
        let startState = LNGTDSlotState.requestingGAM(plan: samplePlan, auctionId: "a1")
        let (state, _) = reducer.reduce(startState, .lateAuctionCompleted(auctionId: "a1"))

        XCTAssertEqual(state, startState, "State must not change on late completion")
    }

    // 7. That same late completion does emit a `bid` effect marked late.
    func test7_lateCompletionEmitsLateBidEffect() {
        let reducer = makeReducer()
        let startState = LNGTDSlotState.requestingGAM(plan: samplePlan, auctionId: "a1")
        let (_, effects) = reducer.reduce(startState, .lateAuctionCompleted(auctionId: "a1"))

        XCTAssertEqual(effects, [.emitBid(auctionId: "a1", late: true)])
    }

    // 8. A refresh input while `auctioning` does not start a second auction.
    func test8_refreshWhileAuctioningDoesNotStartSecondAuction() {
        let reducer = makeReducer()
        let startState = LNGTDSlotState.auctioning(plan: samplePlan, auctionId: "a1")
        let (state, effects) = reducer.reduce(startState, .refreshDue)

        XCTAssertEqual(state, startState)
        XCTAssertTrue(effects.isEmpty)
    }

    // 9. A refresh input while `requestingGAM` does not start a second auction.
    func test9_refreshWhileRequestingGAMDoesNotStartSecondAuction() {
        let reducer = makeReducer()
        let startState = LNGTDSlotState.requestingGAM(plan: samplePlan, auctionId: "a1")
        let (state, effects) = reducer.reduce(startState, .refreshDue)

        XCTAssertEqual(state, startState)
        XCTAssertTrue(effects.isEmpty)
    }

    // 10. A refresh from `impressed` starts exactly one new auction, with a new id.
    func test10_refreshFromImpressedStartsNewAuction() {
        let reducer = makeReducer(auctionId: "a2")
        let startState = LNGTDSlotState.impressed(plan: samplePlan, auctionId: "a1")
        let (state, effects) = reducer.reduce(startState, .refreshDue)

        XCTAssertEqual(state, .resolvingFloor(auctionId: "a2"))
        XCTAssertEqual(effects, [.resolveFloor(auctionId: "a2")])
    }

    // 11. A refresh from `rendered` does not start one — the impression has not been counted yet.
    func test11_refreshFromRenderedDoesNotStartNewAuction() {
        let reducer = makeReducer()
        let startState = LNGTDSlotState.rendered(plan: samplePlan, auctionId: "a1")
        let (state, effects) = reducer.reduce(startState, .refreshDue)

        XCTAssertEqual(state, startState)
        XCTAssertTrue(effects.isEmpty)
    }

    // 12. A GAM failure after a successful auction routes to passthrough with a distinct cause and still emits.
    func test12_gamFailureAfterAnAuctionIsATerminalFailureNotAPassthrough() {
        let reducer = makeReducer()
        let startState = LNGTDSlotState.requestingGAM(plan: samplePlan, auctionId: "a1")
        let (state, effects) = reducer.reduce(startState, .gamFailed)

        // NOT `.passthrough(.invalidGamPath)`. That cause means the ad unit has no usable
        // gamPath — a config defect a publisher fixes. Here the config was fine, the auction ran
        // and the request went out; GAM just did not fill. Reporting it as a broken path sends
        // support after the wrong thing.
        XCTAssertEqual(state, .failed(.gamNoFill))
        XCTAssertEqual(effects, [.emitFailure(.gamNoFill)])
    }

    // 13. Teardown from any state produces no further effects, and a late completion arriving after teardown produces none either.
    func test13_teardownProducesNoEffects() {
        let reducer = makeReducer()
        let allStates: [LNGTDSlotState] = [
            .awaitingConfig,
            .resolvingFloor(auctionId: "a1"),
            .auctioning(plan: samplePlan, auctionId: "a1"),
            .requestingGAM(plan: samplePlan, auctionId: "a1"),
            .rendered(plan: samplePlan, auctionId: "a1"),
            .impressed(plan: samplePlan, auctionId: "a1"),
            .passthrough(.killSwitch),
            .tornDown
        ]

        for state in allStates {
            let (tornState, effects) = reducer.reduce(state, .teardown)
            XCTAssertEqual(tornState, .tornDown)
            XCTAssertTrue(effects.isEmpty)
        }

        let (finalState, finalEffects) = reducer.reduce(.tornDown, .lateAuctionCompleted(auctionId: "a1"))
        XCTAssertEqual(finalState, .tornDown)
        XCTAssertTrue(finalEffects.isEmpty)
    }

    // 14. Exhaustiveness: every (state, input) pair either transitions or is explicitly documented as ignored.
    // 14. Exhaustiveness.
    //
    // The compiler now carries most of this: every reducer function enumerates every input with
    // no `default:` arm, so an unhandled pair will not build. The delivered version had a
    // `default` in each function and a loop that only checked the reducer did not hit a
    // fatalError — which lint already forbids — so it asserted nothing at all.
    //
    // What is left to check at runtime are the invariants a compiler cannot see.
    func test14_terminalAndGlobalInvariants() {
        let reducer = makeReducer()

        let allStates: [LNGTDSlotState] = [
            .awaitingConfig,
            .resolvingFloor(auctionId: "a1"),
            .auctioning(plan: samplePlan, auctionId: "a1"),
            .requestingGAM(plan: samplePlan, auctionId: "a1"),
            .rendered(plan: samplePlan, auctionId: "a1"),
            .impressed(plan: samplePlan, auctionId: "a1"),
            .passthrough(.killSwitch),
            .failed(.gamNoFill),
            .tornDown
        ]

        let allInputs: [LNGTDSlotInput] = [
            .configResolved(.longitude(samplePlan)),
            .configResolved(.passthrough(.killSwitch)),
            .auctionCompleted,
            .auctionTimedOut,
            .auctionFailed,
            .gamLoaded,
            .gamFailed,
            .impressionRecorded,
            .refreshDue,
            .lateAuctionCompleted(auctionId: "late-1"),
            .teardown
        ]

        for input in allInputs {
            // A torn-down slot is inert. Anything else means a deallocated view's slot can still
            // emit, or worse, restart an auction.
            let (state, effects) = reducer.reduce(.tornDown, input)
            XCTAssertEqual(state, .tornDown, "teardown is terminal for \(input)")
            XCTAssertEqual(effects, [], "a torn-down slot must emit nothing for \(input)")
        }

        for state in allStates where state != .tornDown {
            // Dropped from the FLOW, not from REPORTING. A bidder consistently past the timeout
            // is invisible unless every state still reports a late bid.
            let (next, effects) = reducer.reduce(state, .lateAuctionCompleted(auctionId: "late-1"))
            XCTAssertEqual(next, state, "a late bid must not move \(state)")
            XCTAssertEqual(
                effects, [.emitBid(auctionId: "late-1", late: true)],
                "a late bid must still be reported from \(state)"
            )
        }

        for input in allInputs where input != .teardown {
            // Terminal states stay terminal. Nothing but teardown may pull them back in.
            for terminal in [LNGTDSlotState.passthrough(.killSwitch), .failed(.gamNoFill)] {
                let (next, _) = reducer.reduce(terminal, input)
                XCTAssertEqual(next, terminal, "\(terminal) must not be reopened by \(input)")
            }
        }
    }
}
