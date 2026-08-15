import Foundation

/// Opaque handle for a granted background task. `Int`-backed so the UIKit adapter can carry
/// a `UIBackgroundTaskIdentifier` without Core knowing the type exists.
public struct LNGTDBackgroundTaskToken: Sendable, Equatable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
}

public protocol LNGTDBackgroundTaskHost: Sendable {
    /// Returns nil when the system refuses. `expirationHandler` may run at any time, on any
    /// thread, including before this call has returned.
    func beginTask(expirationHandler: @escaping @Sendable () -> Void) -> LNGTDBackgroundTaskToken?
    func endTask(_ token: LNGTDBackgroundTaskToken)
}

/// Releases a background task token exactly once, from whichever of the two paths arrives
/// first: the drain finishing, or the system's expiration handler.
///
/// All three failure modes here are traps or kills rather than warnings. Never ending a task
/// gets the app killed by the watchdog (`0x8badf00d`) — in the publisher's app, blamed on
/// this SDK. Ending one twice traps. Ending an identifier the system never granted traps.
private final class BackgroundTaskRelease: @unchecked Sendable {
    private let host: LNGTDBackgroundTaskHost
    private let onRelease: @Sendable () -> Void
    private let lock = NSLock()
    private var token: LNGTDBackgroundTaskToken?
    private var released = false

    init(host: LNGTDBackgroundTaskHost, onRelease: @escaping @Sendable () -> Void) {
        self.host = host
        self.onRelease = onRelease
    }

    /// Hands over the token once `beginTask` has returned. The expiration handler is allowed
    /// to fire before that happens, so a release that already occurred has to end this token
    /// on arrival rather than storing it and leaking it.
    func arm(_ token: LNGTDBackgroundTaskToken) {
        lock.lock()
        if released {
            lock.unlock()
            host.endTask(token)
            onRelease()
            return
        }
        self.token = token
        lock.unlock()
    }

    func release() {
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
        onRelease()
    }
}

/// Assembles the store, transport, durable sink and queue, and owns the lifecycle policy.
///
/// Publishers never see this. `Longitude` builds one and hands it to the UIKit adapter.
public final class LNGTDEventPipeline: @unchecked Sendable {
    public enum Trigger: String, Sendable {
        case launch
        case didBecomeActive
        case willResignActive
        case didEnterBackground
    }

    public struct Diagnostics: Sendable {
        public let pendingQueueDepth: Int
        public let storedRecordCount: Int
        public let ticksFired: Int
        public let lastTrigger: Trigger?
        public let isBackgroundTaskActive: Bool
        public let sessionId: String
        public let sessionDepth: Int
        public let page: String?
        public let referrer: String?
        public let isSampled: Bool?
    }

    public let queue: LNGTDEventQueue
    public let sink: LNGTDDurableEventSink
    public let store: LNGTDEventStore
    public let session: LNGTDSession

    /// Hardcoding `.phone` here would label every iPad as a phone, and phone-versus-tablet is a
    /// targeting dimension the warehouse reports on — a systematic mislabel nothing surfaces.
    /// Determining it needs `UIDevice`, so `LongitudeGAM` supplies it; Core defaults to `.phone`
    /// only because `Details.deviceType` has no default and the macOS host cannot know.
    private let deviceType: LNGTDDeviceType

    private let metadata: @Sendable () -> LNGTDDeviceMetadata?
    private let configVersion: @Sendable () -> String?

    private let backgroundHost: LNGTDBackgroundTaskHost?
    private let timerFactory: LNGTDEventPipelineTimerFactory
    private let tickInterval: TimeInterval

    private let lock = NSLock()
    private var timer: LNGTDEventPipelineTimer?
    private var ticksFired = 0
    private var lastTrigger: Trigger?
    private var liveBackgroundTasks = 0

    /// Tail of a chain of fire-and-forget work, so `quiesce()` can await all of it. One task
    /// at a time, each awaiting its predecessor: bounded memory, and the chain unwinds as it
    /// drains. The same shape as `LNGTDEventQueue`'s send chain.
    private var workTail: Task<Void, Never>?
    private var workGeneration = 0

