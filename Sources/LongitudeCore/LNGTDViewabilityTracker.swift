import Foundation

public protocol LNGTDViewSnapshotProvider: AnyObject, Sendable {
    func snapshot() -> LNGTDViewSnapshot?
}

public final class LNGTDViewabilityTracker: @unchecked Sendable {
    private enum DwellState {
        case idle
        case tracking(since: TimeInterval)
        case fired
    }

    private struct Entry {
        weak var provider: LNGTDViewSnapshotProvider?
        let unit: String
        var state: DwellState
    }

    /// MRC display: at least half the pixels, for at least one contiguous second.
    static let exposureThreshold = 0.5
    static let dwellThreshold: TimeInterval = 1.0
    /// 5Hz. Five samples against a one-second threshold, and one shared timer rather than a
    /// CADisplayLink per slot — twenty of those is a measurable battery and jank regression.
    static let sampleInterval: TimeInterval = 0.2

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    private let timerFactory: LNGTDEventPipelineTimerFactory
    private let queue: DispatchQueue
    private let clock: @Sendable () -> TimeInterval
    private let trackViewableImpression: @Sendable (String) -> Void

    private var timer: LNGTDEventPipelineTimer?

    public init(
        timerFactory: LNGTDEventPipelineTimerFactory = DefaultEventTimerFactory(),
        queue: DispatchQueue = .main,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        trackViewableImpression: @escaping @Sendable (String) -> Void
    ) {
        self.timerFactory = timerFactory
        self.queue = queue
        self.clock = clock
        self.trackViewableImpression = trackViewableImpression
    }

    public func register(provider: LNGTDViewSnapshotProvider, unit: String) {
        lock.lock()
        defer { lock.unlock() }
        let id = ObjectIdentifier(provider)
        entries[id] = Entry(provider: provider, unit: unit, state: .idle)
        updateTimer()
    }

    public func deregister(provider: LNGTDViewSnapshotProvider) {
        lock.lock()
        defer { lock.unlock() }
        let id = ObjectIdentifier(provider)
        entries.removeValue(forKey: id)
        updateTimer()
    }

    public func resetLatch(for provider: LNGTDViewSnapshotProvider) {
        lock.lock()
        defer { lock.unlock() }
        let id = ObjectIdentifier(provider)
        if var entry = entries[id] {
            entry.state = .idle
            entries[id] = entry
        }
    }

    private func updateTimer() {
        // Must be called with lock held
        let isEmpty = entries.isEmpty
        if isEmpty {
            timer?.suspend()
        } else {
            if timer == nil {
                timer = timerFactory.makeTimer(interval: Self.sampleInterval, queue: queue) { [weak self] in
                    self?.tick()
                }
            }
            timer?.resume()
        }
    }

    /// The dwell rules, in one place and pure so they read as a table.
    ///
    /// Returns nil when nothing changes. `fires` is set on the single tick that crosses the
    /// threshold; the caller latches to `.fired` so it cannot happen twice.
    private static func nextState(
        from current: DwellState, isExposed: Bool, now: TimeInterval
    ) -> (state: DwellState, fires: Bool)? {
        switch current {
        case .idle:
            return isExposed ? (.tracking(since: now), false) : nil
        case .tracking(let since):
            guard isExposed else {
                // CONTIGUOUS. Back to idle, discarding the accrued time — a slot that flickers
                // across 50% in a feed must not accumulate its way to a second.
                return (.idle, false)
            }
            // Wall clock, not a tick count: at 5Hz a one-second threshold is five samples, so
            // counting quantises to 200ms and drifts with jitter or a dropped tick.
            return now - since >= Self.dwellThreshold ? (.fired, true) : nil
        case .fired:
            return nil
        }
    }

    private func tick() {
        let now = clock()

        lock.lock()
        let currentEntries = entries
        lock.unlock()

        var toRemove: [ObjectIdentifier] = []
        var toUpdate: [ObjectIdentifier: DwellState] = [:]
        var toFire: [String] = []

        for (id, entry) in currentEntries {
            // The view is gone. This is the only removal path: see the nil-snapshot note below.
            guard let provider = entry.provider else {
                toRemove.append(id)
                continue
            }

            // A nil snapshot means "no sample available this tick" — the observer returns nil
            // off the main thread, where UIView geometry cannot be read. It does NOT mean the
            // slot is gone. Removing the entry here would silently deregister a live slot for
            // the rest of its life on a single mistimed tick.
            guard let snapshot = provider.snapshot() else { continue }

            let isExposed = snapshot.exposurePercentage >= Self.exposureThreshold
            guard let next = Self.nextState(from: entry.state, isExposed: isExposed, now: now)
            else { continue }

            toUpdate[id] = next.state
            if next.fires {
                toFire.append(entry.unit)
            }
        }

        lock.lock()
        for id in toRemove {
            entries.removeValue(forKey: id)
        }
        for (id, state) in toUpdate where entries[id] != nil {
            entries[id]?.state = state
        }
        updateTimer()
        lock.unlock()

        for unit in toFire {
            fireEvent(unit: unit)
        }
    }

    private func fireEvent(unit: String) {
        trackViewableImpression(unit)
    }

    /// Per-slot state for the debug overlay and tests. A struct rather than a three-member
    /// tuple, which swiftlint caps at two.
    public struct SlotState: Sendable, Equatable {
        public let exposure: Double
        public let dwell: TimeInterval
        public let fired: Bool

        public init(exposure: Double, dwell: TimeInterval, fired: Bool) {
            self.exposure = exposure
            self.dwell = dwell
            self.fired = fired
        }
    }

    public func state(for provider: LNGTDViewSnapshotProvider) -> SlotState {
        lock.lock()
        let entry = entries[ObjectIdentifier(provider)]
        lock.unlock()

        guard let entry = entry, let snap = entry.provider?.snapshot() else {
            return SlotState(exposure: 0, dwell: 0, fired: false)
        }

        let exposure = snap.exposurePercentage
        var dwell: TimeInterval = 0
        var fired = false

        switch entry.state {
        case .idle:
            break
        case .tracking(let since):
            if exposure >= Self.exposureThreshold {
                dwell = clock() - since
            }
        case .fired:
            dwell = Self.dwellThreshold
            fired = true
        }

        return SlotState(exposure: exposure, dwell: dwell, fired: fired)
    }
}
