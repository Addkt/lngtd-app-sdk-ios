#if os(iOS)
import Foundation

/// Mirrors `GoogleMobileAds.BannerViewDelegate` method-for-method, with
/// `LNGTDBannerView` substituted for `BannerView`.
///
/// That correspondence is the migration story: a publisher moving from GMA changes an
/// import, three type names and one `slot:` label, and their existing delegate bodies
/// compile unchanged. Renaming anything here to read "better" breaks that and buys
/// nothing — the names are GMA's, deliberately.
///
/// Every method is `@MainActor` because GMA's own delegate methods are annotated
/// `NS_SWIFT_UI_ACTOR`; the wrapper forwards on the thread it was called on.
@MainActor
public protocol LNGTDBannerViewDelegate: AnyObject {
    func bannerViewDidReceiveAd(_ bannerView: LNGTDBannerView)
    func bannerView(_ bannerView: LNGTDBannerView, didFailToReceiveAdWithError error: Error)
    func bannerViewDidRecordImpression(_ bannerView: LNGTDBannerView)
    func bannerViewDidRecordClick(_ bannerView: LNGTDBannerView)
    func bannerViewWillPresentScreen(_ bannerView: LNGTDBannerView)
    func bannerViewWillDismissScreen(_ bannerView: LNGTDBannerView)
    func bannerViewDidDismissScreen(_ bannerView: LNGTDBannerView)
}

/// All optional in practice, matching how publishers use `BannerViewDelegate` — most
/// implement one or two methods. Swift protocols have no `@objc optional` without
/// inheriting NSObjectProtocol, so defaults provide the same ergonomics.
public extension LNGTDBannerViewDelegate {
    func bannerViewDidReceiveAd(_ bannerView: LNGTDBannerView) {}
    func bannerView(_ bannerView: LNGTDBannerView, didFailToReceiveAdWithError error: Error) {}
    func bannerViewDidRecordImpression(_ bannerView: LNGTDBannerView) {}
    func bannerViewDidRecordClick(_ bannerView: LNGTDBannerView) {}
    func bannerViewWillPresentScreen(_ bannerView: LNGTDBannerView) {}
    func bannerViewWillDismissScreen(_ bannerView: LNGTDBannerView) {}
    func bannerViewDidDismissScreen(_ bannerView: LNGTDBannerView) {}
}
#endif
