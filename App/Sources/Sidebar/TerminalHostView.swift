import AgentsKit
import AppKit
import SwiftTerm
import SwiftUI

/// SwiftTerm's view, in SwiftUI, wired to a shell the daemon owns.
///
/// SwiftTerm has a `LocalProcessTerminalView` that spawns the process itself. It is not
/// used: the process belongs to the daemon so it can outlive this window, and this view
/// is only a screen and a keyboard. Bytes come in from the daemon, keystrokes go back
/// out to it.
struct TerminalHostView: NSViewRepresentable {
    let client: ShellClient
    /// Told the size whenever the view is laid out, so the pty can be resized and a
    /// full-screen program reflows (FR-021).
    let onSize: (Int, Int) -> Void
    /// Read so that a change of appearance calls `updateNSView`, where the paper
    /// colours are resolved again: SwiftTerm takes a colour's value when it is set.
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(client: client, onSize: onSize)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400))
        view.terminalDelegate = context.coordinator
        view.configureNativeColors()
        Self.paint(view)
        context.coordinator.view = view

        // Everything the daemon sends is fed here. The emulator is this side of the
        // socket and the daemon parses nothing (plan decision 2).
        client.onOutput = { [weak view] data in
            guard let view else { return }
            view.feed(byteArray: Array(data)[...])
        }
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.client = client
        Self.paint(view)
    }

    /// On paper, like the page around it. Only the ground, the ink, the caret and the
    /// selection: the sixteen ANSI colours are the program's to choose.
    private static func paint(_ view: TerminalView) {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.nativeBackgroundColor = NSColor.paperGround.usingColorSpace(.sRGB) ?? .paperGround
            view.nativeForegroundColor = NSColor.paperInk.usingColorSpace(.sRGB) ?? .paperInk
            view.caretColor = NSColor.paperInk.usingColorSpace(.sRGB) ?? .paperInk
            view.selectedTextBackgroundColor = NSColor.paperSelection.usingColorSpace(.sRGB) ?? .paperSelection
        }
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        var client: ShellClient
        let onSize: (Int, Int) -> Void
        weak var view: TerminalView?
        private var lastReported: (rows: Int, cols: Int) = (0, 0)

        init(client: ShellClient, onSize: @escaping (Int, Int) -> Void) {
            self.client = client
            self.onSize = onSize
        }

        // What the user typed. Bytes, not text: a keystroke is not always a character,
        // and ^C goes this way, through the line discipline, exactly as in any terminal
        // rather than through a separate signal call.
        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            Task { @MainActor in await self.client.send(bytes) }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in
                guard (newRows, newCols) != (self.lastReported.rows, self.lastReported.cols) else { return }
                self.lastReported = (newRows, newCols)
                self.onSize(newRows, newCols)
            }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            let text = String(decoding: content, as: UTF8.self)
            Task { @MainActor in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }

        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            // A link in a terminal is the user's to follow, and it goes to their real
            // browser. The pane's browser is for what they type into it (FR-035).
            Task { @MainActor in
                guard let url = URL(string: link), url.scheme == "http" || url.scheme == "https" else { return }
                NSWorkspace.shared.open(url)
            }
        }

        nonisolated func bell(source: TerminalView) {}

        nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}
