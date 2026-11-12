import AgentsKitCore
import SwiftUI

/// A forge page's image, large, in the app (#4010): on the Mac a sheet with the image fitted
/// to it, a pinch, a double-click or ⌘+ and ⌘− to zoom, Esc or Done to close; on the Remote a
/// full-screen cover with a pinch or a double tap to zoom and a swipe down to close. No
/// browser: the person stays here.
struct ImageViewer: View {
    let image: PlatformImage
    let alt: String
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    /// AppKit's magnifying scroll view, as an image file in the pane has (`ImageFile`).
    @State private var zoom = ImageZoom()
    #else
    @State private var zoom = ImageViewerZoom.fit
    /// The level a pinch started at, while the fingers are down.
    @State private var pinchStart: Double?
    /// How far the image is moved: by the finger while zoomed, down while it is closed.
    @State private var offset = CGSize.zero
    @State private var settled = CGSize.zero
    #endif

    private var label: String { alt.isEmpty ? "Image" : alt }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            ZoomingImage(image: image, zoom: zoom, label: label)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 6) {
                Text(label).appText(.supporting).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button(action: zoom.zoomOut) { Image(systemName: "minus.magnifyingglass") }
                    .keyboardShortcut("-")
                    .disabled(!zoom.canZoomOut)
                    .help("Zoom Out (⌘−)")
                    .accessibilityLabel("Zoom Out")
                Button(action: zoom.fit) {
                    Text(zoom.level, format: .percent.precision(.fractionLength(0)))
                        .appText(.supporting).monospacedDigit()
                        .frame(minWidth: 40)
                }
                .help("Fit the image to the window")
                Button(action: zoom.zoomIn) { Image(systemName: "plus.magnifyingglass") }
                    .keyboardShortcut("+")
                    .disabled(!zoom.canZoomIn)
                    .help("Zoom In (⌘+)")
                    .accessibilityLabel("Zoom In")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .padding(.leading, 6)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // ⌘= is ⌘+ without Shift, as Safari and Preview take it.
            .background {
                Button("Zoom In", action: zoom.zoomIn)
                    .keyboardShortcut("=")
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .frame(minWidth: 480, idealWidth: idealSize.width, minHeight: 360, idealHeight: idealSize.height)
        .presentationSizing(.fitted)
        #else
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
                .opacity(1 - min(0.6, max(0, offset.height) / 400))
            // The screen is the window: the image is fitted to all of it.
            Image(platformImage: image)
                .resizable()
                .scaledToFit()
                .accessibilityLabel(label)
                .scaleEffect(zoom)
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(drag)
                .simultaneousGesture(pinch)
                .onTapGesture(count: 2) { toggleZoom() }
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.2))
                .padding()
        }
        .statusBarHidden()
        #endif
    }

    #if os(macOS)
    /// As large as the image, inside what a sheet on this screen can be; the image is then
    /// fitted to the sheet.
    private var idealSize: CGSize {
        let bar: CGFloat = 44
        let room = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let fitted = ImageViewerZoom.fitted(image.size, in: CGSize(width: room.width * 0.85, height: room.height * 0.8 - bar))
        return CGSize(width: max(480, fitted.width), height: max(360, fitted.height + bar))
    }
    #else
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? zoom
                pinchStart = start
                zoom = ImageViewerZoom.pinched(from: start, by: value.magnification)
            }
            .onEnded { _ in
                pinchStart = nil
                if zoom <= ImageViewerZoom.fit { withAnimation(ResponseMotion.snappy) { offset = .zero; settled = .zero } }
            }
    }

    /// Zoomed in, a drag moves the image; fitted, a swipe down closes the viewer.
    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                if zoom > ImageViewerZoom.fit {
                    offset = CGSize(width: settled.width + value.translation.width,
                                    height: settled.height + value.translation.height)
                } else {
                    offset = CGSize(width: 0, height: max(0, value.translation.height))
                }
            }
            .onEnded { value in
                if zoom > ImageViewerZoom.fit {
                    settled = offset
                } else if value.translation.height > 120 || value.predictedEndTranslation.height > 300 {
                    dismiss()
                } else {
                    withAnimation(ResponseMotion.snappy) { offset = .zero }
                }
            }
    }

    private func toggleZoom() {
        withAnimation(ResponseMotion.snappy) {
            zoom = zoom > ImageViewerZoom.fit ? ImageViewerZoom.fit : ImageViewerZoom.doubleTap
            offset = .zero
            settled = .zero
        }
    }
    #endif
}

extension View {
    /// The image viewer over this view while `image` is set (#4010): a sheet on the Mac, a
    /// full-screen cover on the Remote.
    func imageViewer(_ image: Binding<ViewedImage?>) -> some View {
        #if os(macOS)
        sheet(item: image) { ImageViewer(image: $0.image, alt: $0.alt) }
        #else
        fullScreenCover(item: image) { ImageViewer(image: $0.image, alt: $0.alt) }
        #endif
    }
}

/// An image the viewer shows.
struct ViewedImage: Identifiable {
    let id = UUID()
    let image: PlatformImage
    let alt: String
}
