#if os(iOS)
import Foundation
import GoogleMobileAds
import LongitudeCore
import UIKit

private final class DummyDemandFetcher: LNGTDDemandFetching, @unchecked Sendable {
    func fetchDemand(completion: @escaping @Sendable (LNGTDAuctionOutcome, [String: String]?, Double?) -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            completion(.noBids, nil, nil)
        }
    }
    func stopAutoRefresh() {}
}

/// A banner slot. Drop-in replacement for `AdManagerBannerView`.
///
/// **Wrap-and-forward, not subclass.** Subclassing `AdManagerBannerView` would mean
/// intercepting `delegate`, `paidEventHandler` and `appEventDelegate` — publisher-owned
/// properties on a binary ObjC class whose internals move between minor versions.
/// Wrapping gives natural ownership of those, and `gamBannerView` as an escape hatch
/// for anything this type does not cover.
///
/// `@MainActor` throughout: GMA's delegate methods are `NS_SWIFT_UI_ACTOR` and its view
/// work is main-thread-only, so isolating the whole type is simpler and safer than
/// hopping per call.
@MainActor
public final class LNGTDBannerView: UIView {

    // MARK: - Publisher-facing surface

    /// The publisher's own GAM ad unit path.
    ///
    /// Kept writable and **strongly recommended** in the docs, because it is the
    /// passthrough fallback: with no usable config, a kill switch, or an unknown slot
    /// name, this is the only thing that lets the slot still serve. A publisher who
    /// leaves it nil gets no ad at all in exactly the situations where Longitude has
    /// least to offer.
    public var adUnitID: String? {
        didSet { gamBanner.adUnitID = adUnitID }
    }

    /// Sizes the publisher is willing to accept. Used verbatim on the passthrough path;
    /// on the Longitude path the config's sizes take precedence when it provides any.
    public var validAdSizes: [AdSize] = [AdSizeBanner] {
        didSet { applyValidAdSizes(validAdSizes) }
    }

    public weak var rootViewController: UIViewController? {
        didSet { gamBanner.rootViewController = rootViewController }
    }

    public weak var delegate: LNGTDBannerViewDelegate?

    /// Per-impression revenue, straight from GMA.
    ///
    /// Forwarded verbatim to the publisher. Phase 2e also emits `paid_event` from here —
    /// the highest-value mobile-only event in the plan, since it closes the floor
    /// optimisation loop without waiting on a GAM report.
    public var paidEventHandler: ((AdValue) -> Void)?

    /// The wrapped GMA view, for APIs this type does not surface. Read-only: handing out
    /// a settable reference would let a caller reassign `delegate` and silently sever
    /// every callback below.
    public var gamBannerView: AdManagerBannerView { gamBanner }

    /// The publisher-facing slot name, as authored in the config.
    public let slot: String

    /// Whether the most recent load served through Longitude or fell back to GMA
    /// directly, and why. Phase 2e tags subsequent events with this.
    public private(set) var passthroughCause: PassthroughCause?

    /// The plan the most recent load resolved to, or nil if it went passthrough. Read by
    /// the demo app's debug overlay to show the resolved floor and gamPath per slot.
    public private(set) var lastPlan: LongitudeSlotPlan?

    /// Exposes the current load state (waiting, gated, auctioning) for the debug overlay.
    public private(set) var debugLoadState: String = "idle"

    /// Fires after each load resolves, so an overlay can refresh without polling.
    public var onResolution: ((SlotResolution) -> Void)?

    // MARK: - Internals

    private let gamBanner = AdManagerBannerView()
    private let engine: LongitudeEngine
    private let deviceClass: String

    private lazy var slotController: LNGTDSlotController = {
        let runner = LNGTDAuctionRunner(
            fetcher: DummyDemandFetcher(),
            timeout: 1.5
        )
        let controller = LNGTDSlotController(runner: runner)
        controller.delegate = self
        return controller
    }()

    private var currentPermit: LNGTDAuctionGateRelease?
    private var pendingRequest: AdManagerRequest?

    /// Guards against a delegate callback arriving for a load we have already replaced.
    private var loadGeneration: UInt64 = 0

