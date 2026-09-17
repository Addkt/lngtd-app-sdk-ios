import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LNGTDEventTransportResult: Sendable, Equatable {
    /// A 2xx response. The payload was accepted.
    case success
    /// A 4xx response. The payload was permanently rejected.
    case rejected
    /// A 5xx response or a network failure. The connection failed or the server could not process it.
    case failed
}

public enum LNGTDEndpoint: Sendable, Equatable, Hashable {
    case tracking
    case nonTracking
}

public protocol LNGTDEventTransport: Sendable {
    func send(payload: Data, endpoint: LNGTDEndpoint) async -> LNGTDEventTransportResult
}

public let LNGTDSDKVersion = "ios/1.0.0"

public final class URLSessionEventTransport: LNGTDEventTransport {
    /// `logging.js:255` and `logging.js:256`. Built once from literals that are known to
    /// parse, so the failure is impossible rather than force-unwrapped at every init.
    public static let defaultPrimaryURL = URL(
        string: "https://ld.lngtd.com/"
    ) ?? URL(fileURLWithPath: "/")
    public static let defaultFallbackURL = URL(
        string: "https://it.lngtd.com/"
    ) ?? URL(fileURLWithPath: "/")
    public static let defaultNonTrackingURL = URL(
        string: "https://nt.lngtd.com/"
    ) ?? URL(fileURLWithPath: "/")

    private let session: URLSession
    private let primaryURL: URL
    private let fallbackURL: URL
    private let nonTrackingURL: URL
    private let sdkVersion: String

    public init(
        session: URLSession = .shared,
        primaryURL: URL = URLSessionEventTransport.defaultPrimaryURL,
        fallbackURL: URL = URLSessionEventTransport.defaultFallbackURL,
        nonTrackingURL: URL = URLSessionEventTransport.defaultNonTrackingURL,
        sdkVersion: String = LNGTDSDKVersion
    ) {
        self.session = session
        self.primaryURL = primaryURL
        self.fallbackURL = fallbackURL
        self.nonTrackingURL = nonTrackingURL
        self.sdkVersion = sdkVersion
    }

    public func send(payload: Data, endpoint: LNGTDEndpoint) async -> LNGTDEventTransportResult {
        let targetURL = endpoint == .tracking ? primaryURL : nonTrackingURL

        do {
            let (status, error) = try await performRequest(url: targetURL, payload: payload)
            if let status = status {
                if status >= 200 && status < 300 { return .success }
                if status >= 400 && status < 500 { return .rejected }
                // 5xx falls through to fallback
            } else if let error = error {
                if !isFallbackEligible(error) {
                    return .failed // e.g. cancelled, don't fallback
                }
            }
        } catch {
            return .failed
        }

        // Fallback
        if endpoint == .tracking {
            do {
                let (status, _) = try await performRequest(url: fallbackURL, payload: payload)
                if let status = status {
                    if status >= 200 && status < 300 { return .success }
                    if status >= 400 && status < 500 { return .rejected }
                }
            } catch {
                // Ignored, return .failed
            }
        } else {
            // The non-tracking path intentionally has no fallback. `it.lngtd.com` is a listed
            // tracking domain and would be blocked.
        }

        return .failed
    }

    private func performRequest(url: URL, payload: Data) async throws -> (Int?, URLError?) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(sdkVersion, forHTTPHeaderField: "X-LNGTD-SDK")
        request.httpBody = payload

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return (nil, nil)
            }
            return (httpResponse.statusCode, nil)
        } catch let error as URLError {
            return (nil, error)
        } catch {
            throw error
        }
    }

    private func isFallbackEligible(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet,
             .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed:
            return true
        default:
            return false
        }
    }
}
