import Foundation
import XCTest
@testable import LongitudeCore

final class SlotResolutionTests: XCTestCase {

    private final class FakeDiskStore: ConfigDiskStoring, @unchecked Sendable {
        var recordToReturn: ConfigRecord?
        func read(account: String, section: String, platform: String) -> ConfigRecord? { recordToReturn }
        func write(record: ConfigRecord, account: String, section: String, platform: String) {}
    }

    private final class FakeBundledLoader: BundledConfigLoading, @unchecked Sendable {
        func load() -> BundledConfigLoader.Result? { nil }
    }

    /// `neverReturns` is set at init rather than assigned afterwards: the fake is an
    /// actor, so mutating it from a synchronous setup helper is not allowed, and making
    /// the helper async just to flip one flag would ripple through every test.
    private actor FakeFetcher: ConfigFetching {
        private let neverReturns: Bool
        private(set) var called = false

        init(neverReturns: Bool = false) {
            self.neverReturns = neverReturns
        }

        func wasCalled() -> Bool { called }

        func fetch(account: String, section: String, etag: String?) async -> ConfigFetchOutcome {
            called = true
            if neverReturns {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
            return .failed(.timeout)
        }
    }

    private func makeConfigData(
        killSwitch: Bool = false,
        slotName: String = "test_slot",
        uid: String = "u_test",
        gamPath: String = "/1234/test",
        sizes: String = "[[320, 50]]",
        slotRefresh: Int? = nil,
        accountRefresh: Int? = nil,
        baseFloor: String = "null",
        floorsJson: String = "{}"
    ) -> Data {
        let ksStr = killSwitch ? "true" : "false"
        let refreshStr = slotRefresh.map { "{\"seconds\": \($0)}" } ?? "null"
        let accRefreshStr = accountRefresh.map { "{\"seconds\": \($0)}" } ?? "null"

        let json = """
        {
            "schema": 1,
            "platform": "ios",
            "ttl": 3600,
            "geo": { "country": "us" },
            "account": { "name": "test_account", "dynamicFloorsEnabled": true },
            "features": {
                "killSwitch": \(ksStr),
                "refresh": \(accRefreshStr)
            },
            "adUnits": {
                "\(slotName)": {
                    "uid": "\(uid)",
                    "gamPath": "\(gamPath)",
                    "sizes": \(sizes),
                    "baseFloor": \(baseFloor),
                    "refresh": \(refreshStr)
                }
            },
            "floors": {
                "\(uid)": \(floorsJson)
            }
        }
        """
        return Data(json.utf8)
    }

    private func setupEngine(
        record: ConfigRecord?,
        fetcherNeverReturns: Bool = false
    ) -> (LongitudeEngine, ConfigStore) {
        let disk = FakeDiskStore()
        disk.recordToReturn = record

        let bundled = FakeBundledLoader()
        let fetcher = FakeFetcher(neverReturns: fetcherNeverReturns)

        let store = ConfigStore(
            account: "a",
            section: "s",
            platform: "ios",
            diskStore: disk,
            bundledLoader: bundled,
            fetcher: fetcher,
            clock: { 0 }
        )

        let engine = LongitudeEngine(
            store: store,
            section: "s",
            floorResolver: FloorResolver(),
            clock: { 0 },
            deviceRegion: { "uk" } // fallback country
        )

        return (engine, store)
    }

    // 1. A slot present in the config resolves to .longitude with gamPath, uid and sizes.
    // Assert the uid is the value's uid, not the slot key.
    func testResolve_PresentSlot_ReturnsLongitudePlan() async {
        let data = makeConfigData(slotName: "home", uid: "u_home", gamPath: "/path", sizes: "[[300, 250]]")
        let record = ConfigRecord(fetchedAt: 0, etag: "tag", payload: data)
        let (engine, _) = setupEngine(record: record)

        let resolution = await engine.resolve(slot: "home", auctionId: "a1", deviceClass: "phone", sessionDepth: 1)

        guard case .longitude(let plan) = resolution else {
            XCTFail("Expected .longitude, got \(resolution)")
            return
        }
        XCTAssertEqual(plan.gamPath, "/path")
        XCTAssertEqual(plan.uid, "u_home") // Assert uid is ad unit's uid, not "home"
        XCTAssertEqual(plan.sizes, [[300, 250]])
    }

    // 2. A slot absent from an otherwise valid config resolves to .passthrough(.unknownSlot).
    // Assert distinct from .noConfig.
    func testResolve_AbsentSlot_ReturnsUnknownSlot() async {
        let data = makeConfigData(slotName: "home")
        let record = ConfigRecord(fetchedAt: 0, etag: "tag", payload: data)
        let (engine, _) = setupEngine(record: record)

        let resolution = await engine.resolve(slot: "other", auctionId: "a1", deviceClass: "phone", sessionDepth: 1)

        XCTAssertEqual(resolution, .passthrough(.unknownSlot))
        XCTAssertNotEqual(PassthroughCause.unknownSlot, PassthroughCause.noConfig)
    }

    // 3. killSwitch resolves every slot to passthrough with the kill-switch cause.
    func testResolve_KillSwitch_ReturnsKillSwitch() async {
        let data = makeConfigData(killSwitch: true, slotName: "home")
        let record = ConfigRecord(fetchedAt: 0, etag: "tag", payload: data)
        let (engine, _) = setupEngine(record: record)

        let resolution = await engine.resolve(slot: "home", auctionId: "a1", deviceClass: "phone", sessionDepth: 1)

        XCTAssertEqual(resolution, .passthrough(.killSwitch))
    }

    // 4. No config at all resolves to passthrough with the no-config cause.
    func testResolve_NoConfig_ReturnsNoConfig() async {
        let (engine, _) = setupEngine(record: nil)

        let resolution = await engine.resolve(slot: "home", auctionId: "a1", deviceClass: "phone", sessionDepth: 1)

        XCTAssertEqual(resolution, .passthrough(.noConfig))
    }

    // 5. An ad unit with an empty or missing gamPath is passthrough with its own cause.
    func testResolve_EmptyGamPath_ReturnsInvalidGamPath() async {
        let data = makeConfigData(slotName: "home", gamPath: "")
        let record = ConfigRecord(fetchedAt: 0, etag: "tag", payload: data)
        let (engine, _) = setupEngine(record: record)

        let resolution = await engine.resolve(slot: "home", auctionId: "a1", deviceClass: "phone", sessionDepth: 1)

        XCTAssertEqual(resolution, .passthrough(.invalidGamPath))
    }

    // 6. Refresh: per-slot wins over account default; account default applies when slot omits; both absent yields nil.
    /// Resolves `test_slot` and returns the plan, or nil if it came back passthrough.
    private func planFor(
        slotRefresh: Int?, accountRefresh: Int?
    ) async -> LongitudeSlotPlan? {
        let data = makeConfigData(slotRefresh: slotRefresh, accountRefresh: accountRefresh)
        let record = ConfigRecord(fetchedAt: 0, etag: "t", payload: data)
        let (engine, _) = setupEngine(record: record)
        let resolution = await engine.resolve(
            slot: "test_slot", auctionId: "a1", deviceClass: "phone", sessionDepth: 1
        )
        guard case .longitude(let plan) = resolution else { return nil }
        return plan
    }

    func testResolve_Refresh_Hierarchy() async {
        let slotWins = await planFor(slotRefresh: 15, accountRefresh: 30)
        XCTAssertEqual(slotWins?.refreshSeconds, 15, "the per-slot value must win")

        let accountDefault = await planFor(slotRefresh: nil, accountRefresh: 30)
        XCTAssertEqual(
            accountDefault?.refreshSeconds, 30,
            "the account default applies when the slot omits one"
        )

        let neither = await planFor(slotRefresh: nil, accountRefresh: nil)
        let plan = await planFor(slotRefresh: nil, accountRefresh: nil)
        XCTAssertNotNil(plan, "the slot must still resolve without any refresh setting")
        XCTAssertNil(
            neither?.refreshSeconds,
            "no refresh configured must be nil, not 0 — a 0 would mean refresh immediately"
        )
    }

    // 7. FloorRequest is assembled with uppercase country, passed-through deviceClass and sessionDepth, uid, baseFloor.
    func testResolve_FloorRequest_Assembly() async {
        let floorsJson = """
        {
            "ios_US_phone_s_B": 1.25,
            "default": 0.5
        }
        """
        // configCountry is "us". It should be uppercased to "US" by GeoFreshness.
        // deviceClass "phone", section "s", sessionDepth 1 -> bucket "B".
        // Match key: ios_US_phone_s_B -> 1.25.

        let data = makeConfigData(uid: "u1", baseFloor: "0.25", floorsJson: floorsJson)
        let record = ConfigRecord(fetchedAt: 0, etag: "tag", payload: data)
        let (engine, _) = setupEngine(record: record)

        let resolution = await engine.resolve(slot: "test_slot", auctionId: "a1", deviceClass: "phone", sessionDepth: 1)

        guard case .longitude(let plan) = resolution else {
            return XCTFail("Expected longitude")
        }
        // If all fields were assembled correctly, the resolver will return the exact tier match.
        XCTAssertEqual(plan.resolvedFloor, .value(1.25))
    }

    // 8. A slot whose floors entry resolves to nothing still produces a .longitude plan.
    func testResolve_NoFloor_ProducesLongitudePlan() async {
        // No matching tier, and baseFloor is null/missing -> .noFloor
        let data = makeConfigData(baseFloor: "null", floorsJson: "{}")
        let record = ConfigRecord(fetchedAt: 0, etag: "tag", payload: data)
        let (engine, _) = setupEngine(record: record)

        let resolution = await engine.resolve(slot: "test_slot", auctionId: "a1", deviceClass: "phone", sessionDepth: 1)

        guard case .longitude(let plan) = resolution else {
            return XCTFail("Expected longitude")
        }
        XCTAssertEqual(plan.resolvedFloor, .noFloor)
    }

    // 9. start() returns without waiting.
    func testStart_ReturnsWithoutWaiting() async {
        let (engine, _) = setupEngine(record: nil, fetcherNeverReturns: true)

        let start = Date()
        await engine.start()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.1, "start() should not block")
    }

