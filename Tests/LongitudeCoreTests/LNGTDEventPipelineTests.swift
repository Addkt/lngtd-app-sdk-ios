import XCTest
@testable import LongitudeCore

final class PipelineFakeTransport: LNGTDEventTransport, @unchecked Sendable {
    private let lock = NSLock()
    var payloads: [Data] = []
    var result: LNGTDEventTransportResult = .success

    var isPaused = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func send(payload: Data, endpoint: LNGTDEndpoint) async -> LNGTDEventTransportResult {
        let shouldPause: Bool
        let resultToReturn: LNGTDEventTransportResult

        lock.lock()
        payloads.append(payload)
        shouldPause = isPaused
        resultToReturn = result
        lock.unlock()

        if shouldPause {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                continuations.append(continuation)
                lock.unlock()
            }
        }

        return resultToReturn
    }

    func callCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return payloads.count
    }

    func unpause() {
        lock.lock()
        let toResume = continuations
        continuations.removeAll()
        isPaused = false
        lock.unlock()

        for c in toResume {
            c.resume()
        }
    }
}

final class PipelineFakeHost: LNGTDBackgroundTaskHost, @unchecked Sendable {
    private let lock = NSLock()
    var begins = 0
    var ends = 0
    var refuseTasks = false
    var expirationHandlers: [() -> Void] = []

    func beginTask(expirationHandler: @escaping @Sendable () -> Void) -> LNGTDBackgroundTaskToken? {
        lock.lock()
        defer { lock.unlock() }
        if refuseTasks { return nil }
        begins += 1
        expirationHandlers.append(expirationHandler)
        return LNGTDBackgroundTaskToken(rawValue: begins)
    }

    func endTask(_ token: LNGTDBackgroundTaskToken) {
        lock.lock()
        defer { lock.unlock() }
        ends += 1
    }

    func fireLastExpiration() {
        lock.lock()
        let handler = expirationHandlers.last
        lock.unlock()
        handler?()
    }
}

final class PipelineFakeTimer: LNGTDEventPipelineTimer, @unchecked Sendable {
    let factory: PipelineFakeTimerFactory
    var isActive = false

    init(factory: PipelineFakeTimerFactory) {
        self.factory = factory
    }

    func resume() {
        if !isActive {
            isActive = true
            factory.activeTimersCount += 1
        }
    }

    func suspend() {
        if isActive {
            isActive = false
            factory.activeTimersCount -= 1
        }
    }

    func cancel() {
        suspend()
    }
}

final class PipelineFakeTimerFactory: LNGTDEventPipelineTimerFactory, @unchecked Sendable {
    var activeTimersCount = 0
    var lastHandler: (() -> Void)?
    var createdCount = 0

    func makeTimer(interval: TimeInterval, handler: @escaping @Sendable () -> Void) -> LNGTDEventPipelineTimer {
        createdCount += 1
        lastHandler = handler
        return PipelineFakeTimer(factory: self)
    }

    func fireTick() {
        lastHandler?()
    }
}

/// Settable clock shared by the pipeline and the queue it builds.
final class PipelineTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TimeInterval = 0

    var now: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

final class LNGTDEventPipelineTests: XCTestCase {

    private var baseDir: URL = FileManager.default.temporaryDirectory
    private let clock = PipelineTestClock()