    /// - Parameter session: the session tracker.
    /// - Parameter isSampled: Required, with no default. 2e-1 decided sampling per session and
    ///   2e-3 made the queue take that decision; a default of `{ true }` here would let 2e-6
    ///   ship with sampling silently disabled, which the collector would feel as volume rather
    ///   than as a bug. Making it required means the omission cannot happen quietly.
    /// - Parameter tickInterval: How often the timer polls, **not** the flush interval. The
    ///   flush interval is `LNGTDEventQueue`'s own 5000ms gate (`logging.js:263`), which stays
    ///   the single source of truth. Polling faster than that gate is deliberate: two
    ///   independent five-second gates in series silently drop any tick that arrives a hair
    ///   early, and the next one is five seconds later — so a 5s timer against a 5s gate gives
    ///   a worst-case flush latency of ten seconds. A one-second poll costs a cheap
    ///   already-flushed-recently check and removes the drift entirely.
    /// - Parameter clock: Shared with the queue so a test can advance time for both at once.
    public init(
        store: LNGTDEventStore,
        transport: LNGTDEventTransport,
        backgroundHost: LNGTDBackgroundTaskHost?,
        session: LNGTDSession = LNGTDSession(),
        isSampled: @escaping @Sendable () -> Bool,
        metadata: @escaping @Sendable () -> LNGTDDeviceMetadata? = { nil },
        configVersion: @escaping @Sendable () -> String? = { nil },
        deviceType: LNGTDDeviceType = .phone,
        tickInterval: TimeInterval = 1.0,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        timerFactory: LNGTDEventPipelineTimerFactory = DefaultEventTimerFactory()
    ) {
        self.store = store
        self.deviceType = deviceType
        self.backgroundHost = backgroundHost
        self.session = session
        self.tickInterval = tickInterval
        self.timerFactory = timerFactory
        self.metadata = metadata
        self.configVersion = configVersion

        let sink = LNGTDDurableEventSink(store: store, transport: transport)
        self.sink = sink
        self.queue = LNGTDEventQueue(sink: sink, clock: clock, isSampled: isSampled)
    }

    // MARK: - API

    public func trackScreenView(_ name: String) {
        // One snapshot, so the event cannot mix one screen's name with another's depth.
        let state = session.trackScreenView(name)
        let meta = metadata()

        let custom = LNGTDEventCustomDetails(
            platform: .ios,
            appBundle: meta?.appBundle,
            appVersion: meta?.appVersion,
            sdkVersion: LNGTDSDKVersion,
            osVersion: meta?.osVersion,
            deviceModel: meta?.deviceModel,
            ifa: meta?.ifa,
            ifaType: meta?.ifaType,
            attStatus: meta?.attStatus,
            connection: nil, // 2e-8
            sessionId: state.sessionId,
            configVersion: configVersion(),
            pageviewId: state.pageviewId
        )

        let details = LNGTDEvent.Details(
            page: state.page,
            // A screen name, not a URL. `referrer_url` is the wire name the warehouse already
            // reads; the plan maps the previous screen onto it rather than inventing a key.
            referrerUrl: state.referrer,
            deviceType: deviceType,
            sessionDepth: state.sessionDepth,
            custom: custom
        )

        let event = LNGTDEvent(event: .pageview, details: details)
        let queue = self.queue
        chain { await queue.enqueue(event) }
    }

    // MARK: - Lifecycle

    /// Kicks the launch drain. Never blocks: `Longitude.start()` is measured at ~7ms in the
    /// demo and the drain reads a file and POSTs.
    ///
    /// Separate from `init` on purpose — constructing a pipeline should have no side effects,
    /// or every test and preview that builds one issues a network request.
    ///
    /// A launch drain and a backgrounding drain may overlap. That is safe because
    /// `LNGTDEventStore.remove(records:)` matches by bytes with multiset semantics, so each
    /// caller removes exactly the records it claimed. The safety comes from the store, **not**
    /// from mutual exclusion here — do not "fix" this by serialising the two, which would only
    /// add latency to the live path.
    public func start() {
        record(trigger: .launch)

        // Start the timer here rather than waiting for `didBecomeActive`. That notification
        // has already been delivered by the time a publisher calling `Longitude.start()` from
        // anywhere other than `didFinishLaunching` gets here — a SwiftUI `.onAppear`, say — and
        // then no timer is ever installed and nothing flushes on an interval until the app has
        // been backgrounded and reopened once.
        installTimerIfNeeded().resume()

        let sink = self.sink
        chain { await sink.drain() }
    }

    /// The app came back to the foreground: install the timer if needed, and resume it.
    public func didBecomeActive() {
        record(trigger: .didBecomeActive)
        installTimerIfNeeded().resume()
    }

    /// The app merely lost focus — Control Centre, the notification shade, an incoming call,
    /// the app switcher, a permission alert. Frequent, and none of it means the app is going
    /// away, so this flushes what is pending and deliberately does **not** take a background
    /// task: the system will not grant time to an app that is not backgrounding.
    public func willResignActive() {
        record(trigger: .willResignActive)
        let queue = self.queue
        chain { await queue.flush() }
    }

