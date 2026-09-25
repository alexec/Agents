import AppKit
import SwiftUI

/// How close the reader is looking at a picture, and the buttons' way of changing it.
///
/// The scroll view owns the magnification — a pinch changes it without asking — so
/// this only mirrors it for the caption and passes the buttons' requests through.
@MainActor @Observable
final class ImageZoom {
    /// The magnification as last seen, where 1 is one point of the picture to one point
    /// of the screen.
    private(set) var level: CGFloat = 1
    /// Whether the picture is fitted to the pane, and so refits as the pane is resized.
    private(set) var isFitted = true
    fileprivate weak var view: ZoomingImageScrollView?

    var canZoomIn: Bool { (view?.maxMagnification ?? 0) > level + 0.001 }
    var canZoomOut: Bool { (view?.minMagnification ?? .infinity) < level - 0.001 }

    func zoomIn() { view?.step(by: 1.5) }
    func zoomOut() { view?.step(by: 1 / 1.5) }
    func fit() { view?.fit() }
    func actualSize() { view?.zoom(to: 1, at: nil) }

    fileprivate func saw(level: CGFloat, fitted: Bool) {
        if self.level != level { self.level = level }
        if isFitted != fitted { isFitted = fitted }
    }
}

/// A picture that opens fitted to the pane and can be looked into: pinch or the
/// buttons to zoom, scroll to move about, double-click to go between fitted and actual
/// size at the place clicked.
///
/// AppKit's own magnifying scroll view rather than a SwiftUI scale: a scale effect
/// leaves the layout the size it was, so a zoomed picture could not be scrolled to its
/// edges, which are the details a screenshot is zoomed into to read.
struct ZoomingImage: NSViewRepresentable {
    let image: NSImage
    let zoom: ImageZoom
    let label: String

    func makeNSView(context: Context) -> ZoomingImageScrollView {
        let view = ZoomingImageScrollView(image: image, zoom: zoom)
        view.imageView.setAccessibilityLabel(label)
        return view
    }

    func updateNSView(_ view: ZoomingImageScrollView, context: Context) {
        view.zoom = zoom
        zoom.view = view
        view.imageView.setAccessibilityLabel(label)
        if view.imageView.image !== image { view.show(image) }
    }
}

final class ZoomingImageScrollView: NSScrollView {
    let imageView = NSImageView()
    fileprivate var zoom: ImageZoom
    /// Most a picture is blown up past its own size. Past this a screenshot is squares.
    private static let most: CGFloat = 8

    fileprivate init(image: NSImage, zoom: ImageZoom) {
        self.zoom = zoom
        super.init(frame: .zero)
        contentView = CentringClipView()
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        allowsMagnification = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageFrameStyle = .none
        documentView = imageView
        zoom.view = self

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked(_:)))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)

        NotificationCenter.default.addObserver(self, selector: #selector(magnified),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: self)
        show(image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Draws a new picture, fitted. A rewrite of the file is a new picture, and where
    /// the reader was in the old one says nothing about the new one.
    func show(_ image: NSImage) {
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        fitted = true
        fit()
    }

    /// Whether to refit as the pane changes size. Cleared by any zoom but a fit.
    private var fitted = true

    /// The magnification that shows the whole picture, never more than its own size:
    /// a 48-point icon blown up to fill the pane is not a preview of the icon.
    private var fitLevel: CGFloat {
        let size = imageView.frame.size
        let room = contentView.frame.size
        guard size.width > 0, size.height > 0, room.width > 0, room.height > 0 else { return 1 }
        return min(1, room.width / size.width, room.height / size.height)
    }

    override func layout() {
        super.layout()
        minMagnification = fitLevel
        maxMagnification = max(Self.most, fitLevel)
        if fitted, abs(magnification - fitLevel) > 0.0001 { magnification = fitLevel }
        report()
    }

    func fit() {
        fitted = true
        minMagnification = fitLevel
        maxMagnification = max(Self.most, fitLevel)
        magnification = fitLevel
        report()
    }

    fileprivate func step(by factor: CGFloat) {
        zoom(to: magnification * factor, at: nil)
    }

    /// Zooms keeping `point` — in the picture's coordinates — where it is on screen, or
    /// the middle of what is showing when there is no point.
    fileprivate func zoom(to level: CGFloat, at point: NSPoint?) {
        let level = min(maxMagnification, max(minMagnification, level))
        let centre = point ?? NSPoint(x: documentVisibleRect.midX, y: documentVisibleRect.midY)
        setMagnification(level, centeredAt: centre)
        fitted = abs(level - fitLevel) < 0.0001
        report()
    }

    @objc private func doubleClicked(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: imageView)
        if fitted {
            // A picture smaller than the pane is already at its own size when fitted,
            // so going "to actual size" would do nothing; twice as close instead.
            zoom(to: fitLevel < 1 ? 1 : 2, at: point)
        } else {
            fit()
        }
    }

    @objc private func magnified() {
        fitted = abs(magnification - fitLevel) < 0.0001
        report()
    }

    private func report() {
        zoom.saw(level: magnification, fitted: fitted)
    }
}

/// Keeps a picture smaller than the pane in the middle of it, rather than pinned to the
/// bottom-left corner where AppKit puts a document that does not fill its clip view.
private final class CentringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
