import Foundation

public protocol ConfigDiskStoring {
    func read(account: String, section: String, platform: String) -> ConfigRecord?
    func write(record: ConfigRecord, account: String, section: String, platform: String)
}
extension ConfigDiskStore: ConfigDiskStoring {}

public protocol BundledConfigLoading {
    func load() -> BundledConfigLoader.Result?
}
extension BundledConfigLoader: BundledConfigLoading {}

public enum ConfigStorePassthroughReason: String, Equatable, Sendable {
    case noConfig = "no_config"
    case killSwitch = "kill_switch"
    case unsupportedSchemaOrPlatform = "unsupported_schema_or_platform"
}

public protocol ConfigStoreReporting: AnyObject, Sendable {
    func storeDidPassthrough(reason: String)
    func storeDidFlagStale()
}

public actor ConfigStore {
    private let account: String
    private let section: String
    private let platform: String
    private let diskStore: ConfigDiskStoring
    private let bundledLoader: BundledConfigLoading
    private let fetcher: ConfigFetching
    private let clock: () -> TimeInterval
    private weak var reporter: ConfigStoreReporting?

    private var memoryRecord: ConfigRecord?
    private var memoryConfig: AppConfig?

    // We must track if the memory tier holds a bundled config.
    // If it does, its freshness is always `.staleUsable` and we shouldn't attempt to classify its age.
    private var backgroundRevalidation: Task<Void, Never>?
    private var isMemoryBundled: Bool = false

    /// Called whenever a config becomes the memory tier, carrying `account.sampleRate`.
    ///
    /// Exists because the sampling gate on `LNGTDEventQueue` is **synchronous** while this is an
    /// actor: the rate has to be pushed into a lock-guarded box the gate can read without
    /// awaiting. The closure must not call back into this store — it runs inside actor context,
    /// and re-entering from here is a deadlock.
    private var onSampleRateUpdate: (@Sendable (Double?) -> Void)?

    public func setOnSampleRateUpdate(_ closure: @escaping @Sendable (Double?) -> Void) {
        onSampleRateUpdate = closure
    }

    /// Takes an optional so callers do not need an `if let`, which is what pushed
    /// `handleFetchOutcome` past the cyclomatic complexity limit.
    private func notifySampleRate(of config: AppConfig?) {
        onSampleRateUpdate?(config?.account?.sampleRate)
    }

    public private(set) var passthroughReason: ConfigStorePassthroughReason?
    public private(set) var networkGateHitCount: Int = 0

    private var reportedPassthroughReasons: Set<String> = []

    public init(
        account: String,
        section: String,
        platform: String,
        diskStore: ConfigDiskStoring,
        bundledLoader: BundledConfigLoading,
        fetcher: ConfigFetching,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        reporter: ConfigStoreReporting? = nil
    ) {
        self.account = account
        self.section = section
        self.platform = platform
        self.diskStore = diskStore
        self.bundledLoader = bundledLoader
        self.fetcher = fetcher
        self.clock = clock
        self.reporter = reporter
    }

    /// Synchronous, never waits.
    public func prime() {
        let (resolution, _) = resolveLocalConfig()

        // If there's a usable config, check if it requires a fetch.
        // `fresh` -> no fetch. `revalidate` or `staleUsable` -> trigger fetch.
        let needsFetch: Bool
        if let res = resolution {
            needsFetch = (res.freshness != .fresh)
        } else {
            needsFetch = true
        }

        if needsFetch {
            spawnRevalidation(etag: resolution?.record?.etag)
        }
    }

    /// Fire-and-forget revalidation, with a handle kept purely so tests can await it.
    ///
    /// Nothing in production reads `backgroundRevalidation` — `prime()` and the
    /// `revalidate`/`staleUsable` paths must not wait, which is the whole point. But a
    /// test that asserts on what a background fetch reported would otherwise have to
    /// sleep and hope, and a sleeping test is a flaky test. Only the most recent handle
    /// is kept; that is sufficient for the tests that need it.
    private func spawnRevalidation(etag: String?) {
        backgroundRevalidation = Task { [weak self] in
            await self?.executeFetch(etag: etag)
        }
    }

    /// Test seam: waits for the most recently spawned background revalidation.
    /// Never call this from production code — it reintroduces exactly the blocking
    /// that `prime()` exists to avoid.
    func awaitPendingRevalidation() async {
        await backgroundRevalidation?.value
    }

    /// What the demo app's debug overlay reads, and what a publisher support ticket
    /// should quote. The plan specifies these fields, so they are API rather than
    /// something the overlay reaches in and computes for itself.
    public struct Diagnostics: Sendable, Equatable {
        /// The `version` string from the served config, if any.
        public let configVersion: String?
        /// Which tier answered. `nil` when nothing is held.
        public let source: Source?
        /// Age of the held record. `nil` for bundled config, which has no fetch time —
        /// and that nil is informative, not missing data.
        public let ageSeconds: TimeInterval?
        public let freshness: ConfigFreshness?
        public let passthroughReason: ConfigStorePassthroughReason?
        /// How often an ad request had to wait on the network because no tier could
        /// answer. The plan calls this a top-line SLO; it should be 0 in a healthy app.
        public let networkGateHits: Int

        public enum Source: String, Sendable, Equatable {
            case memory
            case disk
            case bundled
        }
    }

    public func diagnostics() -> Diagnostics {
        guard let config = memoryConfig else {
            return Diagnostics(
                configVersion: nil, source: nil, ageSeconds: nil, freshness: nil,
                passthroughReason: passthroughReason, networkGateHits: networkGateHitCount
            )
        }

        // `memory` is not reported as a source: by the time anything is in memory it
        // arrived from disk, the bundle or the network, and saying "memory" would hide
        // the fact that matters. Bundled is distinguished because its age is unknowable.
        let source: Diagnostics.Source = isMemoryBundled ? .bundled : .disk
        let age = isMemoryBundled ? nil : memoryRecord.map { clock() - $0.fetchedAt }
        let freshness = memoryRecord.map {
            ConfigFreshness.classify(
                fetchedAt: $0.fetchedAt, ttl: config.ttl,
                isError: config.isServerError, clock: clock
            )
        } ?? (isMemoryBundled ? ConfigFreshness.staleUsable : nil)

        return Diagnostics(
            configVersion: config.version,
            source: source,
            ageSeconds: age,
            freshness: freshness,
            passthroughReason: passthroughReason,
            networkGateHits: networkGateHitCount
        )
    }

    /// Geo for the floor ladder, resolved against the age of the config being served.
    ///
    /// This lives on the store because only the store knows **which tier answered**,
    /// and that changes the answer. A bundled config has no fetch time at all: its geo
    /// was baked in when the app was submitted, so it must always be treated as stale
    /// and fall back to the device region. A caller outside the store cannot tell the
    /// difference, and would silently use a build-time country for the floor ladder —
    /// which is worse than a wrong floor, because a mismatched country matches no floor
    /// key and sends every unit to baseFloor.
    public func geo(deviceRegion: String?) -> GeoFreshness {
        guard let config = memoryConfig else {
            return GeoFreshness.resolve(
                fetchedAt: staleGeoTimestamp, configCountry: nil,
                deviceRegion: deviceRegion, clock: clock
            )
        }

        // A bundled config carries no record, so there is no honest fetchedAt to use.
        let fetchedAt = isMemoryBundled ? staleGeoTimestamp
                                        : (memoryRecord?.fetchedAt ?? staleGeoTimestamp)

        return GeoFreshness.resolve(
            fetchedAt: fetchedAt, configCountry: config.geo?.country,
            deviceRegion: deviceRegion, clock: clock
        )
    }

    /// A day in the past — comfortably beyond the geo staleness threshold without
    /// hard-coding the threshold's own value here.
    private var staleGeoTimestamp: TimeInterval { clock() - 86_400 }

    /// May wait, but only when it has to.
    public func config(timeout: TimeInterval) async -> AppConfig? {
        let (resolution, decodeError) = resolveLocalConfig()

        if let res = resolution {
            // We have a local config. Handle freshness.
            switch res.freshness {
            case .fresh:
                break // serve as is
            case .revalidate:
                // serve immediately, revalidate in background
                spawnRevalidation(etag: res.record?.etag)
            case .staleUsable:
                // serve, flag stale, revalidate in background
                reporter?.storeDidFlagStale()
                spawnRevalidation(etag: res.record?.etag)
            }
            return validated(res.config)
        }

        if let decodeError = decodeError {
            reportPassthrough(reason: decodeError)
            return nil
        }

        // Nothing usable at all. We must wait up to timeout for the network gate.
        networkGateHitCount += 1

        let outcome = await fetchWithTimeout(etag: nil, timeout: timeout)
        return handleFetchOutcome(outcome)
    }

    private func fetchWithTimeout(etag: String?, timeout: TimeInterval) async -> ConfigFetchOutcome {
        let fetchTask = Task {
            await fetcher.fetch(account: account, section: section, etag: etag)
        }

        return await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)

            Task {
                let outcome = await fetchTask.value
                gate.resume(with: outcome)
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                gate.resume(with: .failed(.timeout))
            }
        }
    }

    private struct LocalResolution {
        let config: AppConfig
        let record: ConfigRecord?
        let freshness: ConfigFreshness
    }

    private func resolveLocalConfig() -> (LocalResolution?, ConfigStorePassthroughReason?) {
        // 1. Memory Tier
        if let config = memoryConfig {
            if isMemoryBundled {
                return (LocalResolution(config: config, record: nil, freshness: .staleUsable), nil)
            } else if let record = memoryRecord {
                let freshness = ConfigFreshness.classify(
                    fetchedAt: record.fetchedAt,
                    ttl: config.ttl,
                    isError: config.isServerError,
                    clock: clock
                )
                return (LocalResolution(config: config, record: record, freshness: freshness), nil)
            }
        }

        // 2. Disk Tier
        if let record = diskStore.read(account: account, section: section, platform: platform) {
            do {
                let config = try record.decodedPayload()
                let freshness = ConfigFreshness.classify(
                    fetchedAt: record.fetchedAt,
                    ttl: config.ttl,
                    isError: config.isServerError,
                    clock: clock
                )
                memoryConfig = config
                memoryRecord = record
                isMemoryBundled = false
                notifySampleRate(of: config)
                return (LocalResolution(config: config, record: record, freshness: freshness), nil)
            } catch AppConfig.AppConfigError.unsupportedSchema {
                return (nil, .unsupportedSchemaOrPlatform)
            } catch AppConfig.AppConfigError.unsupportedPlatform {
                return (nil, .unsupportedSchemaOrPlatform)
            } catch {
                // fallthrough
            }
        }

        // 3. Bundled Tier
        if let bundled = bundledLoader.load() {
            memoryConfig = bundled.config
            memoryRecord = nil
            isMemoryBundled = true
            notifySampleRate(of: bundled.config)
            return (LocalResolution(config: bundled.config, record: nil, freshness: bundled.freshness), nil)
        }

        return (nil, nil)
    }

    private func executeFetch(etag: String?) async {
        let outcome = await fetcher.fetch(account: account, section: section, etag: etag)
        _ = handleFetchOutcome(outcome)
    }

    private func handleFetchOutcome(_ outcome: ConfigFetchOutcome) -> AppConfig? {
        switch outcome {
        case .fetched(let record):
            do {
                let config = try record.decodedPayload()
                memoryRecord = record
                memoryConfig = config
                isMemoryBundled = false
                if config.isCacheable {
                    diskStore.write(record: record, account: account, section: section, platform: platform)
                }
                clearPassthrough()
                let validConfig = validated(config)
                notifySampleRate(of: validConfig)
                return validConfig
            } catch AppConfig.AppConfigError.unsupportedSchema {
                reportPassthrough(reason: .unsupportedSchemaOrPlatform)
                return nil
            } catch AppConfig.AppConfigError.unsupportedPlatform {
                reportPassthrough(reason: .unsupportedSchemaOrPlatform)
                return nil
            } catch {
                reportPassthrough(reason: .noConfig)
                return nil
            }

        case .notModified:
            if let existingRecord = memoryRecord, let config = memoryConfig, !isMemoryBundled {
                let updatedRecord = ConfigRecord(
                    fetchedAt: clock(),
                    etag: existingRecord.etag,
                    payload: existingRecord.payload
                )
                memoryRecord = updatedRecord
                if config.isCacheable {
                    diskStore.write(record: updatedRecord, account: account, section: section, platform: platform)
                }
                clearPassthrough()
                return validated(config)
            } else {
                // If we got notModified but have no local record, fallback to passthrough
                reportPassthrough(reason: .noConfig)
                return nil
            }

        case .throttled:
            // Fetch was throttled, try to return what we have
            if let config = memoryConfig {
                return validated(config)
            } else {
                reportPassthrough(reason: .noConfig)
                return nil
            }

        case .failed:
            // Fetch failed, do not modify disk or memory.
            if let config = memoryConfig {
                // We have a stale/usable config, return it.
                return validated(config)
            } else {
                reportPassthrough(reason: .noConfig)
                return nil
            }
        }
    }

    private func validated(_ config: AppConfig) -> AppConfig? {
        // Wiring LNGTDCircuitBreaker here in Phase 2g.
        if config.features?.killSwitch == true {
            reportPassthrough(reason: .killSwitch)
            return nil
        }
        clearPassthrough()
        return config
    }

    private func reportPassthrough(reason: ConfigStorePassthroughReason) {
        passthroughReason = reason
        let reasonString = reason.rawValue
        if !reportedPassthroughReasons.contains(reasonString) {
            reportedPassthroughReasons.insert(reasonString)
            reporter?.storeDidPassthrough(reason: reasonString)
        }
    }

    private func clearPassthrough() {
        passthroughReason = nil
        reportedPassthroughReasons.removeAll()
        // Note: A 6-hour app session should probably be allowed to re-report.
        // This session persistence model will need revisiting when 2e lands.
        // We choose to clear the reported set on success so a fault that recovers
        // and then returns is visible.
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ConfigFetchOutcome, Never>?

        init(_ continuation: CheckedContinuation<ConfigFetchOutcome, Never>) {
            self.continuation = continuation
        }

        func resume(with outcome: ConfigFetchOutcome) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: outcome)
        }
    }
}