    /// - Parameter deviceClass: Overridable for tests. Resolved inside the initialiser
    ///   rather than as a default argument, because default arguments are evaluated in a
    ///   nonisolated context and `currentDeviceClass()` needs the main actor.
    public init(
        slot: String,
        engine: LongitudeEngine,
        deviceClass: String? = nil
    ) {
        self.slot = slot
        self.engine = engine
        self.deviceClass = deviceClass ?? Self.currentDeviceClass()
        super.init(frame: .zero)

        addSubview(gamBanner)
        gamBanner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            gamBanner.topAnchor.constraint(equalTo: topAnchor),
            gamBanner.bottomAnchor.constraint(equalTo: bottomAnchor),
            gamBanner.leadingAnchor.constraint(equalTo: leadingAnchor),
            gamBanner.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // We own the GMA delegate. The publisher's delegate is a separate property that
        // we forward to, so their assignment can never displace ours.
        gamBanner.delegate = self
        gamBanner.paidEventHandler = { [weak self] value in
            self?.paidEventHandler?(value)
            // Phase 2e: emit `paid_event` here.
        }
        applyValidAdSizes(validAdSizes)
    }

    /// Returns nil rather than trapping.
    required init?(coder: NSCoder) {
        return nil
    }

    // MARK: - Loading

    /// Requests an ad for this slot.
    ///
    /// Returns immediately. Resolution may need to wait on config — bounded by the
    /// store, which does not wait at all when it has something local — so the actual
    /// GMA request happens after an `await`. That matches GMA's own contract, where
    /// `load` is asynchronous and results arrive via the delegate.
    public func load(_ request: AdManagerRequest = AdManagerRequest()) {
        releasePermit()

        loadGeneration &+= 1

        guard let copied = request.copy() as? AdManagerRequest else { return }
        self.pendingRequest = copied

        slotController.load(existingTargeting: copied.customTargeting)
    }

    public override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview == nil {
            Longitude.viewabilityObserver?.deregister(view: self)
            teardown()
        }
    }

    private func teardown() {
        // Bump the generation, or every in-flight continuation survives teardown.
        //
        // The lazy-load wait is a 250ms `asyncAfter` that re-schedules itself and stops only on
        // a generation mismatch. A banner scrolled out of a reused cell is detached but still
        // retained, so the geometry check keeps saying "not near the viewport" and the poll keeps
        // rearming — 4Hz, forever, for every banner the app has ever created. The same bump
        // discards the floor resolution and permit callbacks for a load nobody is waiting on.
        loadGeneration &+= 1
        releasePermit()
        slotController.teardown()
    }

    private func releasePermit() {
        currentPermit?.release()
        currentPermit = nil
    }

    private func applyPlan(_ plan: LongitudeSlotPlan) {
        gamBanner.adUnitID = plan.gamPath

        if let sizes = plan.sizes, !sizes.isEmpty {
            let converted = sizes.compactMap(Self.adSize(from:))
            if !converted.isEmpty {
                applyValidAdSizes(converted)
            }
        }
    }

    private func applyValidAdSizes(_ sizes: [AdSize]) {
        gamBanner.validAdSizes = sizes.map { nsValue(for: $0) }
        if let first = sizes.first {
            gamBanner.adSize = first
        }
    }

    private static func adSize(from pair: [Int]) -> AdSize? {
        guard pair.count == 2, pair[0] > 0, pair[1] > 0 else { return nil }
        let size = adSizeFor(cgSize: CGSize(width: pair[0], height: pair[1]))
        guard isAdSizeValid(size: size) else { return nil }
        return size
    }

    public static func currentDeviceClass() -> String {
        UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone"
    }

    public override var intrinsicContentSize: CGSize {
        cgSize(for: gamBanner.adSize)
    }

    private func waitAndAcquire(resolution: SlotResolution, generation: UInt64) {
        guard let plan = resolution.plan else {
            slotController.provideResolution(resolution)
            return
        }

        if plan.lazyLoad {
            let margin = Longitude.lazyLoadMarginPoints
            let snapshot = LNGTDViewSnapshotBuilder.compute(for: self)

            if !LNGTDLazyLoad.shouldLoad(snapshot: snapshot, marginPoints: margin) {
                self.debugLoadState = "waiting"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self = self, self.loadGeneration == generation else { return }
                    self.waitAndAcquire(resolution: resolution, generation: generation)
                }
                return
            }
        }

        guard let gate = Longitude.auctionGate else {
            self.debugLoadState = "auctioning"
            slotController.provideResolution(resolution)
            return
        }

        self.debugLoadState = "gated"
        let release = LNGTDAuctionGateRelease(host: gate)
        // Held from now, not from the moment the permit is granted.
        //
        // Assigning this inside `onAcquire` left `currentPermit` nil for the whole queued
        // window, so a slot scrolled away while waiting had nothing to release and stayed in the
        // queue. LIFO then hands it a turn ahead of live slots, and it burns that turn
        // discovering it is dead. Owning the release up front means teardown cancels the queue
        // entry instead.
        self.currentPermit = release
        let token = gate.acquire { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.loadGeneration == generation else {
                    release.release()
                    return
                }
                self.debugLoadState = "auctioning"
                self.currentPermit = release
                self.slotController.provideResolution(resolution)
            }
        }
        release.arm(token)
    }
}

