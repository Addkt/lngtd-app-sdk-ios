import Foundation

/// Session primitives and state management for LongitudeCore.
public final class LNGTDSession: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: () -> TimeInterval

    private var _sessionId: String
    private var _sessionDepth: Int
    private var _pageviewId: String
    private var _page: String?
    private var _referrer: String?

    private var _backgroundedAt: TimeInterval?
    private var _isSampled: Bool?
    private var _hasTrackedScreen: Bool

    // 30 minutes in the background expires the session.
    private let expirationInterval: TimeInterval = 30 * 60

    public init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        self._sessionId = UUID().uuidString
        self._sessionDepth = 0
        self._pageviewId = UUID().uuidString
        self._page = nil
        self._referrer = nil
        self._backgroundedAt = nil
        self._isSampled = nil
        self._hasTrackedScreen = false
    }

    public var sessionId: String {
        lock.lock(); defer { lock.unlock() }
        return _sessionId
    }

    public var sessionDepth: Int {
        lock.lock(); defer { lock.unlock() }
        return _sessionDepth
    }

    public var pageviewId: String {
        lock.lock(); defer { lock.unlock() }
        return _pageviewId
    }

    public var page: String? {
        lock.lock(); defer { lock.unlock() }
        return _page
    }

    public var referrer: String? {
        lock.lock(); defer { lock.unlock() }
        return _referrer
    }

    public func didEnterBackground() {
        lock.lock(); defer { lock.unlock() }
        _backgroundedAt = clock()
    }

    public func willEnterForeground() {
        lock.lock(); defer { lock.unlock() }

        if let bgTime = _backgroundedAt {
            let now = clock()
            // The boundary chosen is inclusive: exactly 30 minutes in the background expires the session.
            if now - bgTime >= expirationInterval {
                resetSession()
            }
        }
        _backgroundedAt = nil
    }

    public func trackScreenView(_ name: String) {
        lock.lock(); defer { lock.unlock() }

        // We count tracking the same screen name twice in a row as a second screen view.
        // Returning to a feed (or triggering it again) is a new pageview with a new ad opportunity.
        _referrer = _page
        _page = name

        if _hasTrackedScreen {
            _sessionDepth += 1
        } else {
            _hasTrackedScreen = true
            // sessionDepth stays 0 on the first track
        }

        _pageviewId = UUID().uuidString
    }

    /// Evaluates if the current session is sampled.
    /// The sampling decision is evaluated once per session and held (cached),
    /// so a config change of `sampleRate` mid-session does not flip the decision.
    public func isSampled(sampler: LNGTDSampler, sampleRate: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }

        if let decision = _isSampled {
            return decision
        }

        let decision = sampler.isSampled(sessionId: _sessionId, sampleRate: sampleRate)
        _isSampled = decision
        return decision
    }

    private func resetSession() {
        _sessionId = UUID().uuidString
        _sessionDepth = 0
        _pageviewId = UUID().uuidString
        _page = nil
        _referrer = nil
        _isSampled = nil
        _hasTrackedScreen = false
    }
}
