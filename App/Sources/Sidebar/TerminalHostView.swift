import AgentsKitCore
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
    /// Set once when the user brings this tab forward or opens it, and cleared through
    /// `focused` once the keyboard is here. Every tab's view stays in the window, so
    /// without it typing would go on into a shell nobody can see (055). A request
    /// rather than "is on top", so a pane built while hidden takes nothing from the
    /// prompt.
    var wantsFocus = false
    var focused: () -> Void = {}
    /// Whether this is the tab on top. One behind lets go of the keyboard.
    var isFront = true
    /// ⌘T and ⌘W while the terminal has the keyboard (#401).
    var newTab: () -> Void = {}
    var closeTab: () -> Void = {}
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
        // The emulator this shell had on screen before, taken up as it was: no rebuild,
        // and no replay of everything it printed (#401).
        if let kept = client.screen as? KeyedTerminalView {
            kept.removeFromSuperview()
            kept.terminalDelegate = context.coordinator
            kept.newTab = newTab
            kept.closeTab = closeTab
            context.coordinator.view = kept
            Self.paint(kept)
            return kept
        }
        let view = KeyedTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400))
        client.screen = view
        view.newTab = newTab
        view.closeTab = closeTab
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
        if let view = view as? KeyedTerminalView {
            view.newTab = newTab
            view.closeTab = closeTab
        }
        Self.paint(view)
        if wantsFocus {
            // After this layout pass: a view made in this update has no window yet.
            DispatchQueue.main.async { [weak view, focused] in
                if let view, let window = view.window { window.makeFirstResponder(view) }
                focused()
            }
        } else if !isFront, let window = view.window, window.firstResponder === view {
            window.makeFirstResponder(nil)
        }
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
            // Queued here, on the main thread SwiftTerm calls from, so keystrokes keep
            // their order: a task each could overtake one another (#401).
            if Thread.isMainThread {
                MainActor.assumeIsolated { self.client.type(bytes) }
            } else {
                Task { @MainActor in self.client.type(bytes) }
            }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in
                guard (newRows, newCols) != (self.lastReported.rows, self.lastReported.cols) else { return }
                self.lastReported = (newRows, newCols)
                self.onSize(newRows, newCols)
            }
        }

        // Called as the emulator reads the bytes, on the main thread.
        nonisolated func setTerminalTitle(source: TerminalView, title: String) {
            Task { @MainActor in self.client.title = title }
        }

        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // OSC 7 says a file: URL; the "This shell is in" strip follows it (#401).
            Task { @MainActor in
                self.client.directory = directory.flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0 : nil }
            }
        }
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            let text = String(decoding: content, as: UTF8.self)
            Task { @MainActor in
                // Only while the person is at this terminal: a program printing in a
                // tab nobody is looking at does not get to replace the clipboard (#401).
                guard let view = self.view, let window = view.window, window.isKeyWindow,
                      window.firstResponder === view else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }

        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            // A link in a terminal is the user's to follow, and it goes to their real
            // browser. The pane's browser is for what they type into it (FR-035).
            Task { @MainActor in
                guard let url = URL(string: link), url.scheme == "http" || url.scheme == "https" else { return }
                NSWorkspace.shared.open(url)  // store-ok: web links only, checked above
            }
        }

        nonisolated func bell(source: TerminalView) {
            Task { @MainActor in
                // Heard only from the terminal on screen in the window in front.
                guard let view = self.view, let window = view.window, window.isKeyWindow,
                      window.firstResponder === view else { return }
                NSSound.beep()
            }
        }

        nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}

/// The terminal, taking the keys a terminal is expected to have ahead of the menus,
/// but only while it has the keyboard (#401): ⌘. interrupts as in Terminal, ⌘K
/// clears, ⌘F finds, ⌘T and ⌘W open and close a tab.
final class KeyedTerminalView: TerminalView {
    var newTab: () -> Void = {}
    var closeTab: () -> Void = {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Every view in the window is asked; only the one with the keyboard answers.
        guard let window, window.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case ".":
            send([0x03])
        case "k":
            // The screen and what scrolled off it, here, and a fresh prompt from the
            // shell at the top. What the helper holds comes back on the next replay.
            feed(text: "\u{1B}[H\u{1B}[2J\u{1B}[3J")
            send([0x0C])
        case "f":
            let item = NSMenuItem()
            item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            performFindPanelAction(item)
        case "t":
            newTab()
        case "w":
            closeTab()
        default:
            return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
