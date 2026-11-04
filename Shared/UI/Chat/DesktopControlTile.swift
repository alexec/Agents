import AgentsKitCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The words of the live tile (#3004, US4); the web page's are in
/// `Web/src/model/desktopControlWords.ts`.
enum DesktopControlTileWords {
    static let title = "Driving the Mac's screen"
    static let locked = "Mac is locked"
    static let lockedBody = "The agent keeps working. No picture is shown while the screen is locked."
    static let waiting = "Waiting for the first look at the screen…"
    static func label(_ narration: String?) -> String {
        [title, narration].compactMap { $0 }.joined(separator: ": ")
    }
}

/// An agent driving the Mac's screen (#3004, US4, FR-011), as a tile at the end of the
/// transcript: the latest still of the screen, or "Mac is locked" with no picture (FR-012),
/// and the agent's last action in words. Frames come from `desktopControl/liveFrame` while
/// the agent holds the screen lease; the host sends one at least every 5 seconds, so a tile
/// that has heard none for `DesktopControlLiveFrame.staleAfter` takes itself away. The
/// window and the Remote both draw it; the web page's is `DesktopControlTile.tsx`.
struct DesktopControlTile: View {
    let frame: DesktopControlLiveFrame
    /// When this client heard it (`AgentsModel.liveFrameHeardAt`).
    let heardAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if DesktopControlLiveFrame.isFresh(heardAt: heardAt, now: context.date) {
                tile
            }
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(DesktopControlTileWords.title, systemImage: "display")
                .appText(.supporting).fontWeight(.semibold)
                .foregroundStyle(.secondary)
            picture
            if let narration = frame.narration {
                Text(narration)
                    .appText(.reading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(frame.locked == true
                            ? DesktopControlTileWords.label(DesktopControlTileWords.locked)
                            : DesktopControlTileWords.label(frame.narration))
    }

    @ViewBuilder private var picture: some View {
        if frame.locked == true {
            placeholder(symbol: "lock", title: DesktopControlTileWords.locked, body: DesktopControlTileWords.lockedBody)
        } else if let data = frame.imageData, let image = Self.image(data) {
            image
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity)
        } else {
            placeholder(symbol: "display", title: DesktopControlTileWords.waiting, body: nil)
        }
    }

    private func placeholder(symbol: String, title: String, body: String?) -> some View {
        VStack(spacing: 6) {
            // Decorative: the words under it say the same.
            Image(systemName: symbol).font(.title2)
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

    private static func image(_ data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map(Image.init(nsImage:))
        #else
        UIImage(data: data).map(Image.init(uiImage:))
        #endif
    }
}
