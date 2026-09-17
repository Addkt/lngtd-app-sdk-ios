#if os(iOS)
import Foundation
import LongitudeCore

/// Assembles the config layer. Exists so `Longitude.start` has one seam to inject
/// through, rather than hard-wiring a caches directory and a real URLSession into a
/// static function nobody can substitute.
public struct LongitudeConfiguration {

    /// Where the disk cache lives. Defaults to `<Caches>/com.lngtd.sdk/config/`.
    public var cacheDirectory: URL

    /// Per-caller budget for the one ad request per launch that may wait on config.
    /// The plan's default is 1.5s with a 3.0s hard cap, enforced by the coordinator.
    public var configTimeout: TimeInterval

    /// How often the event timer polls, in seconds. **Not** the flush interval: that is
    /// `LNGTDEventQueue`'s own 5000ms gate. Polling faster avoids two five-second gates in
    /// series silently doubling worst-case flush latency.
    public var tickInterval: TimeInterval

    /// Where events are sent. Exposed so the Demo app can simulate network failures.
    public var eventAPIURL: URL

    /// The fallback endpoint (`logging.js:256`). Configurable for the same reason as the
    /// primary: without it, exercising a failure path falls back onto production, so the very
    /// test meant to avoid touching the live collector posts to it.
    public var eventFallbackURL: URL

    /// The endpoint for payloads lacking an identifier. Configurable for the same reason
    /// as the primary.
    public var eventNonTrackingURL: URL

    /// The distance in points beyond the viewport to eagerly load slots.
    public var lazyLoadMarginPoints: Double

    public init(
        cacheDirectory: URL? = nil,
        configTimeout: TimeInterval = 1.5,
        tickInterval: TimeInterval = 1.0,
        lazyLoadMarginPoints: Double = 500.0,
        eventAPIURL: URL = URLSessionEventTransport.defaultPrimaryURL,
        eventFallbackURL: URL = URLSessionEventTransport.defaultFallbackURL,
        eventNonTrackingURL: URL = URLSessionEventTransport.defaultNonTrackingURL
    ) {
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
        self.configTimeout = configTimeout
        self.tickInterval = tickInterval
        self.lazyLoadMarginPoints = lazyLoadMarginPoints
        self.eventAPIURL = eventAPIURL
        self.eventFallbackURL = eventFallbackURL
        self.eventNonTrackingURL = eventNonTrackingURL
    }

    /// `Library/Caches/com.lngtd.sdk/config/`, resolved through FileManager rather than
    /// a hardcoded path.
    ///
    /// Falls back to the temporary directory if caches cannot be located — which should
    /// not happen on iOS, but returning a working temporary path degrades to "the cache
    /// does not survive relaunch" rather than to "the SDK cannot start".
    private static func defaultCacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let base = caches ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("com.lngtd.sdk", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
    }

    func makeStore(account: String, section: String) -> ConfigStore {
        let coordinator = ConfigFetchCoordinator(
            transport: URLSessionConfigTransport(),
            timeout: configTimeout
        )
        return ConfigStore(
            account: account,
            section: section,
            platform: "ios",
            diskStore: ConfigDiskStore(baseDirectory: cacheDirectory),
            bundledLoader: BundledConfigLoader(),
            fetcher: coordinator
        )
    }
}
#endif
