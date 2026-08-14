#if os(iOS)
import UIKit
import LongitudeCore

/// Adapts `UIApplication`'s background task API so `LongitudeCore` never imports UIKit.
public final class UIKitBackgroundTaskHost: LNGTDBackgroundTaskHost, @unchecked Sendable {
    public init() {}

    /// `UIApplication.shared` is main-actor isolated, and the protocol is synchronous because
    /// the caller needs the token before it starts the drain.
    ///
    /// In practice this always runs on main — both callers are `UIApplication` notification
    /// callbacks — so the fast path is a direct call and the `DispatchQueue.main.sync` below is
    /// a fallback that must never be reached from main itself, which is why it is guarded.
    public func beginTask(
        expirationHandler: @escaping @Sendable () -> Void
    ) -> LNGTDBackgroundTaskToken? {
        guard !Thread.isMainThread else {
            return Self.begin(expirationHandler)
        }
        return DispatchQueue.main.sync { Self.begin(expirationHandler) }
    }

    /// Synchronous when already on main, which is the path that matters: the expiration handler
    /// means the system is already out of patience, and hopping to a `Task` there would return
    /// before the task was actually ended. It also keeps the real host's timing the same as the
    /// fake host the tests use, rather than passing tests that the real thing would fail.
    public func endTask(_ token: LNGTDBackgroundTaskToken) {
        guard !Thread.isMainThread else {
            Self.end(token)
            return
        }
        DispatchQueue.main.sync { Self.end(token) }
    }

    // Not `@MainActor`-annotated, and not `MainActor.assumeIsolated` either: that is iOS 17+
    // and this package targets iOS 14. The two callers above establish main-thread execution
    // at runtime — directly when already on main, and via `DispatchQueue.main.sync` otherwise —
    // which is what `UIApplication` actually requires. UIKit's pre-concurrency annotations let
    // this compile; the guarantee is the guard, not the type system.
    private static func begin(
        _ expirationHandler: @escaping @Sendable () -> Void
    ) -> LNGTDBackgroundTaskToken? {
        let identifier = UIApplication.shared.beginBackgroundTask(
            expirationHandler: expirationHandler
        )
        // `.invalid` means the system refused. Returning a token for it would lead to an
        // `endBackgroundTask(.invalid)`, which traps.
        guard identifier != .invalid else { return nil }
        return LNGTDBackgroundTaskToken(rawValue: identifier.rawValue)
    }

    private static func end(_ token: LNGTDBackgroundTaskToken) {
        UIApplication.shared.endBackgroundTask(
            UIBackgroundTaskIdentifier(rawValue: token.rawValue)
        )
    }
}

/// Binds an `LNGTDEventPipeline` to `UIApplication` lifecycle notifications.
///
/// Separate from the pipeline so the policy stays testable on the macOS host, and separate
/// from `Longitude` so the entry point does not become a god object. Deliberately thin: a
/// simulator is the only thing that can exercise this file.
public final class LNGTDLifecycleObserver: @unchecked Sendable {
    private let pipeline: LNGTDEventPipeline

    /// The tokens returned by `addObserver(forName:object:queue:using:)` — **these** are the
    /// observers, not `self`. `removeObserver(self)` does not remove block-based observers, so
    /// the delivered version's `deinit` removed nothing while claiming in a comment that it did.
    private var tokens: [NSObjectProtocol] = []

    public init(pipeline: LNGTDEventPipeline) {
        self.pipeline = pipeline

        // Block observers retain their closure, so `self` is captured weakly.
        observe(UIApplication.willResignActiveNotification) { $0.willResignActive() }
        observe(UIApplication.didEnterBackgroundNotification) { $0.didEnterBackground() }
        observe(UIApplication.didBecomeActiveNotification) { $0.didBecomeActive() }
    }

    private func observe(
        _ name: Notification.Name,
        _ action: @escaping (LNGTDEventPipeline) -> Void
    ) {
        let token = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            action(self.pipeline)
        }
        tokens.append(token)
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
#endif
