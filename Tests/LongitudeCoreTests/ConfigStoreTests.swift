import XCTest
@testable import LongitudeCore

// Fifteen behaviours of the composing tier in one suite. Splitting it would mean
// either duplicating the five fakes or promoting them out of file scope, both worse
// than the length. The rule earns its keep on production types, where a body this
// long is a genuine smell — so it is scoped to this declaration rather than
// disabled for the file.
// swiftlint:disable:next type_body_length
final class ConfigStoreTests: XCTestCase {

    private actor FakeFetcher: ConfigFetching {
        var outcome: ConfigFetchOutcome = .failed(.timeout)
        var delay: TimeInterval = 0
        var neverReturns = false
        var fetchCount = 0

        private var inFlightFetch: Task<ConfigFetchOutcome, Never>?

        func fetch(account: String, section: String, etag: String?) async -> ConfigFetchOutcome {
            if let task = inFlightFetch {
                return await task.value
            }

            let task = Task {
                fetchCount += 1
                if neverReturns {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                } else if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                return outcome
            }
            inFlightFetch = task
            let result = await task.value
            inFlightFetch = nil
            return result
        }

        func update(outcome: ConfigFetchOutcome, delay: TimeInterval = 0, neverReturns: Bool = false) {
            self.outcome = outcome
            self.delay = delay
            self.neverReturns = neverReturns
        }

        func getFetchCount() -> Int {
            return fetchCount
        }
    }

    private class FakeReporter: ConfigStoreReporting, @unchecked Sendable {
        private let lock = NSLock()
        var passthroughReasons: [String] = []
        var staleCount = 0

        func storeDidPassthrough(reason: String) {
            lock.lock()
            passthroughReasons.append(reason)
            lock.unlock()
        }

        func storeDidFlagStale() {
            lock.lock()
            staleCount += 1
            lock.unlock()
        }
    }

    private final class FakeDiskStore: ConfigDiskStoring, @unchecked Sendable {
        private let lock = NSLock()
        var recordToReturn: ConfigRecord?
        var writtenRecord: ConfigRecord?

        func read(account: String, section: String, platform: String) -> ConfigRecord? {
            lock.lock(); defer { lock.unlock() }
            return recordToReturn
        }

        func write(record: ConfigRecord, account: String, section: String, platform: String) {
            lock.lock(); defer { lock.unlock() }
            writtenRecord = record
        }
    }

    private final class FakeBundledLoader: BundledConfigLoading, @unchecked Sendable {
        private let lock = NSLock()
        var resultToReturn: BundledConfigLoader.Result?

        func load() -> BundledConfigLoader.Result? {
            lock.lock(); defer { lock.unlock() }
            return resultToReturn
        }
    }

    private class ActorClock: @unchecked Sendable {
        var time: TimeInterval = 0
    }

    private func makeConfigData(
        killSwitch: Bool = false, ttl: Int = 3600, error: Bool = false,
        platform: String = "ios", schema: Int = 1
    ) -> Data {
        let errorKey = error ? #" "_error": true,"# : ""
        let killSwitchKey = killSwitch ? #""features":{"killSwitch":true},"# : ""
        let json = """
        {
            "schema": \(schema),
            "platform": "\(platform)",
            "ttl": \(ttl),
            \(killSwitchKey)
            \(errorKey)
            "adUnits": {},
            "floors": {}
        }
        """
        return Data(json.utf8)
    }

