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

    public init(cacheDirectory: URL? = nil, configTimeout: TimeInterval = 1.5) {
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
        self.configTimeout = configTimeout
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
