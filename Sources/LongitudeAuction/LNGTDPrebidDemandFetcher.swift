#if os(iOS)
import Foundation
import PrebidMobile
import LongitudeCore

/// A demand fetcher that wraps a Prebid `AdUnit`.
///
/// Kept entirely behind `#if os(iOS)` so it compiles to an empty module on macOS,
/// preserving the millisecond host test loop for `LongitudeCore`.
public final class LNGTDPrebidDemandFetcher: LNGTDDemandFetching, @unchecked Sendable {
    private let adUnit: AdUnit

    public init(adUnit: AdUnit) {
        self.adUnit = adUnit
        // Defensive: never let Prebid auto-refresh, because it re-auctions without
        // reloading GAM, inflating the auction denominator.
        self.adUnit.stopAutoRefresh()
    }

    public func fetchDemand(completion: @escaping @Sendable (LNGTDAuctionOutcome, [String: String]?, Double?) -> Void) {
        // `completionBidInfo:`, not `fetchDemand(adObject:completion:)` — that overload's body
        // is `completion(bidInfo.resultCode)`, discarding the targeting keys, the price and exp.
        //
        // Prebid delivers this through DispatchQueue.main.async, so it arrives on main even
        // though the rest of the SDK stays off it. Map and hand off; do no work here.
        adUnit.fetchDemand { bidInfo in
            completion(
                Self.mapOutcome(bidInfo.resultCode),
                bidInfo.targetingKeywords,
                bidInfo.exp
            )
        }
    }

    public func stopAutoRefresh() {
        adUnit.stopAutoRefresh()
    }

    /// Static, and deliberately not an instance method captured weakly. Reading the result
    /// code needs nothing from `self`, and a `[weak self]` capture meant a fetcher deallocated
    /// mid-flight reported `.unrecognised` for a bid that had in fact resolved.
    private static func mapOutcome(_ resultCode: ResultCode?) -> LNGTDAuctionOutcome {
        guard let resultCode = resultCode else { return .unrecognised }
        switch resultCode {
        case .prebidDemandFetchSuccess:
            return .success
        case .prebidDemandNoBids:
            return .noBids
        case .prebidDemandTimedOut:
            return .timeout
        case .prebidNetworkError:
            return .networkError
        case .prebidServerError:
            return .serverError
        case .prebidInvalidAccountId:
            return .invalidAccountId
        case .prebidInvalidConfigId:
            return .invalidConfigId
        case .prebidInvalidSize:
            return .invalidSize
        default:
            return .unrecognised
        }
    }
}
#endif
