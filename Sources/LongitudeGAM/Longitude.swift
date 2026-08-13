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
}

private extension LongitudeEngine {
    /// `start()` is actor-isolated; this hops without making callers await.
    nonisolated func startNonBlocking() {
        Task { await self.start() }
    }
}
#endif
