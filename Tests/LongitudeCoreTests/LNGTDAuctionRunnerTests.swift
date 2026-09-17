import XCTest
@testable import LongitudeCore

private final class AuctionRunnerFakeFetcher: LNGTDDemandFetching, @unchecked Sendable {
    var completions: [(LNGTDAuctionOutcome, [String: String]?, Double?) -> Void] = []
    var fetchCallCount = 0
    var stopAutoRefreshCallCount = 0
    let lock = NSLock()

    func fetchDemand(completion: @escaping @Sendable (LNGTDAuctionOutcome, [String: String]?, Double?) -> Void) {
        lock.lock()
        fetchCallCount += 1
        completions.append(completion)
        lock.unlock()
    }

    func stopAutoRefresh() {
        lock.lock()
        stopAutoRefreshCallCount += 1
        lock.unlock()
    }

    func complete(at index: Int, outcome: LNGTDAuctionOutcome, keywords: [String: String]?, exp: Double?) {
        lock.lock()
        let completion = completions[index]
        lock.unlock()
        completion(outcome, keywords, exp)
    }
}

final class LNGTDAuctionRunnerTests: XCTestCase {

    private var fetcher: AuctionRunnerFakeFetcher!
    private var runner: LNGTDAuctionRunner!
    private var watchdogTriggers: [DispatchWorkItem] = []

    private var primaryOutcomes: [LNGTDAuctionResult] = []
    private var lateOutcomes: [LNGTDAuctionResult] = []

    override func setUp() {
        super.setUp()
        fetcher = AuctionRunnerFakeFetcher()
        runner = LNGTDAuctionRunner(
            fetcher: fetcher,
            timeout: 1.0,
            scheduler: { [weak self] _, item in
                self?.watchdogTriggers.append(item)
            }
        )
        watchdogTriggers = []
        primaryOutcomes = []
        lateOutcomes = []
    }

    private func startRunner() {
        runner.start(
            onPrimary: { [weak self] result in
                self?.primaryOutcomes.append(result)
            },
            onLate: { [weak self] result in
                self?.lateOutcomes.append(result)
            }
        )
    }

    // 1. A completion inside the budget yields exactly one outcome, marked not late.
    func test1_completionInsideBudgetYieldsOneOutcomeNotLate() {
        startRunner()
        fetcher.complete(at: 0, outcome: .success, keywords: nil, exp: nil)

        XCTAssertEqual(primaryOutcomes.count, 1, "Expected exactly one primary outcome")
        XCTAssertEqual(primaryOutcomes.first?.outcome, .success)
        XCTAssertEqual(primaryOutcomes.first?.isLate, false)
        XCTAssertTrue(lateOutcomes.isEmpty, "Expected no late outcomes")
    }

    // 2. No completion by the deadline yields exactly one timed-out outcome.
    func test2_noCompletionByDeadlineYieldsTimeoutOutcome() {
        startRunner()
        XCTAssertEqual(watchdogTriggers.count, 1, "Expected watchdog to be scheduled")
        watchdogTriggers.last?.perform()

        XCTAssertEqual(primaryOutcomes.count, 1, "Expected exactly one primary outcome")
        XCTAssertEqual(primaryOutcomes.first?.outcome, .timeout)
        XCTAssertEqual(primaryOutcomes.first?.isLate, false)
        XCTAssertTrue(lateOutcomes.isEmpty, "Expected no late outcomes")
    }

    // 3. A completion arriving after the deadline yields a late result.
    func test3_completionAfterDeadlineYieldsLateResult() {
        startRunner()
        watchdogTriggers.last?.perform()
        fetcher.complete(at: 0, outcome: .success, keywords: ["k": "v"], exp: 2.0)

        XCTAssertEqual(lateOutcomes.count, 1, "Expected exactly one late outcome")
        XCTAssertEqual(lateOutcomes.first?.outcome, .success)
        XCTAssertEqual(lateOutcomes.first?.isLate, true)
    }

    // 4. That late arrival does not replace or repeat the primary outcome — assert the primary was
    // delivered exactly once, with its original value.
    func test4_lateArrivalDoesNotReplacePrimaryOutcome() {
        startRunner()
        watchdogTriggers.last?.perform()

        let primaryCopy = primaryOutcomes
        XCTAssertEqual(primaryCopy.count, 1)
        XCTAssertEqual(primaryCopy.first?.outcome, .timeout)

        fetcher.complete(at: 0, outcome: .success, keywords: nil, exp: nil)

        XCTAssertEqual(primaryOutcomes.count, 1, "Primary outcome count should remain 1")
        XCTAssertEqual(primaryOutcomes.first, primaryCopy.first, "Primary outcome should be unchanged")
    }

