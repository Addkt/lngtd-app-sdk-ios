import Foundation

public enum ConfigFreshness: Equatable, Sendable {
    case fresh
    case revalidate
    case staleUsable

    /// Classifies a stored config's freshness based on its age.
    ///
    /// Precedence when `ttl > 24h`: The 24h bound is absolute and overrides the TTL.
    /// A config older than 24h is always `staleUsable`, even if its TTL claims it is
    /// still valid. The physical world (e.g., the user's location) or server-side
    /// requirements may have changed over a 24-hour period, meaning the config is no
    /// longer "fresh".
    ///
    /// - Parameters:
    ///   - fetchedAt: When the config was fetched
    ///   - ttl: The ttl from the config payload
    ///   - isError: The `_error` flag from the config payload
    ///   - clock: Injected clock
    public static func classify(
        fetchedAt: TimeInterval,
        ttl: TimeInterval,
        isError: Bool,
        clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) -> ConfigFreshness {
        let age = clock() - fetchedAt
        let twentyFourHours: TimeInterval = 86400

        if age >= twentyFourHours {
            return .staleUsable
        }

        if isError {
            return .revalidate
        }

        if age < ttl {
            return .fresh
        }

        return .revalidate
    }
}

public enum GeoSource: Equatable, Sendable {
    case config
    case device
}

public struct GeoFreshness: Equatable, Sendable {
    public let country: String
    public let source: GeoSource

    /// Resolves which country to use and its source.
    ///
    /// - Parameters:
    ///   - fetchedAt: When the config was fetched
    ///   - configCountry: The country provided by the config, if any
    ///   - deviceRegion: The fallback region (e.g. Locale.current.region?.identifier)
    ///   - clock: Injected clock
    public static func resolve(
        fetchedAt: TimeInterval,
        configCountry: String?,
        deviceRegion: String?,
        clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) -> GeoFreshness {
        let age = clock() - fetchedAt
        let oneHour: TimeInterval = 3600

        if age <= oneHour, let configCountry = configCountry, !configCountry.isEmpty {
            return GeoFreshness(country: configCountry.uppercased(), source: .config)
        }

        if let deviceRegion = deviceRegion, !deviceRegion.isEmpty {
            return GeoFreshness(country: deviceRegion.uppercased(), source: .device)
        }

        if let configCountry = configCountry, !configCountry.isEmpty {
            return GeoFreshness(country: configCountry.uppercased(), source: .config)
        }

        return GeoFreshness(country: "", source: .device)
    }
}
