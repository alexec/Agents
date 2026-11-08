import Foundation

/// How large the Remote's image viewer draws a forge page's image (#4010): 1 is the image
/// fitted to the screen; above 1 it is that, enlarged. The Mac's viewer is AppKit's own
/// magnifying scroll view (`ZoomingImage`), as an image file in the pane is.
public enum ImageViewerZoom {
    public static let fit = 1.0
    public static let most = 8.0
    /// How close a double tap goes from fitted.
    public static let doubleTap = 2.5

    /// The size an image of `natural` size is drawn at to fit in `room`: smaller to fit, never
    /// larger than it is.
    public static func fitted(_ natural: CGSize, in room: CGSize) -> CGSize {
        guard natural.width > 0, natural.height > 0, room.width > 0, room.height > 0 else { return .zero }
        let scale = min(1, room.width / natural.width, room.height / natural.height)
        return CGSize(width: natural.width * scale, height: natural.height * scale)
    }

    /// The level a pinch has reached: where it started, times how far the fingers moved,
    /// between fitted and the most.
    public static func pinched(from start: Double, by magnification: Double) -> Double {
        let level = start * magnification
        guard level.isFinite else { return fit }
        return min(max(level, fit), most)
    }
}
