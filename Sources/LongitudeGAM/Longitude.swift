#if os(iOS)
import Foundation
import GoogleMobileAds
import UIKit
import LongitudeCore

private final class ConfigRateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _rate: Double?

    init(rate: Double?) {
        self._rate = rate
    }

    var rate: Double? {
        lock.lock(); defer { lock.unlock() }
        return _rate
    }

    func update(rate: Double?) {
        lock.lock(); defer { lock.unlock() }
        self._rate = rate
    }
}

private final class ConfigVersionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _version: String?

    init(version: String?) {
        self._version = version
    }

    var version: String? {
        lock.lock(); defer { lock.unlock() }
        return _version
    }

    func update(version: String?) {
        lock.lock(); defer { lock.unlock() }
        self._version = version
    }
}

/// The publisher-facing entry point. Replaces `MobileAds.shared.start()`.
///
/// A thin forwarder over `LongitudeEngine`, which holds the actual logic and is
/// testable on the host. Everything that needs a GMA type lives here; everything that
/// does not lives there, deliberately — this file can only be exercised in a simulator.
@MainActor
public enum Longitude {

    private static var engine: LongitudeEngine?
    private static var pipeline: LNGTDEventPipeline?
    private static var observer: LNGTDLifecycleObserver?
    public static var viewabilityObserver: LNGTDViewabilityObserver?
    private static var startCalled = false
    private static let samplingSalt = "LNGTDSample"

    private static var metadataProvider: LNGTDDeviceMetadataProvider?
    private static var metadataBox: LNGTDDeviceMetadataBox?

    private static var connectionMonitor: LNGTDConnectionMonitor?

    static var auctionGate: LNGTDAuctionGate?
    static var lazyLoadMarginPoints: Double = 0

    /// Refreshes device metadata (e.g. after the ATT prompt resolves).
    public static func refreshDeviceMetadata() {
        guard let provider = metadataProvider, let box = metadataBox else { return }
        box.update(metadata: provider.currentMetadata())
    }

    /// Starts the SDK. **Never blocks.**
    ///
    /// Loads disk and bundled config and kicks a network fetch without awaiting it, then
    /// starts GMA. Only the first ad request per launch can wait on config, and only up
    /// to `configTimeout`.
    ///
    /// - Parameter waitsForATT: When true, GMA is **not** started here — the caller must
    ///   call `startAdSDK()` once the ATT prompt has resolved. Starting GMA before ATT
    ///   completes means the first requests carry no IDFA and clear far lower, which is
    ///   the plan's fifth-largest risk and one publishers get wrong by default.
    public static func start(
        accountId: String,
        section: String,
        waitsForATT: Bool = false,
        configuration: LongitudeConfiguration = .init()
    ) {
        guard !startCalled else {
            // Idempotent: a publisher calling start() from both AppDelegate and a
            // SwiftUI App initialiser must not get two engines and two config stores.
            return
        }
        startCalled = true

        let provider = DefaultDeviceMetadataProvider()
        metadataProvider = provider
        let box = LNGTDDeviceMetadataBox(metadata: provider.currentMetadata())
        metadataBox = box

        auctionGate = LNGTDAuctionGate()
        lazyLoadMarginPoints = configuration.lazyLoadMarginPoints

        let store = configuration.makeStore(account: accountId, section: section)
        let created = LongitudeEngine(store: store, section: section)
        engine = created

        let bundledConfig = BundledConfigLoader().load()
        let rateBox = ConfigRateBox(rate: bundledConfig?.config.account?.sampleRate)
        let versionBox = ConfigVersionBox(version: bundledConfig?.config.version)

        Task {
            await store.setOnConfigUpdate { observation in
                rateBox.update(rate: observation.sampleRate)
                versionBox.update(version: observation.version)
            }
        }

        created.startNonBlocking()

        buildEventPipeline(
            configuration: configuration,
            metadataBox: box,
            rateBox: rateBox,
            versionBox: versionBox
        )

        if !waitsForATT {
            startAdSDK()
        }
    }