    /// The app is actually backgrounding. Suspend the timer, take a background task, drain,
    /// and release the task exactly once.
    public func didEnterBackground() {
        record(trigger: .didEnterBackground)
        suspendTimer()

        let sink = self.sink
        let queue = self.queue

        // Flush BEFORE draining, and do both inside the background task.
        //
        // `drain()` only sends what is already on disk, so draining alone leaves up to 49
        // events sitting in memory to die with the process. `willResignActive` does flush, and
        // in the real UIKit sequence it fires first — but relying on that ordering means the
        // flush happens *outside* the protected window, where its POST and its disk write can
        // be cut off by suspension, and any records it just persisted are then not drained.
        let finish: @Sendable () async -> Void = {
            await queue.flush()
            await queue.awaitPendingSends()
            await sink.drain()
        }

        guard let host = backgroundHost else {
            chain(finish)
            return
        }

        let release = BackgroundTaskRelease(host: host) { [weak self] in
            self?.noteBackgroundTaskEnded()
        }

        guard let token = host.beginTask(expirationHandler: { release.release() }) else {
            // The system refused. Drain best-effort with whatever cycles remain, and never
            // call `endTask` — doing so on an identifier that was never granted traps.
            chain(finish)
            return
        }

        release.arm(token)
        noteBackgroundTaskBegan()

        chain {
            await finish()
            // The expiration handler may already have released this. Ending the task is
            // mandatory; finishing the drain is not — anything still on disk is what the
            // next launch drain is for.
            release.release()
        }
    }

    // MARK: - Diagnostics

    public func diagnostics() async -> Diagnostics {
        let pending = await queue.pendingEvents().count
        // Not `readAll()`: that reports a skipped-line count on every call, so a debug overlay
        // polling it would re-report the same corrupt line once per refresh.
        let stored = store.storedRecordCount()
        let snapshot = stateSnapshot()

        return Diagnostics(
            pendingQueueDepth: pending,
            storedRecordCount: stored,
            ticksFired: snapshot.ticks,
            lastTrigger: snapshot.trigger,
            isBackgroundTaskActive: snapshot.liveTasks > 0,
            sessionId: session.sessionId,
            sessionDepth: session.sessionDepth,
            page: session.page,
            referrer: session.referrer,
            isSampled: session.isSampledDecision
        )
    }

    // MARK: - Test seam

    /// Awaits every piece of fire-and-forget work this pipeline has started.
    ///
    /// The lifecycle methods are called from notification callbacks, which cannot await, so
    /// they spawn work and return. Without this a test asserting straight after
    /// `willResignActive()` observes nothing having happened yet — which is exactly how six of
    /// the delivered tests failed.
    func quiesce() async {
        while true {
            let (tail, generation) = tailSnapshot()
            guard let tail else { return }
            _ = await tail.value
            // Work chained while we were awaiting has to be awaited too, or a test that
            // triggers two transitions races the second one.
            if tailSnapshot().generation == generation { return }
        }
    }

    // MARK: - Private

    /// Every lock acquisition below sits in a **synchronous** method on purpose. `NSLock.lock()`
    /// inside an `async` function is an error in the Swift 6 language mode, and the delivered
    /// version took the lock in `diagnostics()` and inside two `Task` bodies.
    private func chain(_ body: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = workTail
        workGeneration += 1
        workTail = Task {
            _ = await previous?.value
            await body()
        }
        lock.unlock()
    }

    private func tailSnapshot() -> (tail: Task<Void, Never>?, generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (workTail, workGeneration)
    }

    private func record(trigger: Trigger) {
        lock.lock()
        lastTrigger = trigger
        lock.unlock()
    }

    private func recordTick() {
        lock.lock()
        ticksFired += 1
        lock.unlock()
    }

    private func noteBackgroundTaskBegan() {
        lock.lock()
        liveBackgroundTasks += 1
        lock.unlock()
    }

    private func noteBackgroundTaskEnded() {
        lock.lock()
        liveBackgroundTasks = max(0, liveBackgroundTasks - 1)
        lock.unlock()
    }

    private struct StateSnapshot {
        let ticks: Int
        let trigger: Trigger?
        let liveTasks: Int
    }

    private func stateSnapshot() -> StateSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return StateSnapshot(
            ticks: ticksFired, trigger: lastTrigger, liveTasks: liveBackgroundTasks
        )
    }

    /// Returns the single timer, creating it once. Reinstalling instead of resuming leaves the
    /// old source alive and the flush fires twice per interval, which is invisible without a
    /// test that counts ticks rather than asserting one happened.
    private func installTimerIfNeeded() -> LNGTDEventPipelineTimer {
        lock.lock()
        if let existing = timer {
            lock.unlock()
            return existing
        }

        let queue = self.queue
        let created = timerFactory.makeTimer(interval: tickInterval) { [weak self] in
            guard let self else { return }
            self.recordTick()
            self.chain { await queue.tick() }
        }
        timer = created
        lock.unlock()
        return created
    }

    private func suspendTimer() {
        lock.lock()
        let existing = timer
        lock.unlock()
        existing?.suspend()
    }

    deinit {
        timer?.cancel()
    }
}