    // 10. resolve on a store holding a usable config returns without waiting, even with a fetcher that never returns.
    func testResolve_WithUsableConfig_ReturnsWithoutWaiting() async {
        let data = makeConfigData()
        let record = ConfigRecord(fetchedAt: 0, etag: "tag", payload: data)
        let (engine, _) = setupEngine(record: record, fetcherNeverReturns: true)

        let start = Date()
        let resolution = await engine.resolve(slot: "test_slot", auctionId: "a1", deviceClass: "phone", sessionDepth: 1)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.1, "resolve() should not block when config is usable")
        guard case .longitude = resolution else {
            return XCTFail("Expected longitude")
        }
    }

    /// A schema this SDK cannot read is its own cause, not `noConfig`.
    ///
    /// `ConfigStore.config(timeout:)` returns nil for several distinct situations and
    /// only the store knows which, so the engine asks it rather than assuming. Before
    /// that mapping existed, a kill-switched account reported `noConfig` — telling an
    /// operator the cache was broken when someone had deliberately turned ads off.
    func testResolve_UnsupportedSchema_ReturnsUnsupportedConfig() async {
        let json = """
        {
            "schema": 99,
            "platform": "ios",
            "ttl": 3600,
            "adUnits": {},
            "floors": {}
        }
        """
        let record = ConfigRecord(fetchedAt: 0, etag: "t", payload: Data(json.utf8))
        let (engine, _) = setupEngine(record: record)

        let resolution = await engine.resolve(
            slot: "home", auctionId: "a1", deviceClass: "phone", sessionDepth: 1
        )

        XCTAssertEqual(resolution, .passthrough(.unsupportedConfig))
        XCTAssertNotEqual(PassthroughCause.unsupportedConfig, PassthroughCause.noConfig)
    }

    /// All five causes are distinct values. A cause that silently equals another is
    /// worse than no cause at all, because the collector would report it confidently.
    func testAllPassthroughCausesAreDistinct() {
        let causes: [PassthroughCause] = [
            .noConfig, .killSwitch, .unknownSlot, .invalidGamPath, .unsupportedConfig
        ]
        for (index, cause) in causes.enumerated() {
            for other in causes[(index + 1)...] {
                XCTAssertNotEqual(cause, other, "\(cause) and \(other) must be distinct")
            }
        }
    }
}
