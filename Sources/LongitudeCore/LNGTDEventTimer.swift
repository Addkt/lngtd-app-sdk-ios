import Foundation

public protocol LNGTDEventPipelineTimer: Sendable {
    func resume()
    func suspend()
    func cancel()
}

public protocol LNGTDEventPipelineTimerFactory: Sendable {
    func makeTimer(
        interval: TimeInterval, queue: DispatchQueue?, handler: @escaping @Sendable () -> Void
    ) -> LNGTDEventPipelineTimer
}

/// The repeating flush, on a serial `.utility` queue.
///
/// `DispatchSourceTimer` rather than `Timer`: a `Timer` needs a run loop, and a
/// `DispatchQueue` worker thread has none. Scheduling one there fires nothing, crashes
/// nothing and logs nothing — the timer looks installed and every batch silently waits for a
/// size or lifecycle trigger instead.
public final class DispatchSourceEventTimer: LNGTDEventPipelineTimer, @unchecked Sendable {
    private enum State {
        case suspended
        case resumed
        case cancelled
    }

    private let source: DispatchSourceTimer
    private let lock = NSLock()
    private var state: State = .suspended

    public init(interval: TimeInterval, queue: DispatchQueue? = nil, handler: @escaping @Sendable () -> Void) {
        let timerQueue = queue ?? DispatchQueue(label: "com.lngtd.sdk.events.timer", qos: .utility)
        source = DispatchSource.makeTimerSource(queue: timerQueue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler(handler: handler)
    }

    public func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard state == .suspended else { return }
        source.resume()
        state = .resumed
    }

    public func suspend() {
        lock.lock()
        defer { lock.unlock() }
        guard state == .resumed else { return }
        source.suspend()
        state = .suspended
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard state != .cancelled else { return }
        // Releasing a *suspended* dispatch source traps. Resume it first so the cancel can
        // take effect, then cancel. This is a crash, not a warning, and it only reproduces on
        // the path where the app backgrounds and is then torn down without returning.
        if state == .suspended {
            source.resume()
        }
        source.cancel()
        state = .cancelled
    }

    deinit {
        cancel()
    }
}

public struct DefaultEventTimerFactory: LNGTDEventPipelineTimerFactory {
    public init() {}

    public func makeTimer(
        interval: TimeInterval, queue: DispatchQueue? = nil, handler: @escaping @Sendable () -> Void
    ) -> LNGTDEventPipelineTimer {
        DispatchSourceEventTimer(interval: interval, queue: queue, handler: handler)
    }
}
