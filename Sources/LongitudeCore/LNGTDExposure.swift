import CoreGraphics
import Foundation

public struct LNGTDViewSnapshot: Sendable, Equatable {
    public let frameInWindow: CGRect
    public let clippingAncestors: [CGRect]
    public let windowBounds: CGRect
    public let screenBounds: CGRect
    public let cumulativeAlpha: CGFloat
    public let isAttachedToWindow: Bool
    public let hasHiddenAncestor: Bool
    public let isAppActive: Bool

    public init(
        frameInWindow: CGRect,
        clippingAncestors: [CGRect],
        windowBounds: CGRect,
        screenBounds: CGRect,
        cumulativeAlpha: CGFloat,
        isAttachedToWindow: Bool,
        hasHiddenAncestor: Bool,
        isAppActive: Bool
    ) {
        self.frameInWindow = frameInWindow
        self.clippingAncestors = clippingAncestors
        self.windowBounds = windowBounds
        self.screenBounds = screenBounds
        self.cumulativeAlpha = cumulativeAlpha
        self.isAttachedToWindow = isAttachedToWindow
        self.hasHiddenAncestor = hasHiddenAncestor
        self.isAppActive = isAppActive
    }

    public var exposurePercentage: Double {
        guard isAppActive, isAttachedToWindow, !hasHiddenAncestor, cumulativeAlpha >= 0.5 else {
            return 0.0
        }

        let area = frameInWindow.width * frameInWindow.height
        guard area > 0 else { return 0.0 }

        var visibleRect = frameInWindow
        for clippingRect in clippingAncestors {
            visibleRect = visibleRect.intersection(clippingRect)
            if visibleRect.isNull { return 0.0 }
        }

        visibleRect = visibleRect.intersection(windowBounds)
        if visibleRect.isNull { return 0.0 }

        visibleRect = visibleRect.intersection(screenBounds)
        if visibleRect.isNull { return 0.0 }

        let visibleArea = visibleRect.width * visibleRect.height
        return Double(visibleArea / area)
    }
}
