#if DEBUG
import AppKit
import Foundation
import SwiftTerm

/// The window drawn into a PNG by itself (#1172), with its sheet and child windows over it
/// where they sit, at the screen's scale or at one asked for (#1855: a video's 2× on a 1×
/// screen). No window server capture, so a locked screen still gets a picture.
///
/// Every view draws into its layer first, then the layer tree is rendered (`render(in:)`):
/// SwiftUI draws most of a page as plain layers with no view, which `cacheDisplay` leaves
/// out. What a layer render cannot draw is drawn again over it: glass and a scroll view's
/// edge show their content through portals, a selected sidebar row is a material, and the
/// terminal draws only when asked. The spike behind this is in the PR for #1172.
@MainActor
enum WalkShot {
    /// A drawn window, made into a PNG off the main thread: the encoding was a fifth of a
    /// shot's time, and a video takes several a second (#1078). Nothing draws into it after.
    struct Drawn: @unchecked Sendable {
        let canvas: NSBitmapImageRep
        var png: Data? { canvas.representation(using: .png, properties: [:]) }
    }

    /// Without `shadows`, the layers' shadows are left out: a layer render blurs each one in
    /// software, most of a shot's time, too slow for a video's frames (#1078).
    static func picture(of window: NSWindow, shadows: Bool = true, scale: CGFloat? = nil) -> Drawn? {
        prepare(window)
        let scale = scale ?? window.backingScaleFactor
        guard window.contentView != nil else { return nil }
        let over = [window.attachedSheet].compactMap { $0 } + (window.childWindows ?? []).filter(\.isVisible)
        // A clear layer draws nothing, but a layer render still draws all under it, through
        // a picture of its own: a pane SwiftUI keeps by its opacity was most of a shot's
        // time (#1078). Hidden while the shot is drawn, as are shadows when not wanted, and
        // the sidebar's faint tint (5%), drawn the same way over all of the sidebar.
        var shadowed: [(CALayer, Float)] = []
        var clear: [CALayer] = []
        func visit(_ layer: CALayer) {
            if layer.opacity < 0.1, !layer.isHidden { clear.append(layer); return }
            if !shadows, layer.shadowOpacity > 0 { shadowed.append((layer, layer.shadowOpacity)) }
            layer.sublayers?.forEach(visit)
        }
        for each in [window] + over { (each.contentView?.superview ?? each.contentView)?.layer.map(visit) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowed.forEach { $0.0.shadowOpacity = 0 }
        clear.forEach { $0.isHidden = true }
        defer {
            shadowed.forEach { $0.0.shadowOpacity = $0.1 }
            clear.forEach { $0.isHidden = false }
            CATransaction.commit()
        }
        for each in [window] + over { (each.contentView?.superview ?? each.contentView).map { redraw($0, scale: scale) } }
        return picture(size: window.frame.size, scale: scale) {
            for (index, layer) in ([window] + over).enumerated() {
                guard let view = layer.contentView?.superview ?? layer.contentView else { continue }
                // Where it sits on the window, in points from the window's bottom left.
                let origin = index == 0 ? .zero
                    : CGPoint(x: layer.frame.minX - window.frame.minX, y: layer.frame.minY - window.frame.minY)
                let place = CGRect(origin: origin, size: layer.frame.size)
                render(view, in: place)
            }
        }
    }

    /// Every view draws into its layer: a window that is not on screen (locked, covered)
    /// has left that for later. Before the canvas is made the current context: drawn while
    /// it was, SwiftUI's text layers kept a picture upside down (#1078).
    ///
    /// At a `scale` over the screen's, each layer is drawn again at that scale first, so its
    /// text is sharp on the canvas, not a 1× picture made bigger (#1855).
    private static func redraw(_ root: NSView, scale: CGFloat? = nil) {
        root.layoutSubtreeIfNeeded()
        if let scale, let layer = root.layer, scale > (root.window?.backingScaleFactor ?? scale) {
            func sharpen(_ layer: CALayer) {
                defer { layer.sublayers?.forEach(sharpen) }
                // Only a layer that draws its own contents (text, a path) is drawn again at
                // the scale. One whose contents were given it (a symbol, an image) keeps them
                // and its scale: asked to draw, it would be left empty.
                guard layer.contentsScale != scale, draws(layer) else { return }
                layer.contentsScale = scale
                layer.setNeedsDisplay()
            }
            sharpen(layer)
        }
        for view in [root] + root.subviews(of: NSView.self) where !view.isHiddenOrHasHiddenAncestor {
            view.needsDisplay = true
            view.displayIfNeeded()
        }
    }

    /// Whether `layer` makes its own contents: through its delegate (a view), or as a class
    /// that draws (SwiftUI's text).
    private static func draws(_ layer: CALayer) -> Bool {
        if let delegate = layer.delegate,
           delegate.responds(to: #selector(CALayerDelegate.draw(_:in:))) || delegate.responds(to: #selector(CALayerDelegate.display(_:))) {
            return true
        }
        let type: AnyClass = type(of: layer)
        return [#selector(CALayer.draw(in:)), #selector(CALayer.display)].contains {
            class_getMethodImplementation(type, $0) != class_getMethodImplementation(CALayer.self, $0)
        }
    }

    /// `root`'s layer tree rendered as it stands, once `redraw` has had every view draw.
    /// SwiftUI draws much of a page as plain layers with no view, which only this reaches.
    private static func render(_ root: NSView, in place: CGRect) {
        // A rect in `root`'s points to one on the canvas, which counts from the bottom left.
        let canvas = { (rect: CGRect) -> CGRect in
            let y = root.isFlipped ? root.bounds.height - rect.maxY : rect.minY
            return CGRect(x: place.minX + rect.minX, y: place.minY + y, width: rect.width, height: rect.height)
        }
        let again = { (view: NSView, within: CGRect) in
            renderLayer(of: view, at: canvas(view.convert(view.bounds, to: root)), clip: canvas(within))
        }
        renderLayer(of: root, at: place, clip: place)
        for view in root.subviews(of: NSView.self) where isShown(view) {
            let name = view.className
            if name.contains("GlassEffectView") {
                // Glass shows its content through a portal, which a layer render leaves out:
                // the content again, over the glass.
                for content in view.subviews where !content.isHidden && !isMaterial(content) {
                    again(content, content.convert(content.bounds, to: root))
                }
            } else if let clip = view as? NSClipView {
                // A scroll view with an edge effect shows its content through one too.
                let shown = clip.convert(clip.visibleRect, to: root)
                for content in clip.subviews where !content.isHidden { again(content, shown) }
            } else if let table = view as? NSTableView {
                selection(of: table, root: root, canvas: canvas)
            } else if view is TerminalView || name.hasPrefix("_NSTheme") {
                // The terminal and the window's buttons draw only when asked to, which a
                // layer render does not do.
                draw(view, view.bounds, at: canvas(view.convert(view.bounds, to: root)))
            }
        }
    }

    /// A selected row is drawn with a vibrant colour, which comes out black off screen: the
    /// grey of a window that is not key, which a scratch window never is, and the row's cells
    /// over it again.
    private static func selection(of table: NSTableView, root: NSView, canvas: (CGRect) -> CGRect) {
        guard let shown = table.enclosingScrollView.map({ $0.contentView.convert($0.contentView.visibleRect, to: root) }) else { return }
        for row in table.selectedRowIndexes {
            guard let rowView = table.rowView(atRow: row, makeIfNecessary: false), isShown(rowView) else { continue }
            // A sidebar's selection is a material view in the row; a plain list's is drawn
            // into the row's content.
            let pill = rowView.subviews.first(where: { $0 is NSVisualEffectView })?.frame
                ?? rowView.layer?.sublayers?.first(where: { $0.className.contains("ContentLayer") })?.frame ?? rowView.bounds
            let place = canvas(rowView.convert(pill, to: root))
            guard let context = NSGraphicsContext.current?.cgContext else { continue }
            context.saveGState()
            context.clip(to: canvas(shown))
            rowView.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: place, xRadius: 5, yRadius: 5).fill()
            }
            context.restoreGState()
            for cell in rowView.subviews where isShown(cell) && !isMaterial(cell) && !cell.className.contains("Separator") {
                // Over the grey, so not `cacheDisplay`, which fills the cell white; and turned
                // over from what the rule says, as a row's cell is.
                renderLayer(of: cell, at: canvas(cell.convert(cell.bounds, to: root)), clip: canvas(shown),
                            flip: cell.isFlipped == cell.layer?.isGeometryFlipped)
            }
        }
    }

    /// Not hidden, by itself or above: SwiftUI hides a pane it keeps by its opacity.
    private static func isShown(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let now = current {
            if now.isHidden || now.alphaValue == 0 || now.layer?.isHidden == true || now.layer?.opacity == 0 { return false }
            current = now.superview
        }
        return true
    }

    /// The `n`th view whose class name holds `name` (`name#2`), for looking at one view.
    static func pick(_ name: String, in window: NSWindow) -> NSView? {
        let parts = name.split(separator: "#")
        let nth = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        guard let root = window.contentView?.superview, let first = parts.first else { return nil }
        let all = ([root] + root.subviews(of: NSView.self)).filter { $0.className.contains(first) }
        return all.indices.contains(nth - 1) ? all[nth - 1] : nil
    }

    /// One view's layer tree at `place` on the canvas, cut to `clip`.
    private static func renderLayer(of view: NSView, at place: CGRect, clip: CGRect, flip: Bool? = nil) {
        guard let layer = view.layer, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: clip)
        context.translateBy(x: place.minX, y: place.minY)
        // A flipped view's layer counts from its top left, the canvas from its bottom left.
        if flip ?? (view.isFlipped != layer.isGeometryFlipped) {
            context.translateBy(x: 0, y: place.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        context.restoreGState()
    }

    /// One view only, the first whose class name holds `name` (`name#2`, the second): to
    /// see what draws.
    static func picture(ofView name: String, in window: NSWindow) -> Drawn? {
        prepare(window)
        guard let view = pick(name, in: window) else { return nil }
        redraw(view)
        return picture(size: view.bounds.size, scale: window.backingScaleFactor) { render(view, in: CGRect(origin: .zero, size: view.bounds.size)) }
    }

    /// What a window that is not on screen leaves for later, made now: a locked or covered
    /// window's table and outline make no row views until they are drawn on screen.
    static func prepare(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        for table in window.contentView?.subviews(of: NSTableView.self) ?? [] {
            let rows = table.rows(in: table.visibleRect)
            guard rows.length > 0 else { continue }
            for row in rows.location..<(rows.location + rows.length) {
                _ = table.rowView(atRow: row, makeIfNecessary: true)
            }
        }
    }

    private static func picture(size: CGSize, scale: CGFloat, _ draw: () -> Void) -> Drawn? {
        guard size.width >= 1, size.height >= 1,
              let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                            pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        canvas.size = size
        // The canvas counts in pixels: everything is drawn in points (#1078, a Retina screen).
        context.cgContext.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return Drawn(canvas: canvas)
    }

    /// Glass, a material, a scroll edge: drawn on screen from what is behind the window, and
    /// as a flat fill off it, which would cover the content.
    private static func isMaterial(_ view: NSView) -> Bool {
        let name = view.className
        return ["Glass", "VisualEffect", "Backdrop", "Pocket", "NSCoreHostingView", "TitlebarBackground"].contains { name.contains($0) }
    }

    private static func draw(_ view: NSView, _ rect: CGRect, at place: CGRect) {
        guard rect.width >= 1, rect.height >= 1, var rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        // At the canvas's scale, not the screen's (#1855).
        let scale = abs(NSGraphicsContext.current?.cgContext.ctm.a ?? 1)
        if scale > CGFloat(rep.pixelsWide) / rect.width,
           let sharp = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width * scale), pixelsHigh: Int(rect.height * scale),
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            sharp.size = rect.size
            rep = sharp
        }
        view.cacheDisplay(in: rect, to: rep)
        rep.draw(in: place)
    }
}
#endif
