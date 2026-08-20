import Foundation
import Network

public protocol LNGTDConnectionMonitor: Sendable {
    /// Returns the current active connection type.
    ///
    /// The vocabulary is chosen once to match contract §5 and must remain stable:
    /// - "wifi"
    /// - "cellular"
    /// - "wired"
    /// - "loopback"
    /// - "other"
    /// - "unknown"
    func currentConnection() -> String?
}

/// A lock-guarded box to hold the current connection string.
public final class LNGTDConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _connection: String?

    public init(connection: String? = nil) {
        self._connection = connection
    }

    public var connection: String? {
        lock.lock()
        defer { lock.unlock() }
        return _connection
    }

    public func update(connection: String?) {
        lock.lock()
        defer { lock.unlock() }
        self._connection = connection
    }
}

public final class DefaultConnectionMonitor: LNGTDConnectionMonitor, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "com.lngtd.sdk.connection-monitor")
    private let box = LNGTDConnectionBox()

    private let lock = NSLock()
    private var isCancelled = false

    public init() {
        self.monitor = NWPathMonitor()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            // "Each path type maps to its own stable string and no two collide."
            let connectionStr: String
            if path.usesInterfaceType(.wifi) {
                connectionStr = "wifi"
            } else if path.usesInterfaceType(.cellular) {
                connectionStr = "cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                connectionStr = "wired"
            } else if path.usesInterfaceType(.loopback) {
                connectionStr = "loopback"
            } else if path.usesInterfaceType(.other) {
                connectionStr = "other"
            } else {
                connectionStr = "unknown"
            }

            // Only update if not cancelled
            self.lock.lock()
            let cancelled = self.isCancelled
            self.lock.unlock()

            if !cancelled {
                self.box.update(connection: connectionStr)
            }
        }

        monitor.start(queue: queue)
    }

    public func currentConnection() -> String? {
        return box.connection
    }

    public func cancel() {
        lock.lock()
        if !isCancelled {
            isCancelled = true
            monitor.cancel()
        }
        lock.unlock()
    }

    deinit {
        cancel()
    }
}
