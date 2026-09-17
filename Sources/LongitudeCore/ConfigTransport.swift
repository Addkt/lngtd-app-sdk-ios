import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ConfigTransportResponse: Sendable {
    public let statusCode: Int
    public let etag: String?
    public let body: Data

    public init(statusCode: Int, etag: String?, body: Data) {
        self.statusCode = statusCode
        self.etag = etag
        self.body = body
    }
}

public protocol ConfigTransport: Sendable {
    func fetch(url: URL, ifNoneMatch etag: String?) async throws -> ConfigTransportResponse
}

public struct URLSessionConfigTransport: ConfigTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(url: URL, ifNoneMatch etag: String?) async throws -> ConfigTransportResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        if let etag = etag {
            // Send verbatim, preserving weak prefix W/ and quotes if present.
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConfigTransportError.invalidResponse
        }

        let responseEtag = httpResponse.value(forHTTPHeaderField: "Etag")

        return ConfigTransportResponse(
            statusCode: httpResponse.statusCode,
            etag: responseEtag,
            body: data
        )
    }
}

public enum ConfigTransportError: Error, Equatable {
    case invalidResponse
}
