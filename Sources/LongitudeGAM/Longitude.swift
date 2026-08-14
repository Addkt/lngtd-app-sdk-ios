#if os(iOS)
import Foundation
import GoogleMobileAds
import LongitudeCore

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
    private static var startCalled = false

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

        let store = configuration.makeStore(account: accountId, section: section)
        let created = LongitudeEngine(store: store, section: section)
        engine = created
        created.startNonBlocking()

        let eventStoreDir = configuration.cacheDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("events", isDirectory: true)

        let eventStore = LNGTDEventStore(baseDirectory: eventStoreDir)
        let transport = URLSessionEventTransport(
            primaryURL: configuration.eventAPIURL,
            fallbackURL: configuration.eventFallbackURL
        )

        let createdPipeline = LNGTDEventPipeline(
            store: eventStore,
            transport: transport,
            backgroundHost: UIKitBackgroundTaskHost(),
            // 2e-6 replaces this with the real per-session decision from LNGTDSampling. It is a
            // required parameter precisely so that substitution cannot be forgotten silently.
            isSampled: { true },
            tickInterval: configuration.tickInterval
        )

        pipeline = createdPipeline
        observer = LNGTDLifecycleObserver(pipeline: createdPipeline)

        // Kicks the launch drain and installs the flush timer. Non-blocking.
        createdPipeline.start()

        if !waitsForATT {
            startAdSDK()
        }
    }

    /// Starts GMA. Call this after the ATT prompt resolves when `waitsForATT` was true.
    public static func startAdSDK() {
        MobileAds.shared.start(completionHandler: nil)
    }

    /// The `pageview` analogue. Inert until Phase 2e supplies the session model.
    public static func trackScreenView(_ name: String) {
        guard let engine else { return }
        Task { await engine.trackScreenView(name) }
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
}

private extension LongitudeEngine {
    /// `start()` is actor-isolated; this hops without making callers await.
    nonisolated func startNonBlocking() {
        Task { await self.start() }
    }
}
#endif
