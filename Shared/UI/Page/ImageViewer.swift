import AgentsKitCore
import SwiftUI

/// A forge page's image, large, in the app (#4010): on the Mac a sheet with the image fitted
/// to it, a pinch, a double-click or ⌘+ and ⌘− to zoom, Esc or Done to close; on the Remote a
/// full-screen cover with a pinch or a double tap to zoom and a swipe down to close. No
/// browser: the person stays here.
///
/// The viewer goes through the images of the same message or page (#4954): the arrows, ← and →,
/// and on the Remote a swipe sideways go to the previous and the next image. On the Mac the
/// arrows show while the pointer is over the image; on the Remote they show always.
struct ImageViewer: View {
    let images: [ViewedImage.Item]
    @State private var index: Int
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

    #if os(macOS)
    @State private var overImage = false
    #endif

    init(images: [ViewedImage.Item], start: Int) {
        self.images = images
        _index = State(initialValue: images.indices.contains(start) ? start : 0)
    }

    private var image: PlatformImage { images[index].image }
    private var label: String { images[index].alt.isEmpty ? "Image" : images[index].alt }
    private var counter: String? { ImageSequence.counter(index, of: images.count) }
    private var previous: Int? { ImageSequence.step(from: index, count: images.count, by: -1) }
    private var following: Int? { ImageSequence.step(from: index, count: images.count, by: 1) }

    /// Goes to the image at `next`, fitted.
    private func show(_ next: Int?) {
        guard let next else { return }
        #if os(macOS)
        index = next
        #else
        withAnimation(ResponseMotion.snappy) {
            index = next
            zoom = ImageViewerZoom.fit
            offset = .zero
            settled = .zero
        }
        #endif
    }

    /// The previous and the next arrows, and ← and → for them. An arrow at an end is not there.
    private var arrows: some View {
        HStack {
            arrow(previous, icon: "chevron.left", name: "Previous Image", key: .leftArrow)
            Spacer(minLength: 0)
            arrow(following, icon: "chevron.right", name: "Next Image", key: .rightArrow)
        }
        .padding(12)
    }

    private func arrow(_ target: Int?, icon: String, name: String, key: KeyEquivalent) -> some View {
        Button { show(target) } label: {
            Image(icon: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.45), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: [])
        .help("\(name) (\(key == .leftArrow ? "←" : "→"))")
        .accessibilityLabel(name)
        .opacity(target == nil ? 0 : 1)
        .disabled(target == nil)
        .accessibilityHidden(target == nil)
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            ZoomingImage(image: image, zoom: zoom, label: label)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if images.count > 1 {
                        arrows
                            .opacity(overImage ? 1 : 0)
                            .allowsHitTesting(overImage)
                            .animation(.easeOut(duration: 0.15), value: overImage)
                    }
                }
                .onHover { overImage = $0 }
            Divider()
            HStack(spacing: 6) {
                Text(label).appText(.supporting).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let counter {
                    Text(counter).appText(.supporting).foregroundStyle(.tertiary).monospacedDigit()
                        .fixedSize()
                }
                Spacer(minLength: 8)
                Button(action: zoom.zoomOut) { Image(icon: "minus.magnifyingglass") }
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
                Button(action: zoom.zoomIn) { Image(icon: "plus.magnifyingglass") }
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
            if images.count > 1 {
                arrows.frame(maxHeight: .infinity)
                if let counter {
                    Text(counter).appText(.supporting).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.2))
                .padding()
        }
        .statusBarHidden()
        #endif
    }

    #if os(macOS)
    /// As large as the largest image, inside what a sheet on this screen can be; each image is
    /// then fitted to the sheet, which does not change size from one image to the next.
    private var idealSize: CGSize {
        let bar: CGFloat = 44
        let room = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let largest = CGSize(width: images.map(\.image.size.width).max() ?? 0,
                             height: images.map(\.image.size.height).max() ?? 0)
        let fitted = ImageViewerZoom.fitted(largest, in: CGSize(width: room.width * 0.85, height: room.height * 0.8 - bar))
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

    /// Zoomed in, a drag moves the image; fitted, a swipe down closes the viewer, and a swipe
    /// left or right goes to the next or the previous image (#4954).
    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                if zoom > ImageViewerZoom.fit {
                    offset = CGSize(width: settled.width + value.translation.width,
                                    height: settled.height + value.translation.height)
                } else if sideways(value.translation), images.count > 1 {
                    offset = CGSize(width: value.translation.width, height: 0)
                } else {
                    offset = CGSize(width: 0, height: max(0, value.translation.height))
                }
            }
            .onEnded { value in
                let across = value.translation.width, flung = value.predictedEndTranslation.width
                if zoom > ImageViewerZoom.fit {
                    settled = offset
                } else if sideways(value.translation), images.count > 1,
                          let next = across < -80 || flung < -240 ? following : across > 80 || flung > 240 ? previous : nil {
                    show(next)
                } else if !sideways(value.translation),
                          value.translation.height > 120 || value.predictedEndTranslation.height > 300 {
                    dismiss()
                } else {
                    withAnimation(ResponseMotion.snappy) { offset = .zero }
                }
            }
    }

    /// Whether a drag goes more across than down.
    private func sideways(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height)
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
        sheet(item: image) { ImageViewer(images: $0.images, start: $0.start) }
        #else
        fullScreenCover(item: image) { ImageViewer(images: $0.images, start: $0.start) }
        #endif
    }
}

/// The images the viewer goes through, and the one it opens at.
struct ViewedImage: Identifiable {
    struct Item {
        let image: PlatformImage
        let alt: String
    }

    let id = UUID()
    let images: [Item]
    let start: Int
}

/// The images of one message or page that the viewer goes through (#4954), as each is read: an
/// image that opens large puts itself here, and the viewer takes them in `order`.
@MainActor
final class ImageGallery {
    private var read: [URL: ViewedImage.Item] = [:]

    func add(_ url: URL, _ item: ViewedImage.Item) { read[url] = item }

    /// The images read so far, in `order`, opened at `url`'s.
    func viewed(at url: URL, order: [URL]) -> ViewedImage? {
        guard let own = read[url] else { return nil }
        let urls = order.filter { read[$0] != nil }
        guard let start = urls.firstIndex(of: url) else { return ViewedImage(images: [own], start: 0) }
        return ViewedImage(images: urls.compactMap { read[$0] }, start: start)
    }
}

/// A message's or page's gallery and the order of its images, for its pictures to open in.
struct ImageSequenceScope {
    let gallery: ImageGallery
    let order: [URL]
}

extension EnvironmentValues {
    /// Set by `MarkdownText` on a forge's page (#4954); nil elsewhere, where an image opens alone.
    @Entry var imageSequence: ImageSequenceScope?
}