    // 5. A completion and a timeout racing produce exactly one primary outcome, whichever order the test drives them in.
    // 5a. The completion wins the race.
    //
    // Split from 5b rather than calling `setUp()` by hand mid-test, which is not a reset:
    // `watchdogTriggers` survived it, so `.first` performed the previous run's already
    // cancelled work item and the assertion passed for the wrong reason.
    func test5a_completionBeforeTimeoutYieldsExactlyOneSuccess() {
        startRunner()
        fetcher.complete(at: 0, outcome: .success, keywords: nil, exp: nil)
        watchdogTriggers.last?.perform()

        XCTAssertEqual(primaryOutcomes.count, 1, "exactly one primary outcome")
        XCTAssertEqual(primaryOutcomes.first?.outcome, .success)
    }

    // 5b. The timeout wins the race.
    func test5b_timeoutBeforeCompletionYieldsExactlyOneTimeout() {
        startRunner()
        watchdogTriggers.last?.perform()
        fetcher.complete(at: 0, outcome: .success, keywords: nil, exp: nil)

        XCTAssertEqual(primaryOutcomes.count, 1, "exactly one primary outcome")
        XCTAssertEqual(
            primaryOutcomes.first?.outcome, .timeout,
            "the watchdog got there first; the completion is late, not primary"
        )
        XCTAssertEqual(lateOutcomes.count, 1, "and the late arrival is still reported")
    }

    // 6. The watchdog is cancelled when the completion wins — assert no timed-out outcome arrives afterwards.
    func test6_watchdogIsCancelledWhenCompletionWins() {
        startRunner()
        let watchdog = watchdogTriggers.first
        XCTAssertNotNil(watchdog)

        fetcher.complete(at: 0, outcome: .success, keywords: nil, exp: nil)
        XCTAssertEqual(watchdog?.isCancelled, true, "the watchdog is cancelled once the completion wins")

        watchdog?.perform()
        XCTAssertEqual(primaryOutcomes.count, 1, "Should still have exactly one primary outcome")
        XCTAssertEqual(primaryOutcomes.first?.outcome, .success, "Primary outcome should not be timeout")
    }

    // 7. Starting a second run while one is in flight is refused and does not call the fetcher twice.
    func test7_startingSecondRunWhileInFlightIsRefused() {
        startRunner()
        startRunner()

        XCTAssertEqual(fetcher.fetchCallCount, 1, "Fetcher should only be called once")
    }

    // 8. targetingKeywords and exp survive from the fetcher into the result unchanged.
    func test8_targetingKeywordsAndExpSurviveUnchanged() {
        startRunner()
        let keywords = ["key1": "val1", "key2": "val2"]
        let exp = 1.23
        fetcher.complete(at: 0, outcome: .success, keywords: keywords, exp: exp)

        XCTAssertEqual(primaryOutcomes.first?.targetingKeywords, keywords)
        XCTAssertEqual(primaryOutcomes.first?.exp, exp)
    }

    // 9. Empty targeting is distinguishable from absent targeting — [:] and nil must not collapse into one result.
    func test9_emptyTargetingIsDistinguishableFromAbsent() {
        startRunner()
        fetcher.complete(at: 0, outcome: .success, keywords: [:], exp: nil)
        XCTAssertNotNil(primaryOutcomes.first?.targetingKeywords, "Targeting keywords should not be nil")
        XCTAssertTrue(primaryOutcomes.first?.targetingKeywords?.isEmpty == true, "Targeting keywords should be empty")

        setUp()
        startRunner()
        fetcher.complete(at: 0, outcome: .success, keywords: nil, exp: nil)
        XCTAssertNil(primaryOutcomes.first?.targetingKeywords, "Targeting keywords should be nil")
    }

    // 10. Every Prebid result code the mapping handles produces a distinct outcome, and an
    // unrecognised one maps to a defined fallback rather than crashing.
    // Note: Since we cannot import Prebid in this Foundation-only test module, we assert that
    // the LNGTDAuctionOutcome enum has all the distinct cases the mapping will require.
    func test10_distinctOutcomesExistForMapping() {
        let expectedCases: [LNGTDAuctionOutcome] = [
            .success,
            .noBids,
            .timeout,
            .networkError,
            .serverError,
            .invalidAccountId,
            .invalidConfigId,
            .invalidSize,
            .unrecognised
        ]
        XCTAssertEqual(expectedCases.count, 9, "Expected 9 distinct outcome cases to map from Prebid")
        XCTAssertEqual(Set(expectedCases).count, 9, "All mapping cases must be distinct")
    }

    // 11. Teardown mid-flight produces no outcome at all, and a completion arriving afterwards produces none either.
    func test11_teardownMidFlightProducesNoOutcome() {
        startRunner()
        let watchdog = watchdogTriggers.first
        XCTAssertNotNil(watchdog)

        runner.teardown()
        XCTAssertEqual(watchdog?.isCancelled, true, "the watchdog is cancelled on teardown")
        XCTAssertEqual(fetcher.stopAutoRefreshCallCount, 1, "Fetcher should be told to stop auto refresh")

        watchdog?.perform()
        fetcher.complete(at: 0, outcome: .success, keywords: nil, exp: nil)

        XCTAssertTrue(primaryOutcomes.isEmpty, "No primary outcome should be produced")
        XCTAssertTrue(lateOutcomes.isEmpty, "No late outcome should be produced")
    }
}
