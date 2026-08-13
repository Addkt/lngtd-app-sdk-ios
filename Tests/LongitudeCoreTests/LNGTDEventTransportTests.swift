import XCTest
@testable import LongitudeCore

/// Intercepts requests so the fallback policy can be exercised without a network.
///
/// Outcomes are queued and consumed in order, which is what makes "primary 500, fallback
/// 200" expressible. Every request is captured whether or not an outcome was queued, so a
/// test can prove a *third* request never happened.
///
/// Not `final`: the `class func` overrides below are required by `URLProtocol`, and
/// SwiftLint's `static_over_final_class` would object to them in a final class.
class MockURLProtocol: URLProtocol {
    enum Outcome {
        case status(Int)
        case failure(URLError.Code)
    }

    struct Capture {
        let url: String
        let method: String
        let contentType: String?
        let sdkHeader: String?
        let body: Data
    }

    private static let lock = NSLock()
    private static var queuedOutcomes: [Outcome] = []
    private static var storedCaptures: [Capture] = []
    private static var responseBody = Data()

    static func reset(outcomes: [Outcome], responseBody: Data = Data()) {
        lock.lock()
        queuedOutcomes = outcomes
        storedCaptures = []
        self.responseBody = responseBody
        lock.unlock()
    }

    static var captures: [Capture] {
        lock.lock()
        defer { lock.unlock() }
        return storedCaptures
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let capture = Capture(
            url: request.url?.absoluteString ?? "",
            method: request.httpMethod ?? "",
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            sdkHeader: request.value(forHTTPHeaderField: "X-LNGTD-SDK"),
            body: Self.extractBody(from: request)
        )

        Self.lock.lock()
        Self.storedCaptures.append(capture)
        // Anything past the queued outcomes answers 200, so an unexpected extra request is
        // visible in `captures` rather than hanging the test.
        let outcome = Self.queuedOutcomes.isEmpty
            ? Outcome.status(200)
            : Self.queuedOutcomes.removeFirst()
        let body = Self.responseBody
        Self.lock.unlock()

        switch outcome {
        case .status(let code):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url, statusCode: code, httpVersion: nil, headerFields: nil
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)

        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}

    /// `URLSession` moves a request body into `httpBodyStream`, leaving `httpBody` nil. The
    /// delivered test guarded the body assertion behind `if let httpBody`, so on this path it
    /// asserted nothing at all. Always returns a value so the assertion cannot be skipped.
    private static func extractBody(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let capacity = 4096
        var buffer = [UInt8](repeating: 0, count: capacity)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: capacity)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class LNGTDEventTransportTests: XCTestCase {
    private var transport = URLSessionEventTransport()
    private let payload = Data("[{\"event\":\"impression\"}]".utf8)

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset(outcomes: [])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        transport = URLSessionEventTransport(session: URLSession(configuration: configuration))
    }

    // 1.
    func test01_ThePrimaryRequestCarriesTheRequiredMethodAndHeaders() async {
        MockURLProtocol.reset(outcomes: [.status(200)])

        _ = await transport.send(payload: payload)

        XCTAssertEqual(MockURLProtocol.captures.count, 1)
        let request = MockURLProtocol.captures[0]
        XCTAssertEqual(request.url, "https://ld.lngtd.com/", "logging.js:255")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(
            request.contentType, "text/plain;charset=UTF-8",
            "logging.js:309 — a different content type risks a silent 200 with no log line"
        )
        XCTAssertEqual(request.sdkHeader, "ios/1.0.0")
    }

    // 2.
    func test02_TheRequestBodyIsThePayloadVerbatim() async {
        MockURLProtocol.reset(outcomes: [.status(200)])

        _ = await transport.send(payload: payload)

        XCTAssertEqual(MockURLProtocol.captures.map(\.body), [payload])
    }

    // 3.
    func test03_A200DoesNotFallBack() async {
        MockURLProtocol.reset(outcomes: [.status(200)])

        let result = await transport.send(payload: payload)

        XCTAssertEqual(result, .success)
        XCTAssertEqual(MockURLProtocol.captures.map(\.url), ["https://ld.lngtd.com/"])
    }

    // 4.
    func test04_A500FallsBackOnceWithTheSameBody() async {
        MockURLProtocol.reset(outcomes: [.status(500), .status(200)])

        let result = await transport.send(payload: payload)

        XCTAssertEqual(result, .success)
        XCTAssertEqual(
            MockURLProtocol.captures.map(\.url),
            ["https://ld.lngtd.com/", "https://it.lngtd.com/"],
            "logging.js:256 — exactly one fallback attempt, in order"
        )
        XCTAssertEqual(MockURLProtocol.captures.map(\.body), [payload, payload])
    }

    // 5.
    func test05_TheFallbackBoundaryIs500() async {
        MockURLProtocol.reset(outcomes: [.status(499)])
        _ = await transport.send(payload: payload)
        XCTAssertEqual(MockURLProtocol.captures.count, 1, "499 is a 4xx: final, no fallback")

        MockURLProtocol.reset(outcomes: [.status(500), .status(200)])
        _ = await transport.send(payload: payload)
        XCTAssertEqual(MockURLProtocol.captures.count, 2, "500 is the first fallback-eligible status")
    }

    // 6.
    func test06_A404DoesNotFallBack() async {
        MockURLProtocol.reset(outcomes: [.status(404)])

        let result = await transport.send(payload: payload)

        XCTAssertEqual(result, .rejected, "a rejected payload will be rejected again")
        XCTAssertEqual(MockURLProtocol.captures.count, 1)
    }

    // 7.
    func test07_A429DoesNotFallBackDespiteTheConvention() async {
        MockURLProtocol.reset(outcomes: [.status(429)])

        let result = await transport.send(payload: payload)

        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(
            MockURLProtocol.captures.count, 1,
            "the contract says no retry on any 4xx, even the one that conventionally means retry"
        )
    }

    // 8.
    func test08_AConnectionThatNeverCompletedFallsBack() async {
        MockURLProtocol.reset(outcomes: [.failure(.notConnectedToInternet), .status(200)])

        let result = await transport.send(payload: payload)

        XCTAssertEqual(result, .success)
        XCTAssertEqual(
            MockURLProtocol.captures.map(\.url),
            ["https://ld.lngtd.com/", "https://it.lngtd.com/"],
            "this is the Swift equivalent of the web client's status === 0"
        )
    }

    // 9.
    func test09_ACancelledRequestDoesNotFallBack() async {
        MockURLProtocol.reset(outcomes: [.failure(.cancelled)])

        let result = await transport.send(payload: payload)

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(
            MockURLProtocol.captures.count, 1,
            "a cancelled request usually means the app was suspended; retrying it to the "
            + "fallback is how one batch becomes two impressions for the same ad"
        )
    }

    // 10.
    func test10_AFailingFallbackIsNotRetried() async {
        MockURLProtocol.reset(outcomes: [.status(500), .status(500)])

        let result = await transport.send(payload: payload)

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(MockURLProtocol.captures.count, 2, "fire the fallback once, then stop")
    }

    // 11.
    func test11_TheResponseBodyIsNeverParsed() async {
        MockURLProtocol.reset(
            outcomes: [.status(200)],
            responseBody: Data("<html>not json at all".utf8)
        )

        let result = await transport.send(payload: payload)

        XCTAssertEqual(
            result, .success,
            "the collector's response body is not a contract; only the status matters"
        )
    }
}
