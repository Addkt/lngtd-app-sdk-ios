#if os(iOS)
import Foundation
import UIKit
import LongitudeCore

/// Wrapper to bridge MainActor UIKit state to the non-isolated Tracker.
private final class ViewSnapshotProvider: LNGTDViewSnapshotProvider, @unchecked Sendable {
    weak var view: UIView?

    init(view: UIView) {
        self.view = view
    }

    /// Returns nil rather than sampling off the main thread. `UIView` geometry is main-actor
    /// state; the tracker treats nil as a skipped tick and keeps the registration.
    func snapshot() -> LNGTDViewSnapshot? {
        guard Thread.isMainThread, let view = view else { return nil }
        return LNGTDViewSnapshotBuilder.compute(for: view)
    }
}

@MainActor
public final class LNGTDViewabilityObserver {
    private let tracker: LNGTDViewabilityTracker
    private var providers: [ObjectIdentifier: ViewSnapshotProvider] = [:]

    public init(tracker: LNGTDViewabilityTracker) {
        self.tracker = tracker
    }

    public func register(view: UIView, unit: String) {
        cleanUp()
        let id = ObjectIdentifier(view)
        let provider = ViewSnapshotProvider(view: view)
        providers[id] = provider
        tracker.register(provider: provider, unit: unit)
    }

    public func deregister(view: UIView) {
        let id = ObjectIdentifier(view)
        if let provider = providers.removeValue(forKey: id) {
            tracker.deregister(provider: provider)
        }
    }

    public func resetLatch(for view: UIView) {
        let id = ObjectIdentifier(view)
        if let provider = providers[id] {
            tracker.resetLatch(for: provider)
        }
    }

    public func state(for view: UIView) -> LNGTDViewabilityTracker.SlotState {
        let id = ObjectIdentifier(view)
        guard let provider = providers[id] else {
            return LNGTDViewabilityTracker.SlotState(exposure: 0, dwell: 0, fired: false)
        }
        return tracker.state(for: provider)
    }

    private func cleanUp() {
        var toRemove: [ObjectIdentifier] = []
        for (id, provider) in providers where provider.view == nil {
            toRemove.append(id)
            tracker.deregister(provider: provider)
        }
        for id in toRemove {
            providers.removeValue(forKey: id)
        }
    }

}

/// Builds a snapshot from a live view hierarchy.
///
/// Deliberately outside the `@MainActor` observer, and not `MainActor.assumeIsolated` either:
/// that is iOS 17+ and this package targets iOS 14. Every caller establishes main-thread
/// execution at runtime first — UIKit's pre-concurrency annotations let this compile, and the
/// runtime guard is the guarantee rather than the type system.
enum LNGTDViewSnapshotBuilder {
    static func compute(for view: UIView) -> LNGTDViewSnapshot {
        // We do not currently attempt to determine if the window is covered by a modal
        // because there is no reliable public API to detect disjoint view hierarchies
        // overlaying this view. This errs on the side of over-reporting viewability
        // if a modal covers the slot, which is the safer failure mode than silencing revenue.

        let isAppActive = UIApplication.shared.applicationState == .active

        guard let window = view.window else {
            return LNGTDViewSnapshot(
                frameInWindow: .zero,
                clippingAncestors: [],
                windowBounds: .zero,
                screenBounds: .zero,
                cumulativeAlpha: 1.0,
                isAttachedToWindow: false,
                hasHiddenAncestor: false,
                isAppActive: isAppActive
            )
        }

        var hasHiddenAncestor = view.isHidden
        var cumulativeAlpha = view.alpha
        var clippingAncestors: [CGRect] = []

        let frameInWindow = view.convert(view.bounds, to: window)

        var currentAncestor: UIView? = view.superview
        while let ancestor = currentAncestor {
            if ancestor.isHidden {
                hasHiddenAncestor = true
            }
            cumulativeAlpha *= ancestor.alpha

            if ancestor.clipsToBounds {
                let ancestorFrame = ancestor.convert(ancestor.bounds, to: window)
                clippingAncestors.append(ancestorFrame)
            }

            currentAncestor = ancestor.superview
        }

        let screen = window.screen
        let screenBounds = window.convert(screen.bounds, from: screen.coordinateSpace)

        return LNGTDViewSnapshot(
            frameInWindow: frameInWindow,
            clippingAncestors: clippingAncestors.reversed(),
            windowBounds: window.bounds,
            screenBounds: screenBounds,
            cumulativeAlpha: cumulativeAlpha,
            isAttachedToWindow: true,
            hasHiddenAncestor: hasHiddenAncestor,
            isAppActive: isAppActive
        )
    }
}
#endif
