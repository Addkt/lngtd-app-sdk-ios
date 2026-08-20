import Foundation

public protocol LNGTDDemandFetching: Sendable {
    func fetchDemand(completion: @escaping @Sendable (LNGTDAuctionOutcome, [String: String]?, Double?) -> Void)
    func stopAutoRefresh()
}

public final class LNGTDAuctionRunner: @unchecked Sendable {
    private let fetcher: LNGTDDemandFetching
    private let timeout: TimeInterval
    private let scheduler: @Sendable (TimeInterval, DispatchWorkItem) -> Void

    private let lock = NSLock()
    private var inFlightRelease: WatchdogRelease?

    public init(
        fetcher: LNGTDDemandFetching,
        timeout: TimeInterval,
        scheduler: @escaping @Sendable (TimeInterval, DispatchWorkItem) -> Void = { delay, item in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
        }
    ) {
        self.fetcher = fetcher
        self.timeout = timeout
        self.scheduler = scheduler
    }

    public func start(
        onPrimary: @escaping @Sendable (LNGTDAuctionResult) -> Void,
        onLate: @escaping @Sendable (LNGTDAuctionResult) -> Void
    ) {
        lock.lock()
        guard inFlightRelease == nil else {
            lock.unlock()
            return
        }

        let release = WatchdogRelease(onPrimary: onPrimary, onLate: onLate)
        // Assigned after construction: referring to `release` inside its own initialiser
        // call is a capture-before-declaration error.
        release.onPrimaryDelivered = { [weak self, weak release] in
            guard let release else { return }
            self?.clearInFlight(release)
        }
        inFlightRelease = release
        lock.unlock()

        let watchdog = DispatchWorkItem { [weak release] in
            release?.completeFromWatchdog()
        }
        release.arm(watchdog)
        scheduler(timeout, watchdog)

        // STRONG capture, deliberately.
        //
        // Once the watchdog wins, `clearInFlight` drops the runner's reference so a new
        // auction can start. If this closure held the release weakly it would be the only
        // other owner, the release would deallocate, and the late completion — the entire
        // reason the late path exists — would arrive to a nil object and be dropped in
        // silence. Prebid calls this completion at most once, so the closure and the release
        // are freed when it does.
        fetcher.fetchDemand { outcome, keywords, exp in
            release.completeFromFetcher(outcome: outcome, keywords: keywords, exp: exp)
        }
    }

    public func teardown() {
        lock.lock()
        let release = inFlightRelease
        inFlightRelease = nil
        lock.unlock()

        release?.teardown()
        fetcher.stopAutoRefresh()
    }

    private func clearInFlight(_ release: WatchdogRelease) {
        lock.lock()
        if inFlightRelease === release {
            inFlightRelease = nil
        }
        lock.unlock()
    }
}

private enum RunnerState {
    case running
    case completed
    case tornDown
}

/// Releases an auction outcome exactly once, from whichever of the two paths arrives
/// first: the fetcher completing, or the watchdog firing.
private final class WatchdogRelease: @unchecked Sendable {
    private let onPrimary: @Sendable (LNGTDAuctionResult) -> Void
    private let onLate: @Sendable (LNGTDAuctionResult) -> Void
    /// Set by the runner after construction so it can drop its in-flight reference once the
    /// primary outcome has been delivered, without the release having to know about it.
    var onPrimaryDelivered: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var state: RunnerState = .running
    private var watchdog: DispatchWorkItem?

    init(
        onPrimary: @escaping @Sendable (LNGTDAuctionResult) -> Void,
        onLate: @escaping @Sendable (LNGTDAuctionResult) -> Void
    ) {
        self.onPrimary = onPrimary
        self.onLate = onLate
    }

    func arm(_ watchdog: DispatchWorkItem) {
        lock.lock()
        if state != .running {
            lock.unlock()
            watchdog.cancel()
            return
        }
        self.watchdog = watchdog
        lock.unlock()
    }

    func completeFromFetcher(outcome: LNGTDAuctionOutcome, keywords: [String: String]?, exp: Double?) {
        lock.lock()
        switch state {
        case .running:
            state = .completed
            let item = watchdog
            watchdog = nil
            lock.unlock()
            item?.cancel()
            onPrimary(
                LNGTDAuctionResult(
                    outcome: outcome, targetingKeywords: keywords, exp: exp, isLate: false
                )
            )
            onPrimaryDelivered?()
        case .completed:
            lock.unlock()
            onLate(
                LNGTDAuctionResult(
                    outcome: outcome, targetingKeywords: keywords, exp: exp, isLate: true
                )
            )
        case .tornDown:
            lock.unlock()
        }
    }

    func completeFromWatchdog() {
        lock.lock()
        switch state {
        case .running:
            state = .completed
            watchdog = nil
            lock.unlock()
            onPrimary(
                LNGTDAuctionResult(
                    outcome: .timeout, targetingKeywords: nil, exp: nil, isLate: false
                )
            )
            onPrimaryDelivered?()
        case .completed, .tornDown:
            lock.unlock()
        }
    }

    func teardown() {
        lock.lock()
        if state == .running {
            state = .tornDown
            let item = watchdog
            watchdog = nil
            lock.unlock()
            item?.cancel()
        } else {
            state = .tornDown
            lock.unlock()
        }
    }
}
