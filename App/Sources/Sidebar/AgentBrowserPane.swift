import AgentsKitCore
import AppKit
import SwiftUI

/// The browser on the session's machine, which agents drive (#3528, spike #3527).
///
/// Not the Browser pane, which is the person's own web view on this Mac. This one is a
/// screencast of the machine's Chromium, where the agent works: the person sees each page
/// as the agent does, and can scroll, click and type in it at any time. It is drawn in a
/// take-over window (`TakeOverWindow`, #4141), not the side column, and frames come while
/// that window is open. It shows this session's own tab (#3916), and says when another
/// session's agent holds the browser.
struct AgentBrowserPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let agent: Agent
    let isVisible: Bool

    @State private var typed = ""
    @FocusState private var addressFocused: Bool
    /// The size of the page's area, in points: the host lays the page out at it.
    @State private var area: CGSize = .zero
    @State private var watching = false

    private var browser: MachineBrowser { model.machineBrowser(for: agent.id) }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            if let holder = browser.state.otherHolder(than: agent.id) {
                holderLine(holder)
                Divider()
            }
            GeometryReader { geometry in
                page
                    .onChange(of: geometry.size, initial: true) { _, size in area = size }
            }
            if let problem = browser.problem {
                Divider()
                Text(problem)
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
        .task(id: WatchKey(session: agent.id, visible: isVisible, width: Int(area.width), height: Int(area.height))) {
            if isVisible, area.width > 0, area.height > 0 {
                // A resize settles before the page is laid out again.
                if watching { try? await Task.sleep(for: .milliseconds(250)) }
                guard !Task.isCancelled else { return }
                await browser.watch(session: agent.id, width: Int(area.width), height: Int(area.height), adding: !watching)
                watching = true
            } else if watching {
                watching = false
                await browser.unwatch()
            }
        }
        .onDisappear {
            guard watching else { return }
            watching = false
            let browser = browser
            Task { await browser.unwatch() }
        }
        .onChange(of: browser.state.url, initial: true) { _, url in
            if !addressFocused { typed = url ?? "" }
        }
    }

    private var running: Bool { browser.state.status == .running && !browser.state.sessionHasNoTab }

    /// Another session's agent drives the browser now: its title goes to it. This
    /// session's own tab stays below, to look at and use.
    private func holderLine(_ holder: UUID) -> some View {
        HStack(spacing: 4) {
            Image(icon: "cursorarrow.rays")
                .foregroundStyle(.secondary)
            Button {
                if !model.showInFolderWindow(holder) { model.showInMainWindow(holder, opening: openWindow) }
            } label: {
                Text(browser.state.holderTitle ?? "Another session").truncationMode(.middle)
            }
            .buttonStyle(.link)
            .help("Go to this session")
            Text("is using the browser")
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .appText(.supporting)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var bar: some View {
        HStack(spacing: 6) {
            Button { Task { await browser.navigate(.back) } } label: { Image(icon: "chevron.left") }
                .buttonStyle(.borderless)
                .disabled(!running)
                .help("Back")
            Button { Task { await browser.navigate(.forward) } } label: { Image(icon: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(!running)
                .help("Forward")
            Button { Task { await browser.navigate(.reload) } } label: { Image(icon: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(!running)
                .help("Reload")
            TextField("Address", text: $typed)
                .textFieldStyle(.roundedBorder)
                .appText(.reading)
                .focused($addressFocused)
                .onSubmit {
                    let address = typed.trimmingCharacters(in: .whitespaces)
                    guard !address.isEmpty else { return }
                    addressFocused = false
                    Task { await browser.navigate(.go, to: address) }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var page: some View {
        switch browser.state.status {
        case .running where browser.state.sessionHasNoTab:
            Note(symbol: "cursorarrow.rays", title: "This session's agent has not used the browser",
                 words: "When it opens a page, you see it here and can use it. To open one yourself, type an address above.")
        case .running:
            if let frame = browser.frame {
                ZStack {
                    Paper.ground
                    if let image = NSImage(data: frame.image) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .accessibilityLabel("The page in the machine's browser")
                    }
                    BrowserInput(pageSize: CGSize(width: frame.width, height: frame.height)) { browser.send($0) }
                }
            } else {
                Waiting(words: "Loading the page")
            }
        case .starting:
            Waiting(words: browser.state.detail ?? "Starting the browser")
        case .failed:
            Note(symbol: "exclamationmark.triangle", title: "The browser didn't start",
                 words: browser.state.detail ?? "Try the address again.")
        case .stopped:
            Note(symbol: "cursorarrow.rays", title: "The browser isn't running",
                 words: "When an agent opens a page on this machine, you see it here and can use it. To open one yourself, type an address above.")
        }
    }
}

private struct WatchKey: Hashable {
    var session: UUID
    var visible: Bool
    var width: Int
    var height: Int
}

private struct Waiting: View {
    let words: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(words)
                .appText(.supporting)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Paper.ground)
    }
}

private struct Note: View {
    let symbol: String
    let title: String
    let words: String

    var body: some View {
        VStack(spacing: 6) {
            Image(icon: symbol)
                .appText(.title)
                .foregroundStyle(.tertiary)
            Text(title)
                .appText(.reading).fontWeight(.semibold)
            Text(words)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Paper.ground)
    }
}

/// Over the page, drawn to fit: the person's mouse, scroll and keys, sent to it.
private struct BrowserInput: NSViewRepresentable {
    let pageSize: CGSize
    let send: (DaemonAPI.BrowserInputRequest) -> Void

    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        view.send = send
        view.pageSize = pageSize
        return view
    }

    func updateNSView(_ view: InputView, context: Context) {
        view.send = send
        view.pageSize = pageSize
    }
}

private final class InputView: NSView {
    var send: (DaemonAPI.BrowserInputRequest) -> Void = { _ in }
    var pageSize: CGSize = .zero
    /// The button held, so a move while it is down is a drag.
    private var held: String?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    private func pagePoint(_ event: NSEvent) -> CGPoint? {
        MachineBrowser.pagePoint(convert(event.locationInWindow, from: nil), in: bounds.size, page: pageSize)
    }

    private func modifiers(_ event: NSEvent) -> Int {
        let flags = event.modifierFlags
        return BrowserKeys.modifiers(option: flags.contains(.option), control: flags.contains(.control),
                                     command: flags.contains(.command), shift: flags.contains(.shift))
    }

    private func mouse(_ event: NSEvent, _ type: String, button: String?) {
        guard let p = pagePoint(event) else { return }
        send(DaemonAPI.BrowserInputRequest(kind: .mouse, type: type, x: p.x, y: p.y, button: button ?? "none",
                                           clickCount: type == "mouseMoved" ? nil : event.clickCount,
                                           modifiers: modifiers(event)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        held = "left"
        mouse(event, "mousePressed", button: "left")
    }

    override func mouseUp(with event: NSEvent) {
        held = nil
        mouse(event, "mouseReleased", button: "left")
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        held = "right"
        mouse(event, "mousePressed", button: "right")
    }

    override func rightMouseUp(with event: NSEvent) {
        held = nil
        mouse(event, "mouseReleased", button: "right")
    }

    override func mouseMoved(with event: NSEvent) { mouse(event, "mouseMoved", button: nil) }
    override func mouseDragged(with event: NSEvent) { mouse(event, "mouseMoved", button: held) }
    override func rightMouseDragged(with event: NSEvent) { mouse(event, "mouseMoved", button: held) }

    override func scrollWheel(with event: NSEvent) {
        guard let p = pagePoint(event) else { return }
        // A line of a mouse wheel is about 40 CSS pixels; a trackpad says pixels already.
        let scale: Double = event.hasPreciseScrollingDeltas ? 1 : 40
        send(DaemonAPI.BrowserInputRequest(kind: .wheel, x: p.x, y: p.y,
                                           deltaX: -event.scrollingDeltaX * scale, deltaY: -event.scrollingDeltaY * scale,
                                           modifiers: modifiers(event)))
    }

    override func keyDown(with event: NSEvent) { key(event, down: true) }
    override func keyUp(with event: NSEvent) { key(event, down: false) }

    private func key(_ event: NSEvent, down: Bool) {
        send(BrowserKeys.input(down: down, characters: event.characters ?? "",
                               bare: event.charactersIgnoringModifiers ?? "", macKeyCode: event.keyCode,
                               modifiers: modifiers(event)))
    }

    /// ⌘V pastes this Mac's clipboard into the page. Every other ⌘ shortcut stays the app's.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers == "v" else { return super.performKeyEquivalent(with: event) }
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            send(DaemonAPI.BrowserInputRequest(kind: .text, text: text))
        }
        return true
    }
}
