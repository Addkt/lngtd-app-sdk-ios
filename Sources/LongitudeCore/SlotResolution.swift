import Foundation

public struct LongitudeSlotPlan: Equatable, Sendable {
    public let gamPath: String
    public let sizes: [[Int]]?
    public let resolvedFloor: ResolvedFloor
    public let uid: String
    public let refreshSeconds: Int?
    public let lazyLoad: Bool

    public init(
        gamPath: String,
        sizes: [[Int]]?,
        resolvedFloor: ResolvedFloor,
        uid: String,
        refreshSeconds: Int?,
        lazyLoad: Bool
    ) {
        self.gamPath = gamPath
        self.sizes = sizes
        self.resolvedFloor = resolvedFloor
        self.uid = uid
        self.refreshSeconds = refreshSeconds
        self.lazyLoad = lazyLoad
    }
}

public enum PassthroughCause: Equatable, Sendable {
    /// Nothing usable from any tier.
    case noConfig
    /// The served config has `features.killSwitch` set.
    case killSwitch
    /// The config is present and valid, but defines no ad unit under this slot name.
    /// Distinct from `noConfig` because it is the failure a publisher actually hits —
    /// `slot: "home-top"` against a config defining `home_top` — and the two lead to
    /// completely different support answers.
    case unknownSlot
    /// The ad unit exists but has no usable `gamPath`, so there is nothing to request.
    case invalidGamPath
    /// The served config's schema version or platform is not one this SDK understands.
    /// Permanent until the app or the server changes, unlike the others.
    case unsupportedConfig
}

public enum SlotResolution: Equatable, Sendable {
    /// Serve through Longitude.
    case longitude(LongitudeSlotPlan)
    /// Serve GMA directly from the publisher's own settings.
    case passthrough(PassthroughCause)
}