    private func makeAppConfig(killSwitch: Bool = false, ttl: Int = 3600, error: Bool = false) throws -> AppConfig {
        let data = makeConfigData(killSwitch: killSwitch, ttl: ttl, error: error)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    // large_tuple is disabled for this one declaration rather than relaxed
    // globally. The rule guards against unclear API signatures; this is a
    // file-private fixture factory whose call sites name each element as they
    // destructure it. A six-element tuple in Sources should still fail review,
    // which is why the rule stays on.
    // swiftlint:disable:next large_tuple
    private func setupStore() -> (
        ConfigStore, FakeDiskStore, FakeBundledLoader,
        FakeFetcher, FakeReporter, ActorClock
    ) {
        let disk = FakeDiskStore()
        let bundled = FakeBundledLoader()
        let fetcher = FakeFetcher()
        let reporter = FakeReporter()
        let clock = ActorClock()

        let store = ConfigStore(
            account: "a",
            section: "s",
            platform: "ios",
            diskStore: disk,
            bundledLoader: bundled,
            fetcher: fetcher,
            clock: { clock.time },
            reporter: reporter
        )
        return (store, disk, bundled, fetcher, reporter, clock)
    }

    // 1. Resolution order
    func testResolutionOrder() async throws {
        let (store, disk, bundled, fetcher, _, clock) = setupStore()

        let memData = makeConfigData(ttl: 1)
        let memRecord = ConfigRecord(fetchedAt: 0, etag: "mem", payload: memData)
        await fetcher.update(outcome: .fetched(memRecord))

        let diskData = makeConfigData(ttl: 2)
        let diskRecord = ConfigRecord(fetchedAt: 0, etag: "disk", payload: diskData)

        let bundledConfig = try makeAppConfig(ttl: 3)
        let bundledResult = BundledConfigLoader.Result(config: bundledConfig, freshness: .staleUsable)

        // With no config, a fetch is performed and sets memory tier
        let c1 = await store.config(timeout: 0.1)
        XCTAssertEqual(c1?.ttl, 1)

        // With memory populated, it ignores disk and bundled
        disk.recordToReturn = diskRecord
        bundled.resultToReturn = bundledResult
        let c2 = await store.config(timeout: 0.1)
        XCTAssertEqual(c2?.ttl, 1)

        // Let's create a new store to test disk without memory
        let (store2, disk2, bundled2, _, _, _) = setupStore()
        disk2.recordToReturn = diskRecord
        bundled2.resultToReturn = bundledResult
        let c3 = await store2.config(timeout: 0.1)
        XCTAssertEqual(c3?.ttl, 2)

        // Let's create a new store to test bundled without disk or memory
        let (store3, _, bundled3, _, _, _) = setupStore()
        bundled3.resultToReturn = bundledResult
        let c4 = await store3.config(timeout: 0.1)
        XCTAssertEqual(c4?.ttl, 3)
    }

    // 2. prime() returns before the fetch completes
    func testPrimeReturnsBeforeFetchCompletes() async {
        let (store, _, _, fetcher, _, _) = setupStore()
        await fetcher.update(outcome: .failed(.timeout), delay: 0.5)

        let start = ProcessInfo.processInfo.systemUptime
        await store.prime() // Synchronous on the actor
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        XCTAssertLessThan(elapsed, 0.1, "prime() must not wait for fetch")

        // Wait for the async task to kick in
        try? await Task.sleep(nanoseconds: 600_000_000)
        let count = await fetcher.getFetchCount()
        XCTAssertEqual(count, 1)
    }

    // 3. config(timeout:) with a usable bundled config and a never-returning fetcher completes immediately
    func testConfigWithBundledDoesNotWaitAndNoGateHit() async throws {
        let (store, _, bundled, fetcher, _, _) = setupStore()
        bundled.resultToReturn = BundledConfigLoader.Result(config: try makeAppConfig(ttl: 3), freshness: .staleUsable)
        await fetcher.update(outcome: .failed(.timeout), neverReturns: true)

        let start = ProcessInfo.processInfo.systemUptime
        let c = await store.config(timeout: 2.0)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        XCTAssertLessThan(elapsed, 0.1, "Must not wait if local config is present")
        XCTAssertNotNil(c)
        let gateHits = await store.networkGateHitCount
        XCTAssertEqual(gateHits, 0, "Gate should not be hit if local config is present")
    }

    // 4. config(timeout:) with no local config waits and gate-hit increments
    func testConfigWithNoLocalWaitsAndGateHit() async {
        let (store, _, _, fetcher, _, _) = setupStore()
        await fetcher.update(outcome: .failed(.timeout), delay: 2.0)

        let start = ProcessInfo.processInfo.systemUptime
        let c = await store.config(timeout: 0.1)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        XCTAssertLessThan(elapsed, 0.5) // The wait should be capped by the timeout (0.1s)
        XCTAssertNil(c)
        let gateHits = await store.networkGateHitCount
        XCTAssertEqual(gateHits, 1)
    }

    // 5. fresh triggers no fetch; revalidate serves and triggers; staleUsable serves and flags stale
    func testFreshnessBehaviors() async {
        // test fresh
        let (store1, disk1, _, fetcher1, _, _) = setupStore()
        // Age 0 against ttl 3600 classifies as fresh, so no fetch may occur.
        disk1.recordToReturn = ConfigRecord(
            fetchedAt: 0, etag: "disk", payload: makeConfigData(ttl: 3600)
        )
        _ = await store1.config(timeout: 0.1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        var count = await fetcher1.getFetchCount()
        XCTAssertEqual(count, 0)

        // test revalidate
        let (store2, disk2, _, fetcher2, _, clock2) = setupStore()
        disk2.recordToReturn = ConfigRecord(fetchedAt: 0, etag: "disk", payload: makeConfigData(ttl: 3600))
        clock2.time = 4000 // Age > TTL but < 24h -> revalidate
        _ = await store2.config(timeout: 0.1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        count = await fetcher2.getFetchCount()
        XCTAssertEqual(count, 1)

        // test staleUsable
        let (store3, disk3, _, fetcher3, reporter3, clock3) = setupStore()
        disk3.recordToReturn = ConfigRecord(fetchedAt: 0, etag: "disk", payload: makeConfigData(ttl: 3600))
        clock3.time = 86500 // Age > 24h -> staleUsable
        _ = await store3.config(timeout: 0.1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        count = await fetcher3.getFetchCount()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(reporter3.staleCount, 1)
    }

    // 6. .fetched cacheable writes to disk; _error: true updates memory but not disk
    func testFetchedWritesDiskOnlyIfCacheable() async {
        let (store1, disk1, _, fetcher1, _, _) = setupStore()
        let goodRecord = ConfigRecord(fetchedAt: 0, etag: "ok", payload: makeConfigData(ttl: 3600, error: false))
        await fetcher1.update(outcome: .fetched(goodRecord))
        _ = await store1.config(timeout: 0.1)
        XCTAssertNotNil(disk1.writtenRecord)

        let (store2, disk2, _, fetcher2, _, _) = setupStore()
        let errorRecord = ConfigRecord(fetchedAt: 0, etag: "err", payload: makeConfigData(ttl: 0, error: true))
        await fetcher2.update(outcome: .fetched(errorRecord))
        let c = await store2.config(timeout: 0.1)
        XCTAssertNil(disk2.writtenRecord) // No write to disk
        XCTAssertNotNil(c) // Memory tier serves it
    }

    // 7. .notModified re-persists with refreshed fetchedAt
    func testNotModifiedRepersists() async {
        let (store, disk, _, fetcher, _, clock) = setupStore()
        // initial populate
        let record = ConfigRecord(fetchedAt: 0, etag: "etag", payload: makeConfigData(ttl: 3600))
        await fetcher.update(outcome: .fetched(record))
        _ = await store.config(timeout: 0.1)

        // Now trigger notModified
        clock.time = 4000 // revalidate
        await fetcher.update(outcome: .notModified)
        disk.writtenRecord = nil // reset

        _ = await store.config(timeout: 0.1)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(disk.writtenRecord?.fetchedAt, 4000)
        XCTAssertEqual(disk.writtenRecord?.etag, "etag")
        XCTAssertEqual(disk.writtenRecord?.payload, record.payload)
    }

    // 8. .failed leaves memory and disk untouched, serves previously good
    func testFailedOutcome() async {
        let (store, disk, _, fetcher, _, _) = setupStore()
        // prime with good record
        let record = ConfigRecord(fetchedAt: 0, etag: "etag", payload: makeConfigData(ttl: 3600))
        disk.recordToReturn = record
        _ = await store.config(timeout: 0.1)

        await fetcher.update(outcome: .failed(.invalidURL))
        disk.writtenRecord = nil
        let c2 = await store.config(timeout: 0.1)

        XCTAssertNil(disk.writtenRecord)
        XCTAssertEqual(c2?.ttl, 3600) // previously good config
    }

    // 9. .throttled reports nothing, serves what we have
    func testThrottledOutcome() async {
        let (store, disk, _, fetcher, reporter, _) = setupStore()
        let record = ConfigRecord(fetchedAt: 0, etag: "etag", payload: makeConfigData(ttl: 3600))
        disk.recordToReturn = record

        await fetcher.update(outcome: .throttled)
        let c = await store.config(timeout: 0.1)

        XCTAssertEqual(reporter.passthroughReasons.count, 0)
        XCTAssertEqual(c?.ttl, 3600)
    }

    // 10. Passthrough reasons
    func testPassthroughReasons() async {
        // no config
        let (store1, _, _, fetcher1, reporter1, _) = setupStore()
        await fetcher1.update(outcome: .failed(.invalidURL))
        _ = await store1.config(timeout: 0.1)
        XCTAssertEqual(reporter1.passthroughReasons, ["no_config"])

        // kill switch
        let (store2, disk2, _, _, reporter2, _) = setupStore()
        disk2.recordToReturn = ConfigRecord(fetchedAt: 0, etag: "ks", payload: makeConfigData(killSwitch: true))
        _ = await store2.config(timeout: 0.1)
        XCTAssertEqual(reporter2.passthroughReasons, ["kill_switch"])

        // unsupported schema
        let (store3, disk3, _, _, reporter3, _) = setupStore()
        disk3.recordToReturn = ConfigRecord(fetchedAt: 0, etag: "us", payload: makeConfigData(schema: 2))
        _ = await store3.config(timeout: 0.1)
        XCTAssertEqual(reporter3.passthroughReasons, ["unsupported_schema_or_platform"])

        // unsupported platform
        let (store4, disk4, _, _, reporter4, _) = setupStore()
        disk4.recordToReturn = ConfigRecord(fetchedAt: 0, etag: "up", payload: makeConfigData(platform: "android"))
        _ = await store4.config(timeout: 0.1)
        XCTAssertEqual(reporter4.passthroughReasons, ["unsupported_schema_or_platform"])
    }

    // 11a. The same reason arriving many times reports once.
    ///
    /// The plan is explicit that `config_failure` is once per reason per session and
    /// **not** per slot: a twenty-slot feed reporting per slot sends twenty copies of
    /// one fact to the collector.
    func testSameReasonReportedOnceAcrossManyCalls() async {
        let (store, _, _, fetcher, reporter, _) = setupStore()
        await fetcher.update(outcome: .failed(.invalidURL))

        for _ in 0..<20 {
            _ = await store.config(timeout: 0.1)
        }

        XCTAssertEqual(
            reporter.passthroughReasons, ["no_config"],
            "twenty slots must not produce twenty reports of the same reason"
        )
    }

    // 11b. Distinct reasons each report.
    func testDistinctReasonsEachReport() async {
        let (store, _, _, fetcher, reporter, _) = setupStore()

        await fetcher.update(outcome: .failed(.invalidURL))
        _ = await store.config(timeout: 0.1)

        let killSwitched = ConfigRecord(
            fetchedAt: 0, etag: "ks", payload: makeConfigData(killSwitch: true)
        )
        await fetcher.update(outcome: .fetched(killSwitched))
        _ = await store.config(timeout: 0.1)

        XCTAssertEqual(reporter.passthroughReasons, ["no_config", "kill_switch"])
    }

    /// A served config whose schema this SDK does not understand is passthrough with
    /// its own reason, not a generic failure — an operator needs to tell "the server
    /// sent something we cannot read" from "we have no config".
    ///
    /// Needs a store with nothing in memory: once a usable config is held, `config()`
    /// correctly serves it without fetching, so a later bad fetch is never reached.
    /// The earlier version of this test missed that and asserted a report that could
    /// not have happened.
    func testFetchedConfigWithUnsupportedSchemaReportsItsOwnReason() async {
        let (store, _, _, fetcher, reporter, _) = setupStore()
        await fetcher.update(
            outcome: .fetched(
                ConfigRecord(fetchedAt: 0, etag: "us", payload: makeConfigData(schema: 99))
            )
        )

        let config = await store.config(timeout: 0.1)

        XCTAssertNil(config, "an unreadable schema must not be served")
        XCTAssertEqual(reporter.passthroughReasons, ["unsupported_schema_or_platform"])
    }

    // 12. The chosen policy: a successful fetch clears the reported set, so a fault
    // that recovers and later returns is reported again rather than being invisible
    // for the rest of the process. The cost is that a flapping endpoint re-reports;
    // that is preferred to silently losing a recurrence.
    func testSuccessfulFetchClearsReportedReasonsSoARecurrenceIsVisible() async {
        let (store, _, _, fetcher, reporter, _) = setupStore()

        // Every config here uses ttl 0, so nothing is ever `fresh` and each call
        // revalidates in the background — which is how the sequence below gets to
        // exercise repeated outcomes at all.
        func good() -> ConfigRecord {
            ConfigRecord(fetchedAt: 0, etag: "ok", payload: makeConfigData(ttl: 0))
        }
        func killSwitched() -> ConfigRecord {
            ConfigRecord(fetchedAt: 0, etag: "ks", payload: makeConfigData(killSwitch: true, ttl: 0))
        }

        // 1. Nothing anywhere, fetch fails -> no_config.
        await fetcher.update(outcome: .failed(.invalidURL))
        _ = await store.config(timeout: 0.1)
        XCTAssertEqual(reporter.passthroughReasons, ["no_config"])

        // 2. Recover with a servable config. This is the success that clears the set.
        await fetcher.update(outcome: .fetched(good()))
        _ = await store.config(timeout: 0.1)

        // 3. A kill-switched config arrives -> kill_switch reported.
        await fetcher.update(outcome: .fetched(killSwitched()))
        _ = await store.config(timeout: 0.1)
        await store.awaitPendingRevalidation()
        XCTAssertEqual(reporter.passthroughReasons, ["no_config", "kill_switch"])

        // 4. Recover again, clearing the set a second time.
        await fetcher.update(outcome: .fetched(good()))
        _ = await store.config(timeout: 0.1)
        await store.awaitPendingRevalidation()

        // 5. The same kill switch returns. Because the set was cleared on recovery it
        // must be reported again rather than suppressed for the rest of the process.
        await fetcher.update(outcome: .fetched(killSwitched()))
        _ = await store.config(timeout: 0.1)
        await store.awaitPendingRevalidation()

        XCTAssertEqual(
            reporter.passthroughReasons, ["no_config", "kill_switch", "kill_switch"],
            "a reason recurring after a recovery must be reported again, not suppressed"
        )
    }

    // 13. Twenty concurrent config() callers receive the same config and cause one fetch
    func testConcurrentCallers() async {
        let (store, _, _, fetcher, _, _) = setupStore()
        let record = ConfigRecord(fetchedAt: 0, etag: "c", payload: makeConfigData(ttl: 999))
        await fetcher.update(outcome: .fetched(record), delay: 0.2)

        let tasks = (0..<20).map { _ in
            Task {
                await store.config(timeout: 1.0)
            }
        }

        var results: [AppConfig?] = []
        for task in tasks {
            results.append(await task.value)
        }

        for res in results {
            XCTAssertEqual(res?.ttl, 999)
        }

        let count = await fetcher.getFetchCount()
        XCTAssertEqual(count, 1)
    }
}
