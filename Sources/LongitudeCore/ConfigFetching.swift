import Foundation

public protocol ConfigFetching: Sendable {
    func fetch(account: String, section: String, etag: String?) async -> ConfigFetchOutcome
}
