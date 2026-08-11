import Foundation

public actor LongitudeEngine {
    private let store: ConfigStore
    private let section: String
    private let floorResolver: FloorResolver
    private let clock: () -> TimeInterval
    private let deviceRegion: () -> String?

    public init(
        store: ConfigStore,
        section: String,
        floorResolver: FloorResolver = FloorResolver(),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        deviceRegion: @escaping () -> String? = { Locale.current.regionCode }
    ) {
        self.store = store
        self.section = section
        self.floorResolver = floorResolver
        self.clock = clock
        self.deviceRegion = deviceRegion
    }

    /// Primes the config layer and returns. Never waits on the network.
    ///
    /// The `Task` is an actor hop, not a fetch: `ConfigStore.prime()` resolves the local
    /// tiers and kicks its own background fetch without awaiting it.
    ///
    /// The ordering this relies on is worth stating, because it looks like a race and is
    /// not. `prime()` reads the disk, which is real I/O, so the caller returns before the
    /// memory tier is populated — and a publisher requesting a banner in `viewDidLoad`
    /// arrives milliseconds later. That would be a race if the two went to different
    /// places, but both are calls on the same `ConfigStore` actor: `prime()` is enqueued
    /// first and the actor runs its work serially, so the subsequent `config(timeout:)`
    /// cannot observe an unpopulated memory tier. Losing that ordering — by priming a
    /// copy, or moving the disk read off the actor — would reintroduce a network gate hit
    /// on cold launches that have a perfectly good cached config sitting on disk.
    public func start() {
        Task { await store.prime() }
    }

    /// Resolves how one slot should be served.
    ///
    /// `auctionId` is a parameter rather than minted here on purpose. The floor
    /// resolver memoises per `(uid, auctionId)` so that a slot re-resolved within one
    /// auction cannot disagree with itself; a fresh UUID per call makes that memo
    /// permanently inert *and* grows its cache by one entry per resolution, which over
    /// a refreshing session is unbounded. The caller owns the auction, so the caller
    /// supplies its id.
    ///
    /// - Parameter timeout: The caller's budget. Defaults to the plan's 1.5s
    ///   `configTimeout`; the store clamps it and, more importantly, ignores it
    ///   entirely when it already has something local to serve.
    public func resolve(
        slot: String,
        auctionId: String,
        deviceClass: String,
        sessionDepth: Int,
        timeout: TimeInterval = 1.5
    ) async -> SlotResolution {
        guard let config = await store.config(timeout: timeout) else {
            // The store returns nil for several distinct situations — no usable config,
            // a kill switch, a schema or platform it cannot read — and it already knows
            // which. Asking it beats guessing: reporting `.noConfig` for a kill-switched
            // account tells an operator the cache is broken when the truth is that
            // someone deliberately turned ads off.
            return .passthrough(await passthroughCause())
        }

        // No kill-switch check here: `config(timeout:)` has already withheld a
        // kill-switched config, so this is unreachable, and a second check would look
        // load-bearing while never firing.

        guard let adUnit = config.adUnits[slot] else {
            return .passthrough(.unknownSlot)
        }

        guard !adUnit.gamPath.isEmpty else {
            return .passthrough(.invalidGamPath)
        }

        var resolvedRefreshSeconds: Int?
        if let slotRefresh = adUnit.refresh?.seconds {
            resolvedRefreshSeconds = slotRefresh
        } else if case .object(let dict) = config.features?.refresh,
                  case .number(let defaultRefresh) = dict["seconds"] {
            resolvedRefreshSeconds = Int(defaultRefresh)
        }

        // The store resolves geo, because only it knows whether the config being
        // served came from the bundle — whose geo is build-time and always stale.
        let geoFreshness = await store.geo(deviceRegion: deviceRegion())

        let floorsMap: FloorsMap
        if let entries = config.floors[adUnit.uid] {
            floorsMap = .entries(entries)
        } else {
            floorsMap = .missing
        }

        let dynamicParams: DynamicParametersState
        if let params = adUnit.dynamicFloorParameters {
            dynamicParams = .valid(params)
        } else {
            dynamicParams = .missing
        }

        let floorRequest = FloorRequest(
            auctionId: auctionId,
            platform: config.platform,
            country: geoFreshness.country,
            deviceClass: deviceClass,
            section: section,
            sessionDepth: sessionDepth,
            uid: adUnit.uid,
            baseFloor: adUnit.baseFloor,
            dynamicFloorsEnabled: config.account?.dynamicFloorsEnabled ?? false,
            dynamicFloorParameters: dynamicParams,
            floors: floorsMap
        )

        let resolvedFloor = floorResolver.resolve(floorRequest)

        let plan = LongitudeSlotPlan(
            gamPath: adUnit.gamPath,
            sizes: adUnit.sizes,
            resolvedFloor: resolvedFloor,
            uid: adUnit.uid,
            refreshSeconds: resolvedRefreshSeconds,
            lazyLoad: adUnit.lazyLoad ?? false
        )

        return .longitude(plan)
    }

    /// The `pageview` analogue.
    ///
    /// Deliberately inert. The session model this feeds — `pageview_id`,
    /// `session_depth`, `referrer_url` and the 30-minute background timeout — is Phase
    /// 2e, and inventing a partial version here would mean two session models to
    /// reconcile later. The API exists now so publisher integration code does not have
    /// to change when 2e lands.
    public func trackScreenView(_ name: String) {
        _ = name
    }

    /// Maps the store's reason for withholding a config onto a passthrough cause.
    private func passthroughCause() async -> PassthroughCause {
        switch await store.passthroughReason {
        case .killSwitch: return .killSwitch
        case .unsupportedSchemaOrPlatform: return .unsupportedConfig
        case .noConfig: return .noConfig
        // Nil means the store withheld a config without recording why, which should not
        // happen; treat it as no config rather than inventing a cause.
        case nil: return .noConfig
        }
    }
}
