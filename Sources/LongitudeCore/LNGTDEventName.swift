import Foundation

public struct LNGTDEventName: RawRepresentable, Equatable, Hashable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // Immediate events
    public static let impression = LNGTDEventName(rawValue: "impression")
    public static let viewableImpression = LNGTDEventName(rawValue: "viewable_impression")
    public static let pageview = LNGTDEventName(rawValue: "pageview")

    // Mobile-only events
    public static let paidEvent = LNGTDEventName(rawValue: "paid_event")
    public static let adClick = LNGTDEventName(rawValue: "ad_click")
    public static let sdkInit = LNGTDEventName(rawValue: "sdk_init")
    public static let appForeground = LNGTDEventName(rawValue: "app_foreground")
    public static let appBackground = LNGTDEventName(rawValue: "app_background")
    public static let fullscreenPresent = LNGTDEventName(rawValue: "fullscreen_present")
    public static let fullscreenDismiss = LNGTDEventName(rawValue: "fullscreen_dismiss")
    public static let fullscreenPresentFailure = LNGTDEventName(rawValue: "fullscreen_present_failure")
    public static let rewardEarned = LNGTDEventName(rawValue: "reward_earned")
    public static let attStatusChange = LNGTDEventName(rawValue: "att_status_change")
    public static let slotLazyDeferred = LNGTDEventName(rawValue: "slot_lazy_deferred")

    // Auction events
    public static let bid = LNGTDEventName(rawValue: "bid")
    public static let bidBelowFloor = LNGTDEventName(rawValue: "bid_below_floor")
    /// Partial support: we can drop Prebid targeting on a blocked creative but cannot block a GAM-rendered one.
    public static let blockedBid = LNGTDEventName(rawValue: "blocked_bid")

    // The following events are omitted by design:
    // - missing_adapter: Prebid.js concept, not applicable for S2S.
    // - video_impression: partial.
    // - vast_error: no analogue on GAM-rendered path, deferred to Rendering API.
    // - content_start, content_stalled, player_close: needs publisher content player, deferred to manual API.

    public var isImmediate: Bool {
        switch self {
        case .impression, .viewableImpression, .pageview:
            return true
        default:
            return false
        }
    }

    /// Every name this SDK is allowed to emit.
    ///
    /// `RawRepresentable` is deliberately open — the collector accepts whatever it is
    /// sent, and closing the type would mean a new event name required an SDK release.
    /// But open means `LNGTDEventName(rawValue: "page_view")` compiles and ships, and a
    /// misspelled name does not fail anywhere: it lands in the warehouse as a distinct
    /// event that no report counts and nobody notices is missing.
    ///
    /// So the taxonomy is enumerable, `isKnown` can be asserted in tests and checked at
    /// the emit boundary, and adding a name means adding it here too.
    public static let allKnown: [LNGTDEventName] = [
        .impression, .viewableImpression, .pageview,
        .paidEvent, .adClick, .sdkInit, .appForeground, .appBackground,
        .fullscreenPresent, .fullscreenDismiss, .fullscreenPresentFailure,
        .rewardEarned, .attStatusChange, .slotLazyDeferred,
        .bid, .bidBelowFloor, .blockedBid
    ]

    public var isKnown: Bool {
        Self.allKnown.contains(self)
    }
}
