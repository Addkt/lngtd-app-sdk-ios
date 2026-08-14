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
    /// Load-bearing, not vestigial: it makes the first screen view report depth 0. See
    /// `trackScreenView`.
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

    public var isSampledDecision: Bool? {
        lock.lock(); defer { lock.unlock() }
        return _isSampled
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

    /// Everything a pageview needs, captured under one lock acquisition.
    ///
    /// `trackScreenView` returns this rather than leaving the caller to read `sessionId`,
    /// `sessionDepth`, `pageviewId`, `page` and `referrer` back one at a time. Each of those
    /// accessors takes the lock separately, so a second `trackScreenView` interleaving between
    /// them yields an event carrying one screen's name and another's depth and pageview id.
    /// Today every caller arrives on the main actor and cannot race, but nothing in the type
    /// enforces that, and a mislabelled pageview is invisible until a funnel is wrong.
    public struct Snapshot: Sendable {
        public let sessionId: String
        public let sessionDepth: Int
        public let pageviewId: String
        public let page: String?
        public let referrer: String?
    }

    @discardableResult
    public func trackScreenView(_ name: String) -> Snapshot {
        lock.lock(); defer { lock.unlock() }

        // We count tracking the same screen name twice in a row as a second screen view.
        // Returning to a feed (or triggering it again) is a new pageview with a new ad opportunity.
        _referrer = _page
        _page = name

        // ZERO-BASED, matching the web exactly: `config.js:397-418` assigns
        // `this.sessionDepth = parseInt(currSessDepth)` *before* writing the incremented value
        // back, so the first pageview of a session reports 0, the second 1, the third 2.
        //
        // The contract says session_depth is "screens this session, as web counts pageviews",
        // and the phrase reads like a 1-based count — it is not. Making this 1-based puts every
        // app session one ahead of every web session in a column both write, so any
        // app-versus-web comparison is silently off by one and nothing errors.
        if _hasTrackedScreen {
            _sessionDepth += 1
        } else {
            _hasTrackedScreen = true
        }

        _pageviewId = UUID().uuidString

        return Snapshot(
            sessionId: _sessionId,
            sessionDepth: _sessionDepth,
            pageviewId: _pageviewId,
            page: _page,
            referrer: _referrer
        )
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
