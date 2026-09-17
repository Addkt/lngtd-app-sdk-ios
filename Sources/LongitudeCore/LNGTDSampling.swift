import Foundation

/// Handles per-session sampling logic.
///
/// This diverges from the web contract (which applies sampling per-event) on purpose.
/// Mobile sessions are long; per-event sampling destroys every funnel ratio. By sampling
/// per-session, a sampled session contributes all of its events, preventing funnel corruption.
public struct LNGTDSampler: Sendable {
    private let salt: String
    private let hashFunc: @Sendable (String) -> UInt64

    public init(salt: String, hash: (@Sendable (String) -> UInt64)? = nil) {
        self.salt = salt
        self.hashFunc = hash ?? Self.fnv1a
    }

    /// Evaluates whether a session should be sampled.
    ///
    /// - Parameters:
    ///   - sessionId: The session's unique identifier.
    ///   - sampleRate: The sampling rate, defined as 0-1. Rates outside this range are
    ///                 clamped to 0 (nothing sampled) or 1 (everything sampled).
    public func isSampled(sessionId: String, sampleRate: Double) -> Bool {
        // Clamped to 0...1, and it is worth being precise about what that does and does
        // not protect against — the original comment here had it backwards.
        //
        // Clamping UP to 1.0 does not prevent flooding, it causes it: a web-style `50`
        // meaning 50% becomes "sample everything". What clamping buys is that the SDK
        // cannot be made to compute nonsense from an out-of-range value, and the
        // direction is chosen deliberately — these events are revenue telemetry, so
        // over-sending is recoverable and under-sending silently deletes reporting.
        //
        // The real defence against the 100x error is that this type accepts 0...1 only
        // and the conversion happens once at the config boundary. A rate above 1 arriving
        // here means someone wired the web convention through, which is a bug to fix
        // rather than something to quietly reinterpret.
        let clampedRate = max(0.0, min(1.0, sampleRate))

        if clampedRate <= 0.0 {
            return false
        }
        if clampedRate >= 1.0 {
            return true
        }

        // Salt FIRST, then the session id. The order is not cosmetic.
        //
        // FNV-1a folds each byte in and then multiplies, so bytes processed last only
        // perturb the low bits. With the salt appended, two salts differing in their
        // final character changed the hash by roughly 3 * 2^40 — leaving the top bit
        // untouched, and the top bit is exactly what a 0.5 rate compares. The salt
        // therefore reached the hash while having no effect on the decision, which is a
        // decorative salt with extra steps. Prepending it means its bytes are diffused
        // through every subsequent multiply. Caught by testDifferentSaltChangesOutcome.
        let hashValue = hashFunc(salt + sessionId)
        let maxHash = Double(UInt64.max)
        let threshold = maxHash * clampedRate

        return Double(hashValue) < threshold
    }

    /// FNV-1a. Deterministic across processes and launches.
    ///
    /// Do not use Swift's `Hasher` or `hashValue` — they are seeded per process, so the
    /// same session id would sample in on one launch and out on the next. That is not
    /// sampling, it is noise.
    ///
    /// Declared as a `@Sendable` closure rather than a static method so it can satisfy the
    /// stored property's type without an unchecked conversion.
    private static let fnv1a: @Sendable (String) -> UInt64 = { input in
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
