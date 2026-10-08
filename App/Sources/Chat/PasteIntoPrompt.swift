import AgentsKitCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// ⌘V in the prompt attaches what was copied, as a drag or the paperclip would (#396).
///
/// The field's own paste takes ⌘V first, and a text field pastes words and nothing else,
/// so a screenshot or a file copied in Finder never reached the bar. While the field has
/// the caret, ⌘V in its window is looked at here first: pictures and files are attached,
/// and the field still pastes any words that came with them.
struct PastesIntoPrompt: ViewModifier {
    /// Whether the field has the caret.
    let isFocused: Bool
    let attachFile: (URL) -> Void
    let attachPicture: (Data, UTType) -> Void

    @State private var watcher: Any?
    @State private var anchor = PasteAnchor()

    func body(content: Content) -> some View {
        content
            .background(PasteAnchorView(anchor: anchor))
            .onAppear { if isFocused { watch() } }
            .onChange(of: isFocused) { _, now in now ? watch() : stopWatching() }
            .onDisappear(perform: stopWatching)
    }

    private func watch() {
        guard watcher == nil else { return }
        watcher = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [anchor] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  anchor.isIn(window: event.windowNumber)
            else { return event }
            let wordsToo = MainActor.assumeIsolated { paste(from: .general) }
            return wordsToo ? event : nil
        }
    }

    private func stopWatching() {
        guard let watcher else { return }
        NSEvent.removeMonitor(watcher)
        self.watcher = nil
    }

    /// Attaches the pasteboard's files and pictures. Answers whether the field should
    /// still paste: when there was nothing to attach, or words came with it.
    @MainActor
    private func paste(from pasteboard: NSPasteboard) -> Bool {
        var attached = false
        var words = false
        for item in pasteboard.pasteboardItems ?? [] {
            switch PromptPaste.kind(of: item.types.map(\.rawValue)) {
            case .file:
                guard let string = item.string(forType: .fileURL), let url = URL(string: string) else { continue }
                attachFile(url)
                attached = true
            case .picture(let type):
                guard let data = item.data(forType: NSPasteboard.PasteboardType(type.identifier)) else { continue }
                attachPicture(data, type)
                attached = true
            case .words:
                words = true
            case .nothing:
                continue
            }
        }
        return !attached || words
    }
}

/// Where the field is, kept by an AppKit view laid behind it, to tell its window's ⌘V
/// from another window's.
@MainActor
final class PasteAnchor {
    weak var view: NSView?

    nonisolated func isIn(window number: Int) -> Bool {
        MainActor.assumeIsolated { view?.window?.windowNumber == number }
    }
}

private struct PasteAnchorView: NSViewRepresentable {
    let anchor: PasteAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}
