import Foundation

/// An envelope for caching `AppConfig` to disk.
/// `Sendable` because the fetch coordinator returns one across an actor boundary.
/// All stored properties are value types, so the conformance is genuine rather than
/// an `@unchecked` assertion.
public struct ConfigRecord: Codable, Equatable, Sendable {
    public let fetchedAt: TimeInterval
    public let etag: String?

    /// I chose to store the raw `Data` rather than the decoded `AppConfig` because
    /// standard Swift `Codable` drops unknown fields upon re-encoding. If we decoded
    /// `AppConfig` and saved it directly, any forward-compatible fields added by a newer
    /// Lambda would be silently stripped out when writing the cache back to disk. By
    /// storing the original raw `Data`, the standard `JSONEncoder` will encode it (as a
    /// base64 string in the JSON envelope), ensuring those unknown fields survive a
    /// save/load cycle perfectly intact.
    public let payload: Data

    public init(fetchedAt: TimeInterval, etag: String?, payload: Data) {
        self.fetchedAt = fetchedAt
        self.etag = etag
        self.payload = payload
    }

    /// Lazily decodes the payload into an `AppConfig`.
    public func decodedPayload() throws -> AppConfig {
        return try JSONDecoder().decode(AppConfig.self, from: payload)
    }
}