extension SlotResolution {
    var plan: LongitudeSlotPlan? {
        if case .longitude(let plan) = self { return plan }
        return nil
    }
}

// MARK: - LNGTDSlotControllerDelegate
extension LNGTDBannerView: LNGTDSlotControllerDelegate {
    public func resolveFloor(auctionId: String) {
        let generation = self.loadGeneration
        Task { [weak self] in
            guard let self else { return }

            let resolution = await self.engine.resolve(
                slot: self.slot,
                auctionId: auctionId,
                deviceClass: self.deviceClass,
                sessionDepth: 0
            )

            guard generation == self.loadGeneration else { return }

            switch resolution {
            case .longitude(let plan):
                self.applyPlan(plan)
                self.passthroughCause = nil
                self.lastPlan = plan
            case .passthrough(let cause):
                self.passthroughCause = cause
                self.lastPlan = nil
            }

            self.onResolution?(resolution)
            self.waitAndAcquire(resolution: resolution, generation: generation)
        }
    }

    public func requestGAM(plan: LongitudeSlotPlan, auctionId: String, targeting: [String: Any]) {
        releasePermit()
        guard let request = pendingRequest else { return }
        request.customTargeting = targeting
        gamBanner.load(request)
    }

    public func emitBid(auctionId: String, late: Bool) {
        // Phase 2e will implement bid emission.
    }

    public func emitPassthrough(cause: PassthroughCause, targeting: [String: Any]) {
        releasePermit()
        guard let request = pendingRequest else { return }
        request.customTargeting = targeting
        gamBanner.load(request)
    }

    public func emitFailure(_ failure: LNGTDSlotFailure) {
        releasePermit()
    }
}

// MARK: - BannerViewDelegate forwarding

extension LNGTDBannerView: BannerViewDelegate {
    public func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        invalidateIntrinsicContentSize()
        slotController.gamLoaded()
        delegate?.bannerViewDidReceiveAd(self)
    }

    public func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        slotController.gamFailed()
        delegate?.bannerView(self, didFailToReceiveAdWithError: error)
    }

    public func bannerViewDidRecordImpression(_ bannerView: BannerView) {
        Longitude.viewabilityObserver?.register(view: self, unit: slot)
        slotController.impressionRecorded()
        delegate?.bannerViewDidRecordImpression(self)
    }

    public func bannerViewDidRecordClick(_ bannerView: BannerView) {
        delegate?.bannerViewDidRecordClick(self)
    }

    public func bannerViewWillPresentScreen(_ bannerView: BannerView) {
        delegate?.bannerViewWillPresentScreen(self)
    }

    public func bannerViewWillDismissScreen(_ bannerView: BannerView) {
        delegate?.bannerViewWillDismissScreen(self)
    }

    public func bannerViewDidDismissScreen(_ bannerView: BannerView) {
        delegate?.bannerViewDidDismissScreen(self)
    }
}
#endif