    /// Assembles the event layer and starts it.
    ///
    /// Split out of `start()`, which had grown past the function-length limit as each of 2e-1
    /// through 2f added a piece. Nothing here is conditional — it is one long construction — so
    /// the extraction is purely so `start()` reads as the sequence of subsystems it sets up.
    private static func buildEventPipeline(
        configuration: LongitudeConfiguration,
        metadataBox: LNGTDDeviceMetadataBox,
        rateBox: ConfigRateBox,
        versionBox: ConfigVersionBox
    ) {
        let eventStoreDir = configuration.cacheDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("events", isDirectory: true)

        let eventStore = LNGTDEventStore(baseDirectory: eventStoreDir)
        let transport = URLSessionEventTransport(
            primaryURL: configuration.eventAPIURL,
            fallbackURL: configuration.eventFallbackURL,
            nonTrackingURL: configuration.eventNonTrackingURL
        )

        let session = LNGTDSession()
        // A constant salt, not publisher-supplied: a publisher-chosen salt would make two apps'
        // sampling correlated or anticorrelated for no benefit.
        let sampler = LNGTDSampler(salt: Self.samplingSalt)

        let connectionMon = DefaultConnectionMonitor()
        connectionMonitor = connectionMon

        let createdPipeline = LNGTDEventPipeline(
            store: eventStore,
            transport: transport,
            backgroundHost: UIKitBackgroundTaskHost(),
            session: session,
            // A nil rate means no config has ever carried one. 1.0 is the deliberate direction:
            // over-sending is recoverable, under-sending silently deletes reporting.
            isSampled: { session.isSampled(sampler: sampler, sampleRate: rateBox.rate ?? 1.0) },
            metadata: { metadataBox.metadata },
            configVersion: { versionBox.version },
            connection: { connectionMon.currentConnection() },
            deviceType: UIDevice.current.userInterfaceIdiom == .pad ? .tablet : .phone,
            tickInterval: configuration.tickInterval
        )

        pipeline = createdPipeline
        observer = LNGTDLifecycleObserver(pipeline: createdPipeline)

        let tracker = LNGTDViewabilityTracker(
            queue: .main,
            trackViewableImpression: { [weak createdPipeline] unit in
                createdPipeline?.trackViewableImpression(unit: unit)
            }
        )
        viewabilityObserver = LNGTDViewabilityObserver(tracker: tracker)

        // Kicks the launch drain and installs the flush timer. Non-blocking.
        createdPipeline.start()
    }

    /// Starts GMA. Call this after the ATT prompt resolves when `waitsForATT` was true.
    public static func startAdSDK() {
        MobileAds.shared.start(completionHandler: nil)
    }

    /// The `pageview` analogue.
    public static func trackScreenView(_ name: String) {
        guard let pipeline else { return }
        pipeline.trackScreenView(name)
    }

    /// Enqueues a test event to verify the event pipeline before `trackScreenView` is wired.
    public static func enqueueTestEvent() {
        guard let pipeline else { return }
        let event = LNGTDEvent(
            event: .sdkInit,
            details: LNGTDEvent.Details(
                account: "demo",
                section: "app",
                deviceType: .phone,
                custom: LNGTDEventCustomDetails(platform: .ios)
            )
        )
        Task { await pipeline.queue.enqueue(event) }
    }

    /// Creates a banner for a slot. Fails only if `start` has not been called, which is a
    /// programming error the publisher can see immediately rather than a silent no-ad.
    public static func bannerView(slot: String) -> LNGTDBannerView? {
        guard let engine else { return nil }
        return LNGTDBannerView(slot: slot, engine: engine)
    }

    /// Config state for a debug overlay or a support ticket. Nil before `start`.
    ///
    /// Public because the plan's debug overlay needs exactly these fields, and an
    /// overlay that had to reach into internals would mean the SDK gives publishers no
    /// way to diagnose their own integration.
    public static func diagnostics() async -> ConfigStore.Diagnostics? {
        guard let engine else { return nil }
        return await engine.diagnostics()
    }

    /// Pipeline state for the debug overlay. Nil before `start`.
    public static func pipelineDiagnostics() async -> LNGTDEventPipeline.Diagnostics? {
        guard let pipeline else { return nil }
        return await pipeline.diagnostics()
    }

    /// Metadata state for the debug overlay. Nil before `start`.
    public static func metadataDiagnostics() -> LNGTDDeviceMetadata? {
        return metadataBox?.metadata
    }
}

private extension LongitudeEngine {
    /// `start()` is actor-isolated; this hops without making callers await.
    nonisolated func startNonBlocking() {
        Task { await self.start() }
    }
}
#endif
