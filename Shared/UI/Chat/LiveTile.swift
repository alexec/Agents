import AgentsKitCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The words of the live tile (#3004, #4140); the web page's are in
/// `Web/src/model/liveTileWords.ts`.
enum LiveTileWords {
    static let screen = "Screen"
    static let browser = "Agent Browser"
    static let simulator = "Simulator"
    static let locked = "Mac is locked"
    static let lockedBody = "The agent keeps working. No picture is shown while the screen is locked."
    static let open = "Open"
    static let switchLabel = "Show"

    /// The tile's head: "Screen", the page's title, or the simulator's name.
    static func name(_ frame: LiveFrame) -> String {
        switch frame.source {
        case .screen: screen
        case .browser: frame.title.flatMap { $0.isEmpty ? nil : $0 } ?? browser
        case .simulator: frame.title.flatMap { $0.isEmpty ? nil : $0 } ?? simulator
        }
    }

    /// The source's own name, for the switch between two.
    static func kind(_ source: LiveSource) -> String {
        switch source {
        case .screen: screen
        case .browser: browser
        case .simulator: simulator
        }
    }

    static func symbol(_ source: LiveSource) -> String {
        switch source {
        case .screen: "display"
        case .browser: "globe"
        case .simulator: "iphone"
        }
    }

    /// The Now card's line while it drives one (#5033): "Driving the screen".
    static func driving(_ frame: LiveFrame) -> String {
        switch frame.source {
        case .screen: "Driving the screen"
        case .browser: "Driving the browser"
        case .simulator: "Driving the simulator"
        }
    }

    static func waiting(_ source: LiveSource) -> String {
        switch source {
        case .screen: "Waiting for the first look at the screen…"
        case .browser: "Waiting for the first look at the page…"
        case .simulator: "Waiting for the first look at the simulator…"
        }
    }

    static func openHelp(_ source: LiveSource) -> String {
        source == .simulator ? "Use the simulator yourself." : "Use the page yourself."
    }

    /// What the picture says to VoiceOver: the source, then the agent's last action.
    static func label(_ frame: LiveFrame) -> String {
        [name(frame), frame.locked == true ? locked : frame.narration].compactMap { $0 }.joined(separator: ": ")
    }
}

/// What an agent drives (#3004, #4138, #4140), as one tile at the end of the transcript: the
/// newest frame of the screen, the agent browser or a simulator, its source by name and the
/// agent's last action in words. While the screen is locked, "Mac is locked" and no picture
/// (FR-012). Frames come from `live/frame` while the agent drives the source and the chat is
/// in front; a source not heard from for `DesktopControlLiveFrame.staleAfter` drops out, and
/// with none left the tile takes itself away. With two sources at once, a small switch picks
/// one. Open, on the browser or a simulator, is the person's own use of it. The window and the
/// Remote both draw it; the web page's is `LiveTile.tsx`.
struct LiveTile: View {
    let frames: [LiveSource: HeardLiveFrame]
    /// Open the source for the person to use, or nil where it cannot be opened (a chat in a
    /// window of its own on the Mac). Never offered for the screen: its access is Take Over.
    var open: ((LiveSource) -> Void)?

    @State private var chosen: LiveSource?
    @Environment(\.nowOpen) private var nowOpen

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let fresh = LiveTiles.fresh(frames, now: context.date)
            if let shown = LiveTiles.shown(frames, chosen: chosen, now: context.date) {
                tile(shown.frame, sources: fresh.map(\.frame.source))
            } else {
                // Its frames stopped: the Now card's working line, until the agent is done.
                NowHead(title: NowWords.working) { WorkingRing(size: 16, doing: true) }
            }
        }
    }

    /// A part of the Now card (#5033): "Driving the browser · what it did last" as its head,
    /// and, while the card is open (it opens with a picture), the picture, the switch and Open.
    private func tile(_ frame: LiveFrame, sources: [LiveSource]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NowHead(title: LiveTileWords.driving(frame), detail: frame.locked == true ? LiveTileWords.locked : frame.narration) {
                Image(icon: LiveTileWords.symbol(frame.source)).foregroundStyle(.secondary)
            }
            if nowOpen?.wrappedValue ?? true {
                picture(frame)
                if sources.count > 1 || (frame.source != .screen && open != nil) {
                    HStack(spacing: 8) {
                        Text(LiveTileWords.name(frame))
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if sources.count > 1 {
                            switcher(frame.source, sources: sources)
                        }
                        if frame.source != .screen, let open {
                            Button(LiveTileWords.open) { open(frame.source) }
                                .buttonStyle(.paper)
                                .help(LiveTileWords.openHelp(frame.source))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// One icon per source the agent drives now, the shown one picked.
    private func switcher(_ shown: LiveSource, sources: [LiveSource]) -> some View {
        Picker(LiveTileWords.switchLabel, selection: Binding(get: { shown }, set: { chosen = $0 })) {
            ForEach(sources.sorted { $0.rawValue < $1.rawValue }, id: \.self) { source in
                Image(icon: LiveTileWords.symbol(source))
                    .accessibilityLabel(LiveTileWords.kind(source))
                    .help(LiveTileWords.kind(source))
                    .tag(source)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder private func picture(_ frame: LiveFrame) -> some View {
        Group {
            if frame.locked == true {
                placeholder(symbol: "lock", title: LiveTileWords.locked, body: LiveTileWords.lockedBody)
            } else if let data = frame.imageData, let image = Self.image(data) {
                image
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    // A glance, not the whole chat: Open is for a closer look.
                    .frame(maxWidth: .infinity, maxHeight: Self.pictureHeight)
            } else {
                placeholder(symbol: LiveTileWords.symbol(frame.source), title: LiveTileWords.waiting(frame.source), body: nil)
            }
        }
        // One element for the picture and the words under it, which say what it shows.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LiveTileWords.label(frame))
        .accessibilityAddTraits(.isImage)
    }

    private func placeholder(symbol: String, title: String, body: String?) -> some View {
        VStack(spacing: 6) {
            // Decorative: the words under it say the same.
            Image(icon: symbol).font(.title2)
            Text(title).appText(.reading).fontWeight(.semibold)
            if let body {
                Text(body).appText(.supporting).multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.secondary)
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    /// The picture's tallest, in points; the web page's is `.live-tile .desktop-tile-picture`.
    static let pictureHeight: CGFloat = 320

    private static func image(_ data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}
