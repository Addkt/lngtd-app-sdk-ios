#if os(iOS)
import Foundation
import GoogleMobileAds
import LongitudeCore
import UIKit

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

    // MARK: - Internals

    private let gamBanner = AdManagerBannerView()
    private let engine: LongitudeEngine
    private let deviceClass: String

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
    ///
    /// A slot name is required and no default is honest, so there is no usable
    /// storyboard initialiser — but this is a *failable* initialiser, and UIKit will
    /// still dispatch to it at runtime if someone puts this view in a nib. Returning nil
    /// fails that nib load; `fatalError` would crash a publisher's app, which is the
    /// exact outcome the 2g rules exist to prevent. (The SwiftLint rule flagged this
    /// when it was a `fatalError`, which is the rule doing its job.)
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
        loadGeneration &+= 1
        let generation = loadGeneration
        let auctionId = UUID().uuidString

        Task { [weak self] in
            guard let self else { return }

            let resolution = await self.engine.resolve(
                slot: self.slot,
                auctionId: auctionId,
                deviceClass: self.deviceClass,
                sessionDepth: 0  // Phase 2e owns session depth.
            )

            // A newer load() superseded this one while we were resolving.
            guard generation == self.loadGeneration else { return }

            switch resolution {
            case .longitude(let plan):
                self.applyPlan(plan)
                self.passthroughCause = nil
            case .passthrough(let cause):
                // Leave adUnitID and validAdSizes exactly as the publisher set them.
                self.passthroughCause = cause
            }

            self.gamBanner.load(request)
        }
    }

    private func applyPlan(_ plan: LongitudeSlotPlan) {
        gamBanner.adUnitID = plan.gamPath

        // Config sizes win when present; otherwise keep the publisher's, so a config
        // that omits sizes degrades to their intent rather than to nothing.
        if let sizes = plan.sizes, !sizes.isEmpty {
            let converted = sizes.compactMap(Self.adSize(from:))
            if !converted.isEmpty {
                applyValidAdSizes(converted)
            }
        }

        // plan.resolvedFloor and plan.refreshSeconds are unused on this path until
        // LongitudeAuction (M2) and refresh (M4). They are carried on the plan rather
        // than recomputed there.
    }

    private func applyValidAdSizes(_ sizes: [AdSize]) {
        gamBanner.validAdSizes = sizes.map { nsValue(for: $0) }
        if let first = sizes.first {
            gamBanner.adSize = first
        }
    }

    /// `[width, height]` from the config to a GMA `AdSize`.
    ///
    /// Returns nil rather than substituting a default for a malformed pair: silently
    /// serving a 320x50 where the config asked for something else would be a wrong ad
    /// that looks correct.
    private static func adSize(from pair: [Int]) -> AdSize? {
        guard pair.count == 2, pair[0] > 0, pair[1] > 0 else { return nil }
        let size = adSizeFor(cgSize: CGSize(width: pair[0], height: pair[1]))
        guard isAdSizeValid(size: size) else { return nil }
        return size
    }

    /// `phone` or `tablet`, matching the floor ladder's device-class segment.
    ///
    /// Note this is NOT the web's `mobile`/`desktop` vocabulary — see
    /// Tools/FloorContract/README.md for why the two runtimes cannot share spellings.
    public static func currentDeviceClass() -> String {
        UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone"
    }

    public override var intrinsicContentSize: CGSize {
        cgSize(for: gamBanner.adSize)
    }
}

// MARK: - BannerViewDelegate forwarding

extension LNGTDBannerView: BannerViewDelegate {
    public func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        invalidateIntrinsicContentSize()
        delegate?.bannerViewDidReceiveAd(self)
    }

    public func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        delegate?.bannerView(self, didFailToReceiveAdWithError: error)
    }

    public func bannerViewDidRecordImpression(_ bannerView: BannerView) {
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
