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
                return validated(config)
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
