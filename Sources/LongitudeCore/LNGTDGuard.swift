import Foundation
// Unconditional: LNGTDRunCatchingNSException below has no Swift-only fallback, so a
// `#if canImport` guard here would not degrade gracefully — it would just move the
// failure from "module missing" to "function undefined".
import LNGTDExceptionShim

public enum LNGTDGuardFailure {
    case swiftError(Error)
    case exception(name: String, reason: String?)
}

public protocol LNGTDGuardEventSink: AnyObject {
    func guardDidCatch(operation: String, failure: LNGTDGuardFailure)
    func guardDidTripBreaker(operation: String)
}

public final class LNGTDCircuitBreaker {
    public static let shared = LNGTDCircuitBreaker()

    private let threshold: Int
    private let window: TimeInterval
    private let clock: () -> TimeInterval

    private let lock = NSLock()
    private var failures: [TimeInterval] = []
    private var _isTripped: Bool = false

    public init(
        threshold: Int = 5,
        window: TimeInterval = 60,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.threshold = threshold
        self.window = window
        self.clock = clock
    }

    public var isTripped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isTripped
    }

    /// Records a failure. Returns true if this failure caused the breaker to trip for the first time.
    func recordFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if _isTripped { return false }

        let now = clock()
        let cutoff = now - window

        failures.removeAll { $0 < cutoff }
        failures.append(now)

        if failures.count >= threshold {
            _isTripped = true
            return true
        }

        return false
    }

    /// Test-only reset. Must never be called in production — a session that has tripped
    /// has demonstrated our code is unreliable in this process.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        _isTripped = false
        failures.removeAll()
    }
}

public enum LNGTDGuard {
    /// Global sink for reporting guard events. The event logger is a Phase 2e
    /// deliverable and does not exist yet; when it does, `ads_disabled` and
    /// `script_error` get emitted from here.
    ///
    /// **Held weakly, so the caller must retain the sink.** Assigning a freshly
    /// constructed object to this property and nothing else will deallocate it
    /// immediately and silently drop every event. Weak is the right default anyway:
    /// the SDK should not keep a publisher's object alive for the process lifetime,
    /// and the real sink will be a long-lived logger owned elsewhere.
    public static weak var sink: LNGTDGuardEventSink?

    @discardableResult
    public static func run<T>(
        _ operation: String,
        breaker: LNGTDCircuitBreaker = .shared,
        fallback: T,
        body: () throws -> T
    ) -> T {
        if breaker.isTripped {
            return fallback
        }

        var bodyResult: Result<T, Error>?

        let caughtException = LNGTDRunCatchingNSException {
            do {
                bodyResult = .success(try body())
            } catch let error {
                bodyResult = .failure(error)
            }
        }

        if let exception = caughtException {
            let failure = LNGTDGuardFailure.exception(
                name: exception.name.rawValue,
                reason: exception.reason
            )
            handleFailure(operation: operation, failure: failure, breaker: breaker)
            return fallback
        }

        switch bodyResult {
        case .success(let value)?:
            return value
        case .failure(let error)?:
            let failure = LNGTDGuardFailure.swiftError(error)
            handleFailure(operation: operation, failure: failure, breaker: breaker)
            return fallback
        case nil:
            return fallback
        }
    }

    public static func run(
        _ operation: String,
        breaker: LNGTDCircuitBreaker = .shared,
        body: () throws -> Void
    ) {
        run(operation, breaker: breaker, fallback: (), body: body)
    }

    private static func handleFailure(operation: String, failure: LNGTDGuardFailure, breaker: LNGTDCircuitBreaker) {
        let didTrip = breaker.recordFailure()

        sink?.guardDidCatch(operation: operation, failure: failure)

        if didTrip {
            sink?.guardDidTripBreaker(operation: operation)
        }
    }
}
