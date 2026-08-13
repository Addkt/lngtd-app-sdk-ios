import GoogleMobileAds
import LongitudeGAM
import UIKit

/// The drop-in claim, made falsifiable.
///
/// Two banners, identical layout code, same GAM ad unit. The top one is raw
/// `AdManagerBannerView`; the bottom is `LNGTDBannerView`. If the migration really is
/// "one import, three type names, one `slot:` label", the two blocks below should differ
/// by exactly that and the rendered result should be indistinguishable.
final class SideBySideViewController: UIViewController {

    /// The same unit the bundled LNGTDConfig.json maps `demo_banner` to, so both sides
    /// request the same inventory and any difference is ours, not the ad server's.
    /// Google's documented Ad Manager sample unit, which serves test creatives to
    /// simulators without any account setup. `/6499/example/banner` is the older sample
    /// and returns no-fill here, which looks like an SDK failure and is not one.
    static let sampleAdUnit = "/21775744923/example/adaptive-banner"

    private let gamBanner = AdManagerBannerView()
    private var lngtdBanner: LNGTDBannerView?

    private let gamStatus = StatusLabel()
    private let lngtdStatus = StatusLabel()

    private var lngtdResolution = "resolving…"
    private var lngtdLoadState = "loading…"

    private func renderLongitudeStatus() {
        lngtdStatus.text = lngtdLoadState + "\n" + lngtdResolution
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // ── Raw GMA ────────────────────────────────────────────────────────────────
        gamBanner.adUnitID = Self.sampleAdUnit
        gamBanner.validAdSizes = [nsValue(for: AdSizeBanner)]
        gamBanner.rootViewController = self
        gamBanner.delegate = self
        gamBanner.load(AdManagerRequest())

        // ── Longitude ──────────────────────────────────────────────────────────────
        // Differences from the block above: the type name, the slot: label, and that
        // adUnitID is a fallback rather than the instruction.
        let banner = Longitude.bannerView(slot: "demo_banner")
        banner?.adUnitID = Self.sampleAdUnit          // passthrough fallback
        banner?.validAdSizes = [AdSizeBanner]
        banner?.rootViewController = self
        banner?.delegate = self
        banner?.onResolution = { [weak self] resolution in
            // Resolution and load state are separate facts and are shown on separate
            // lines. Overwriting one with the other hid which path had been taken as
            // soon as a load failed, which is exactly when you want to know.
            self?.lngtdResolution = Self.describe(resolution)
            self?.renderLongitudeStatus()
        }
        banner?.load(AdManagerRequest())
        lngtdBanner = banner

        layout(banner: gamBanner, status: gamStatus, header: "Raw GMA", topAnchor: view.safeAreaLayoutGuide.topAnchor)
        if let banner {
            layout(
                banner: banner, status: lngtdStatus, header: "Longitude",
                topAnchor: gamStatus.bottomAnchor
            )
        } else {
            lngtdStatus.text = "Longitude.start was not called"
        }
    }

    private static func describe(_ resolution: SlotResolution) -> String {
        switch resolution {
        case .longitude(let plan):
            let floor: String
            switch plan.resolvedFloor {
            case .value(let value): floor = String(format: "%.2f", value)
            case .noFloor: floor = "none (imp.bidfloor omitted)"
            }
            return "Longitude · \(plan.gamPath) · uid \(plan.uid) · floor \(floor)"
        case .passthrough(let cause):
            return "PASSTHROUGH (\(cause)) · using publisher adUnitID"
        }
    }

    private func layout(
        banner: UIView, status: UILabel, header: String, topAnchor: NSLayoutYAxisAnchor
    ) {
        let title = UILabel()
        title.text = header
        title.font = .preferredFont(forTextStyle: .headline)

        for subview in [title, banner, status] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            banner.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            banner.widthAnchor.constraint(equalToConstant: 320),
            banner.heightAnchor.constraint(equalToConstant: 50),

            status.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])
    }
}

// Both delegates, so the two paths report through the same code and any divergence in
// callback behaviour shows up as different text rather than being invisible.
extension SideBySideViewController: BannerViewDelegate {
    func bannerViewDidReceiveAd(_ bannerView: BannerView) {
        gamStatus.text = "loaded · \(bannerView.adSize.size.width)x\(bannerView.adSize.size.height)"
    }

    func bannerView(_ bannerView: BannerView, didFailToReceiveAdWithError error: Error) {
        gamStatus.text = "failed · \(error.localizedDescription)"
    }
}

extension SideBySideViewController: LNGTDBannerViewDelegate {
    func bannerViewDidReceiveAd(_ bannerView: LNGTDBannerView) {
        DemoMetrics.shared.recordFirstAdResponse()
        let size = bannerView.gamBannerView.adSize.size
        lngtdLoadState = "loaded · \(Int(size.width))x\(Int(size.height))"
        renderLongitudeStatus()
    }

    func bannerView(_ bannerView: LNGTDBannerView, didFailToReceiveAdWithError error: Error) {
        DemoMetrics.shared.recordFirstAdResponse()
        lngtdLoadState = "failed · \(error.localizedDescription)"
        renderLongitudeStatus()
    }
}

final class StatusLabel: UILabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textColor = .secondaryLabel
        numberOfLines = 0
        text = "loading…"
    }

    required init?(coder: NSCoder) { nil }
}
