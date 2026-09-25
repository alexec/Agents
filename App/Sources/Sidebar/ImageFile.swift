import AgentsKit
import AppKit
import SwiftUI

/// An image file, drawn rather than described.
///
/// This is the one place the pane reads a whole file. FR-015 forbids reading a whole
/// large file to show the start of it, and a picture has no start: the first 128 KB of
/// a PNG is not a smaller picture. AppKit does the decoding, so what gets drawn is
/// whatever this Mac can draw, and a file it cannot decode — a corrupt one, or a name on
/// the kit's list that lied about its contents — lands on `OpenElsewhere` with the same
/// words any other binary gets.
///
/// Opens fitted to the pane and never past its own size — a 48-pixel icon blown up to
/// 380 points is not a preview of the icon — and can then be zoomed into and moved
/// about, because the reason to open an agent's screenshot is usually a detail in it.
struct ImageFile: View {
    let url: URL
    /// What the pane read, so a rewrite of the same path draws again. The URL alone
    /// would not: an agent regenerating a chart writes to the same name.
    let probe: FileProbe
    let description: String
    /// The server the file is on, when it is not this Mac (037). Its picture is drawn
    /// from the bytes the server sent, and there is nowhere here to open it.
    var server: String? = nil

    @State private var image: NSImage?
    @State private var failed = false
    @State private var zoom = ImageZoom()

    var body: some View {
        Group {
            if let image {
                VStack(spacing: 0) {
                    ZoomingImage(image: image, zoom: zoom, label: url.lastPathComponent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    HStack(spacing: 6) {
                        Text(caption(for: image))
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        zoomControls
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            } else if failed {
                OpenElsewhere(url: url, description: description, server: server)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: probe) {
            let loaded = server == nil ? NSImage(contentsOf: url) : NSImage(data: probe.prefix)
            image = loaded
            failed = loaded == nil
        }
    }

    /// Out, in, and back to the whole picture, beside how close it is. Pinching and
    /// double-clicking do the same; these are for a mouse, and for finding out it zooms.
    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button(action: zoom.zoomOut) { Image(systemName: "minus.magnifyingglass") }
                .disabled(!zoom.canZoomOut)
                .help("Zoom out")
            Button(action: zoom.actualSize) {
                Text(zoom.level, format: .percent.precision(.fractionLength(0)))
                    .appText(.fine)
                    .monospacedDigit()
                    .frame(minWidth: 36)
            }
            .help("Actual size")
            Button(action: zoom.zoomIn) { Image(systemName: "plus.magnifyingglass") }
                .disabled(!zoom.canZoomIn)
                .help("Zoom in")
            Button("Fit", action: zoom.fit)
                .appText(.fine)
                .disabled(zoom.isFitted)
                .help("Fit the picture to the pane")
        }
        .buttonStyle(.borderless)
    }

    /// The kit's words for the file, then the size in pixels, which is the number a
    /// reader checking an agent's screenshot actually wants.
    private func caption(for image: NSImage) -> String {
        guard let rep = image.representations.first, rep.pixelsWide > 0 else { return description }
        return "\(description) · \(rep.pixelsWide) × \(rep.pixelsHigh)"
    }
}
