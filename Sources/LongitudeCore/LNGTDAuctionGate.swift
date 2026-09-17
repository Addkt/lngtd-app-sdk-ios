import Foundation

/// Opaque handle for a granted auction permit.
public struct LNGTDAuctionGateToken: Sendable, Equatable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
}

public protocol LNGTDAuctionGateHost: Sendable {
    func endTask(_ token: LNGTDAuctionGateToken)
}

/// Releases an auction permit exactly once, accommodating any path (success, failure, supersede).
public final class LNGTDAuctionGateRelease: @unchecked Sendable {
    private let host: LNGTDAuctionGateHost
    private let lock = NSLock()
    private var token: LNGTDAuctionGateToken?
    private var released = false

    public init(host: LNGTDAuctionGateHost) {
        self.host = host
    }

    public func arm(_ token: LNGTDAuctionGateToken) {
        lock.lock()
        if released {
            lock.unlock()
            host.endTask(token)
            return
        }
        self.token = token
        lock.unlock()
    }

    public func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        let expiring = token
        token = nil
        lock.unlock()

        guard let expiring else { return }
        host.endTask(expiring)
    }
}

public final class LNGTDAuctionGate: LNGTDAuctionGateHost, @unchecked Sendable {
    private let lock = NSLock()
    private let limit = 6
    private var nextToken = 0
    /// The tokens actually holding a permit. Counting alone is not enough: `endTask` is public
    /// protocol API, so a second call for the same token — or one for a token that never held a
    /// permit — would decrement the count and let a seventh auction run. `LNGTDAuctionGateRelease`
    /// guards its own double-release, but the gate must not depend on every caller using it.
    private var granted: Set<LNGTDAuctionGateToken> = []

    private var queue: [(token: LNGTDAuctionGateToken, onAcquire: @Sendable () -> Void)] = []

    public init() {}

    /// Requests an auction permit. If the cap is full, this request is queued LIFO (newest wins).
    public func acquire(onAcquire: @escaping @Sendable () -> Void) -> LNGTDAuctionGateToken {
        lock.lock()
        let token = LNGTDAuctionGateToken(rawValue: nextToken)
        nextToken += 1

        if granted.count < limit {
            granted.insert(token)
            lock.unlock()
            onAcquire()
        } else {
            queue.append((token: token, onAcquire: onAcquire))
            lock.unlock()
        }
        return token
    }

    public func endTask(_ token: LNGTDAuctionGateToken) {
        lock.lock()
        // If it was still in the queue, remove it. A slot torn down while queued must leave.
        if let index = queue.firstIndex(where: { $0.token == token }) {
            queue.remove(at: index)
            lock.unlock()
            return
        }

        // Only a token that actually holds a permit can release one.
        guard granted.remove(token) != nil else {
            lock.unlock()
            return
        }

        // Give the permit to the newest waiter.
        if let last = queue.popLast() {
            granted.insert(last.token)
            lock.unlock()
            last.onAcquire()
        } else {
            lock.unlock()
        }
    }
}
