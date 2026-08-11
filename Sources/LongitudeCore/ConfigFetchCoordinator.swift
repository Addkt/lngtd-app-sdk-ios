import Foundation

public protocol ConfigFetchEventSink: AnyObject, Sendable {
    func configFetchDidFail(reason: String)
}

public enum ConfigFetchError: Error, Equatable, Sendable {
    case timeout
    case networkError(statusCode: Int)
    case transportError(domain: String, code: Int)
    case decodeError
    case invalidURL
}

/// `Equatable` so callers and tests can compare outcomes directly rather than
/// pattern-matching every branch. Synthesised: `ConfigRecord` and `ConfigFetchError`
/// are both already `Equatable`.
public enum ConfigFetchOutcome: Sendable, Equatable {
    case fetched(ConfigRecord)
    case notModified
    case throttled
    case failed(ConfigFetchError)
}

public actor ConfigFetchCoordinator {
    private let transport: ConfigTransport
    private let clock: () -> TimeInterval
    /// `nonisolated` because it is immutable after init, so reading it needs no actor
    /// hop — which also lets callers and tests inspect the clamped value synchronously.
    nonisolated let timeout: TimeInterval
    private weak var reporter: ConfigFetchEventSink?

    private var inFlightFetch: Task<ConfigFetchOutcome, Never>?
    private var lastFetchTime: TimeInterval?

    /// Initializes the coordinator.
    ///
    /// - Parameters:
    ///   - transport: The network transport to use.
    ///   - timeout: The per-caller timeout in seconds. Clamped between 0.001s and 3.0s.
    ///   - clock: The monotonic clock source.
    ///   - reporter: The weak sink for reporting errors.
    public init(
        transport: ConfigTransport,
        timeout: TimeInterval = 1.5,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        reporter: ConfigFetchEventSink? = nil
    ) {
        self.transport = transport
        // Timeout is clamped to a sane floor (1ms) for <= 0 values, and hard capped at 3.0s.
        self.timeout = max(0.001, min(timeout, 3.0))
        self.clock = clock
        self.reporter = reporter
    }

    public func fetch(account: String, section: String, etag: String?) async -> ConfigFetchOutcome {
        await fetch(account: account, section: section, etag: etag, timeout: timeout)
    }

    /// Same as `fetch`, with the caller's budget passed explicitly.
    ///
    /// Internal so tests can have two callers with different budgets wait on one
    /// shared request — which is the only way to demonstrate that an impatient caller
    /// timing out does not deprive a patient one of the result. The public entry point
    /// uses the coordinator's configured timeout.
    func fetch(
        account: String, section: String, etag: String?, timeout: TimeInterval
    ) async -> ConfigFetchOutcome {
        // 1. Throttle check
        if let last = lastFetchTime, clock() - last < 60 {
            return .throttled
        }

        // 2. Deduplication check
        let fetchTask: Task<ConfigFetchOutcome, Never>
        if let existing = inFlightFetch {
            fetchTask = existing
        } else {
            // The failure mode to avoid: read "is a fetch in flight?", find none, await something,
            // then store the new task. Any suspension between the check and the store lets a second
            // caller through and you get two requests. Creating a Task is synchronous, so check-and-store
            // can be done with no await between them.
            fetchTask = Task { [weak self] in
                // We capture dependencies rather than `self` where possible, but we need `self`
                // to call back and finalize state (clear task, stamp throttle window).
                guard let self = self else {
                    return .failed(.transportError(domain: "ConfigFetchCoordinator", code: -1))
                }

                let outcome = await self.executeNetworkFetch(account: account, section: section, etag: etag)
                await self.finalizeFetch()
                return outcome
            }
            self.inFlightFetch = fetchTask
        }

        // 3. Wait for the shared result, or give up when this caller's budget expires.
        return await awaitFirst(of: fetchTask, timeout: max(0.001, min(timeout, 3.0)))
    }

    /// Waits for `task`, or returns `.failed(.timeout)` once `timeout` elapses —
    /// whichever happens first — **without** holding on to the shared request.
    ///
    /// This deliberately does not use `withTaskGroup`. A task group awaits all of its
    /// children before its scope returns, and `await task.value` on a
    /// `Task<_, Never>` ignores cancellation, so `cancelAll()` cannot release a child
    /// that is waiting on the shared fetch. The group therefore blocks until the
    /// network finishes and the caller waits the full request duration while still
    /// *reporting* `.failed(.timeout)` — a timeout that looks correct from the return
    /// value and does nothing. Measured at 2.07s against a 0.15s budget before this
    /// was changed.
    ///
    /// Two unstructured tasks race to resume a continuation instead. `withCheckedContinuation`
    /// returns the moment one of them resumes, so the caller is released on time. The
    /// loser finishes later and its resume is a no-op; the shared fetch keeps running
    /// so a later caller, and the cache, still get the result.
    private func awaitFirst(
        of task: Task<ConfigFetchOutcome, Never>, timeout: TimeInterval
    ) async -> ConfigFetchOutcome {
        await withCheckedContinuation { continuation in
            let gate = ResumeOnce(continuation)

            Task {
                let outcome = await task.value
                gate.resume(with: outcome)
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                gate.resume(with: .failed(.timeout))
            }
        }
    }

    /// Ensures a checked continuation is resumed exactly once, whichever racer wins.
    /// Resuming a checked continuation twice is a runtime trap, so the guard is not
    /// optional.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ConfigFetchOutcome, Never>?

        init(_ continuation: CheckedContinuation<ConfigFetchOutcome, Never>) {
            self.continuation = continuation
        }

        func resume(with outcome: ConfigFetchOutcome) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: outcome)
        }
    }

    private func executeNetworkFetch(account: String, section: String, etag: String?) async -> ConfigFetchOutcome {
        guard let url = buildURL(account: account, section: section) else {
            reportError(reason: "invalid_url")
            return .failed(.invalidURL)
        }

        do {
            let response = try await transport.fetch(url: url, ifNoneMatch: etag)

            if response.statusCode == 304 {
                return .notModified
            }

            if response.statusCode == 200 {
                do {
                    let decoder = JSONDecoder()
                    _ = try decoder.decode(AppConfig.self, from: response.body)

                    let record = ConfigRecord(
                        fetchedAt: clock(),
                        etag: response.etag,
                        payload: response.body
                    )
                    return .fetched(record)
                } catch {
                    reportError(reason: "decode_error")
                    return .failed(.decodeError)
                }
            }

            reportError(reason: "http_\(response.statusCode)")
            return .failed(.networkError(statusCode: response.statusCode))

        } catch {
            reportError(reason: "transport_error")
            let nsError = error as NSError
            return .failed(.transportError(domain: nsError.domain, code: nsError.code))
        }
    }

    private func finalizeFetch() {
        self.inFlightFetch = nil
        // Any completed fetch (200, 304, or failure) stamps the throttle window.
        self.lastFetchTime = clock()
    }

    private func reportError(reason: String) {
        reporter?.configFetchDidFail(reason: reason)
    }

    nonisolated private func buildURL(account: String, section: String) -> URL? {
        var components = URLComponents(string: "https://floors.lngtd.com/")
        components?.queryItems = [
            URLQueryItem(name: "account", value: account),
            URLQueryItem(name: "section", value: section),
            URLQueryItem(name: "ct", value: "app"),
            URLQueryItem(name: "p", value: "ios")
        ]
        return components?.url
    }
}
