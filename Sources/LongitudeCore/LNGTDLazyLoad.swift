import CoreGraphics
import Foundation

public enum LNGTDLazyLoad {

    /// Determines whether a slot should load based on its distance from the effective viewport.
    ///
    /// - Parameters:
    ///   - snapshot: The current view geometry of the slot.
    ///   - marginPoints: The distance in points around the viewport where slots should eagerly load.
    /// - Returns: `true` if the slot is within `marginPoints` of the visible viewport. The boundary
    ///   is inclusive (a slot exactly `marginPoints` away will load).
    public static func shouldLoad(snapshot: LNGTDViewSnapshot, marginPoints: CGFloat) -> Bool {
        guard snapshot.isAttachedToWindow else { return false }

        let area = snapshot.frameInWindow.width * snapshot.frameInWindow.height
        guard area > 0 else { return false }

        // Compute the effective viewport by intersecting all boundaries.
        var viewport = snapshot.windowBounds.intersection(snapshot.screenBounds)
        for clippingRect in snapshot.clippingAncestors {
            viewport = viewport.intersection(clippingRect)
        }

        // If the viewport itself is completely obscured or collapsed, nothing is near it.
        if viewport.isNull { return false }

        let expandedViewport = viewport.insetBy(dx: -marginPoints, dy: -marginPoints)
        let frame = snapshot.frameInWindow

        // Inclusive boundary check: if the frame touches the expanded viewport edges, it loads.
        return frame.minX <= expandedViewport.maxX && frame.maxX >= expandedViewport.minX &&
               frame.minY <= expandedViewport.maxY && frame.maxY >= expandedViewport.minY
    }
}