    override func setUp() {
        super.setUp()
        baseDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: baseDir)
        super.tearDown()
    }

    /// A struct rather than a four-member tuple: swiftlint caps tuples at two, and named
    /// fields read better at every call site anyway.
    struct SUT {
        let pipeline: LNGTDEventPipeline
        let transport: PipelineFakeTransport
        let host: PipelineFakeHost
        let timerFactory: PipelineFakeTimerFactory
    }

    private func makeSUT() -> SUT {
        let transport = PipelineFakeTransport()
        let host = PipelineFakeHost()
        let factory = PipelineFakeTimerFactory()
        return SUT(
            pipeline: makePipeline(transport: transport, host: host, factory: factory),
            transport: transport,
            host: host,
            timerFactory: factory
        )
    }

    private func makePipeline(
        transport: LNGTDEventTransport,
        host: LNGTDBackgroundTaskHost? = nil,
        factory: LNGTDEventPipelineTimerFactory = PipelineFakeTimerFactory()
    ) -> LNGTDEventPipeline {
        let store = LNGTDEventStore(baseDirectory: baseDir)
        return LNGTDEventPipeline(
            store: store,
            transport: transport,
            backgroundHost: host,
            isSampled: { true },
            tickInterval: 1.0,
            clock: { [clock] in clock.now },
            timerFactory: factory
        )
    }

    private func makeEvent() -> LNGTDEvent {
        // Use a non-immediate event to test queueing and batch flushing
        LNGTDEvent(
            event: .sdkInit,
            details: LNGTDEvent.Details(
                account: "test",
                section: "test",
                deviceType: .phone,
                custom: LNGTDEventCustomDetails(platform: .ios)
            )
        )
    }

    func test01_TickCallsThroughToFlush() async {
        let sut = makeSUT()
        let pipeline = sut.pipeline
        let transport = sut.transport
        let timerFactory = sut.timerFactory
        pipeline.start()
        await pipeline.quiesce()

        await pipeline.queue.enqueue(makeEvent())

        XCTAssertEqual(transport.callCount(), 0, "Should not flush immediately on enqueue")

        pipeline.didBecomeActive()
        // The timer only polls; LNGTDEventQueue's own 5000ms gate decides whether a tick
        // flushes. Advance past it, or the tick is correctly a no-op.
        clock.now += 5.0
        timerFactory.fireTick()
        await pipeline.quiesce()
        await pipeline.queue.awaitPendingSends()

        XCTAssertEqual(transport.callCount(), 1, "Tick should have triggered a flush")
    }

    func test02_WillResignActiveFlushesWithoutBackgroundTask() async {
        let sut = makeSUT()
        let pipeline = sut.pipeline
        let transport = sut.transport
        let host = sut.host
        pipeline.start()
        await pipeline.quiesce()

        await pipeline.queue.enqueue(makeEvent())

        pipeline.willResignActive()
        await pipeline.quiesce()
        await pipeline.queue.awaitPendingSends()

        XCTAssertEqual(transport.callCount(), 1, "Should have flushed pending batch")
        XCTAssertEqual(host.begins, 0, "Should not begin a background task on willResignActive")
    }

    func test03_DidEnterBackgroundBeginsAndEndsExactlyOneTask() async {
        let sut = makeSUT()
        let pipeline = sut.pipeline
        let transport = sut.transport
        let host = sut.host
        pipeline.start()
        await pipeline.quiesce()

        await pipeline.queue.enqueue(makeEvent())

        pipeline.didEnterBackground()
        await pipeline.quiesce()

        XCTAssertEqual(host.begins, 1, "Should begin exactly one task")
        XCTAssertEqual(host.ends, 1, "Should end exactly one task on natural completion")
        XCTAssertEqual(transport.callCount(), 1, "Drain should have fired")
    }

    func test04_ExpirationHandlerEndsTaskExactlyOnce() async {
        let transport = PipelineFakeTransport()
        let host = PipelineFakeHost()
        let pipeline = makePipeline(transport: transport, host: host)
        pipeline.start()
        await pipeline.quiesce()

        transport.isPaused = true

        await pipeline.queue.enqueue(makeEvent())
        pipeline.didEnterBackground()

        // The background task is begun, drain is paused in the transport layer
        host.fireLastExpiration()

        XCTAssertEqual(host.begins, 1, "Task should have begun")
        XCTAssertEqual(host.ends, 1, "Expiration handler should end the task immediately")

        transport.unpause()
        await pipeline.quiesce()

        XCTAssertEqual(host.ends, 1, "Finishing the drain after expiration should not double-end")
    }

    func test05_NormalCompletionAfterExpirationDoesNotEndAgain() async {
        // Extremely similar to 04, verifying the exactly-once lock in TaskSentinel explicitly.
        let transport = PipelineFakeTransport()
        let host = PipelineFakeHost()
        let pipeline = makePipeline(transport: transport, host: host)
        pipeline.start()
        await pipeline.quiesce()

        transport.isPaused = true

        await pipeline.queue.enqueue(makeEvent())
        pipeline.didEnterBackground()

        host.fireLastExpiration()
        XCTAssertEqual(host.ends, 1, "Task ended by expiration")

        transport.unpause()
        await pipeline.quiesce()

        XCTAssertEqual(host.ends, 1, "Task not ended twice after normal completion")
    }

    func test06_BeginTaskRefusedStillDrainsAndNeverEnds() async {
        let sut = makeSUT()
        let pipeline = sut.pipeline
        let transport = sut.transport
        let host = sut.host
        pipeline.start()
        await pipeline.quiesce()

        host.refuseTasks = true
        await pipeline.queue.enqueue(makeEvent())

        pipeline.didEnterBackground()
        await pipeline.quiesce()

        XCTAssertEqual(transport.callCount(), 1, "Drain still occurs even if task refused")
        XCTAssertEqual(host.begins, 0, "Task refused")
        XCTAssertEqual(host.ends, 0, "Refused task should never be ended")
    }

    func test07_DoubleDidEnterBackgroundDoesNotLeakToken() async {
        let sut = makeSUT()
        let pipeline = sut.pipeline
        let host = sut.host
        pipeline.start()
        await pipeline.quiesce()

        pipeline.didEnterBackground()
        await pipeline.quiesce()

        pipeline.didEnterBackground()
        await pipeline.quiesce()

        XCTAssertEqual(host.begins, 2, "Began twice")
        XCTAssertEqual(host.ends, 2, "Ended twice securely without leaking")
    }

    func test08_LaunchDrainDeliversLeftoverRecords() async {
        let store = LNGTDEventStore(baseDirectory: baseDir)
        let event = makeEvent()
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(event)) ?? Data()
        store.append(lines: [data])

        let transport = PipelineFakeTransport()
        let host = PipelineFakeHost()
        let pipeline = LNGTDEventPipeline(
            store: store,
            transport: transport,
            backgroundHost: host,
            isSampled: { true },
            clock: { [clock] in clock.now }
        )

        pipeline.start()
        await pipeline.quiesce()

        XCTAssertEqual(transport.callCount(), 1, "Launch drain delivered the leftover record")
        XCTAssertEqual(host.begins, 0, "Launch drain does not begin background tasks")
    }

    func test09_DidBecomeActiveLeavesExactlyOneLiveTimer() async {
        let sut = makeSUT()
        let pipeline = sut.pipeline
        let timerFactory = sut.timerFactory
        pipeline.start()
        await pipeline.quiesce()

        pipeline.didBecomeActive()
        XCTAssertEqual(timerFactory.activeTimersCount, 1, "Timer is active")

        pipeline.didEnterBackground()
        await pipeline.quiesce()
        XCTAssertEqual(timerFactory.activeTimersCount, 0, "Timer suspended in background")

        pipeline.didBecomeActive()
        XCTAssertEqual(timerFactory.activeTimersCount, 1, "Timer is active again, not duplicated")
        XCTAssertEqual(timerFactory.createdCount, 1, "Did not create a new timer unnecessarily")
    }

    func test10_FailedSendStaysOnDiskAndDeliversOnNextLaunch() async {
        let sut = makeSUT()
        let pipeline1 = sut.pipeline
        let transport1 = sut.transport
        pipeline1.start()
        await pipeline1.quiesce()

        transport1.result = .failed

        await pipeline1.queue.enqueue(makeEvent())
        pipeline1.willResignActive()
        await pipeline1.quiesce()
        await pipeline1.queue.awaitPendingSends()

        XCTAssertEqual(transport1.callCount(), 1, "Failed attempt was made")

        // Next launch
        let transport2 = PipelineFakeTransport()
        let pipeline2 = makePipeline(transport: transport2)
        pipeline2.start()
        await pipeline2.quiesce()

        XCTAssertEqual(transport2.callCount(), 1, "Relaunch drain picked up the failed batch")
    }
}
