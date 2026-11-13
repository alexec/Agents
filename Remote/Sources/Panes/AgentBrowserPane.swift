import AgentsKitCore
import SwiftUI
import UIKit

/// The browser on the session's machine, which agents drive (#3800), as the window's
/// `AgentBrowserPane` shows it (#3528): a screencast of this session's own tab (#3916),
/// which the person can use at any time, and who holds the browser when another session does. A tap is a click, a drag scrolls the page, a tap in a
/// field of the page opens the keyboard, and the keyboard button types into the page anywhere. Frames come only while the pane is on screen and the app is not in the background.
struct AgentBrowserPane: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let agent: Agent

    @State private var typed = ""
    @FocusState private var addressFocused: Bool
    /// The size of the page's area, in points: the host lays the page out at it.
    @State private var area: CGSize = .zero
    @State private var watching = false
    /// The page has the keyboard: what is typed goes to it.
    @State private var typing = false

    var body: some View {
        if let browser = model.machineBrowser(for: agent.id) {
            content(browser)
        } else {
            ContentUnavailableView("The machine can't be reached", systemImage: "wifi.slash",
                                   description: Text("The browser shows here when the machine is back."))
        }
    }

    private func content(_ browser: MachineBrowser) -> some View {
        VStack(spacing: 0) {
            bar(browser)
            Divider()
            if let holder = browser.state.otherHolder(than: agent.id) {
                holderLine(browser, holder)
                Divider()
            }
            GeometryReader { geometry in
                page(browser)
                    .onChange(of: geometry.size, initial: true) { _, size in area = size }
            }
            // Always on, one line high: a line that came and went changed the page's height,
            // and each new height laid the page out again, so the page flickered.
            Divider()
            Text(browser.problem ?? " ")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .accessibilityHidden(browser.problem == nil)
        }
        // Inactive is still on screen (a notification over it, the app switcher): only the
        // background stops the frames.
        .task(id: WatchKey(session: agent.id, visible: scenePhase != .background, width: Int(area.width), height: Int(area.height))) {
            if scenePhase != .background, area.width > 0, area.height > 0 {
                // A resize (the keyboard, a turn of the phone) settles before the page is laid out again.
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
            Task { await browser.unwatch() }
        }
        .onChange(of: browser.state.url, initial: true) { _, url in
            if !addressFocused { typed = url ?? "" }
        }
        // A tap in a field of the page opens the keyboard, and a tap outside one closes it,
        // as in Safari.
        .onChange(of: browser.editing) { _, said in
            if let said { typing = said.inField }
        }
    }

    /// Another session's agent drives the browser now: its title goes to it. This
    /// session's own tab stays below, to look at and use.
    private func holderLine(_ browser: MachineBrowser, _ holder: UUID) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "cursorarrow.rays")
                .foregroundStyle(.secondary)
            Button { model.open(holder) } label: {
                Text(browser.state.holderTitle ?? "Another session").truncationMode(.middle)
            }
            .accessibilityHint("Goes to this session")
            Text("is using the browser")
                .foregroundStyle(.secondary)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .appText(.fine)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func bar(_ browser: MachineBrowser) -> some View {
        let running = browser.state.status == .running && !browser.state.sessionHasNoTab
        return HStack(spacing: 12) {
            Button { Task { await browser.navigate(.back) } } label: {
                Label("Back", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
            .disabled(!running)
            Button { Task { await browser.navigate(.forward) } } label: {
                Label("Forward", systemImage: "chevron.right").labelStyle(.iconOnly)
            }
            .disabled(!running)
            Button { Task { await browser.navigate(.reload) } } label: {
                Label("Reload", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
            }
            .disabled(!running)
            TextField("Address", text: $typed)
                .textFieldStyle(.roundedBorder)
                .appText(.reading)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit {
                    let address = typed.trimmingCharacters(in: .whitespaces)
                    guard !address.isEmpty else { return }
                    addressFocused = false
                    Task { await browser.navigate(.go, to: address) }
                }
            Button { typing.toggle() } label: {
                Label(typing ? "Hide Keyboard" : "Type in the Page",
                      systemImage: typing ? "keyboard.chevron.compact.down" : "keyboard")
                    .labelStyle(.iconOnly)
            }
            .disabled(!running)
            .accessibilityHint("What you type goes to the page")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func page(_ browser: MachineBrowser) -> some View {
        switch browser.state.status {
        case .running where browser.state.sessionHasNoTab:
            ContentUnavailableView("This session's agent has not used the browser", systemImage: "cursorarrow.rays",
                                   description: Text("When it opens a page, you see it here and can use it. To open one yourself, type an address above."))
        case .running:
            if let frame = browser.frame {
                ZStack {
                    Paper.ground
                    if let image = UIImage(data: frame.image) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .accessibilityLabel("The page in the machine's browser")
                    }
                    TouchInput(pageSize: CGSize(width: frame.width, height: frame.height), typing: $typing) {
                        browser.send($0)
                    }
                }
            } else {
                BrowserWaiting(words: "Loading the page")
            }
        case .starting:
            BrowserWaiting(words: browser.state.detail ?? "Starting the browser")
        case .failed:
            ContentUnavailableView("The browser didn't start", systemImage: "exclamationmark.triangle",
                                   description: Text(browser.state.detail ?? "Try the address again."))
        case .stopped:
            ContentUnavailableView("The browser isn't running", systemImage: "cursorarrow.rays",
                                   description: Text("When an agent opens a page on this machine, you see it here and can use it. To open one yourself, type an address above."))
        }
    }
}

private struct WatchKey: Hashable {
    var session: UUID
    var visible: Bool
    var width: Int
    var height: Int
}

private struct BrowserWaiting: View {
    let words: String

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text(words)
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Paper.ground)
    }
}

/// Over the page, drawn to fit: the person's taps, drags and keys, sent to it.
private struct TouchInput: UIViewRepresentable {
    let pageSize: CGSize
    @Binding var typing: Bool
    let send: (DaemonAPI.BrowserInputRequest) -> Void

    func makeUIView(context: Context) -> TouchInputView {
        let view = TouchInputView()
        update(view)
        return view
    }

    func updateUIView(_ view: TouchInputView, context: Context) {
        update(view)
        if typing, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !typing, view.isFirstResponder {
            _ = view.resignFirstResponder()
        }
    }

    private func update(_ view: TouchInputView) {
        view.send = send
        view.pageSize = pageSize
        view.keyboardWent = { typing = false }
    }
}

final class TouchInputView: UIView, UIKeyInput {
    var send: (DaemonAPI.BrowserInputRequest) -> Void = { _ in }
    var pageSize: CGSize = .zero
    var keyboardWent: () -> Void = {}
    /// Where the last scroll step left the finger, so each step sends only what it moved.
    private var lastPan: CGPoint = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func pagePoint(_ point: CGPoint) -> CGPoint? {
        MachineBrowser.pagePoint(point, in: bounds.size, page: pageSize)
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard let p = pagePoint(tap.location(in: self)) else { return }
        for type in ["mouseMoved", "mousePressed", "mouseReleased"] {
            send(DaemonAPI.BrowserInputRequest(kind: .mouse, type: type, x: p.x, y: p.y,
                                               button: type == "mouseMoved" ? "none" : "left",
                                               clickCount: type == "mouseMoved" ? nil : 1, modifiers: 0))
        }
    }

    /// A drag scrolls the page under the finger, as a page on the phone does.
    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let moved = pan.translation(in: self)
        if pan.state == .began { lastPan = .zero }
        guard pan.state == .changed, let p = pagePoint(pan.location(in: self)) else { return }
        let fit = MachineBrowser.fitted(pageSize, in: bounds.size)
        guard fit.width > 0 else { return }
        let scale = pageSize.width / fit.width
        let step = CGPoint(x: moved.x - lastPan.x, y: moved.y - lastPan.y)
        lastPan = moved
        send(DaemonAPI.BrowserInputRequest(kind: .wheel, x: p.x, y: p.y,
                                           deltaX: -step.x * scale, deltaY: -step.y * scale, modifiers: 0))
    }

    // MARK: The keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func resignFirstResponder() -> Bool {
        let went = super.resignFirstResponder()
        if went { keyboardWent() }
        return went
    }

    var hasText: Bool { true }

    var autocorrectionType: UITextAutocorrectionType {
        get { .no }
        set {}
    }

    var autocapitalizationType: UITextAutocapitalizationType {
        get { .none }
        set {}
    }

    func insertText(_ text: String) {
        if text == "\n" {
            key(36)
        } else if text == "\t" {
            key(48)
        } else {
            send(DaemonAPI.BrowserInputRequest(kind: .text, text: text))
        }
    }

    func deleteBackward() { key(51) }

    /// A key with no text, by the Mac's virtual key code, down and up.
    private func key(_ macKeyCode: UInt16, modifiers: Int = 0) {
        for down in [true, false] {
            send(BrowserKeys.input(down: down, characters: "", bare: "", macKeyCode: macKeyCode, modifiers: modifiers))
        }
    }

    /// An iPad keyboard's keys that type nothing: the arrows and Escape.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let pressed = press.key, let code = Self.macKeyCodes[pressed.keyCode] else { continue }
            let flags = pressed.modifierFlags
            key(code, modifiers: BrowserKeys.modifiers(option: flags.contains(.alternate), control: flags.contains(.control),
                                                       command: flags.contains(.command), shift: flags.contains(.shift)))
            handled = true
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    private static let macKeyCodes: [UIKeyboardHIDUsage: UInt16] = [
        .keyboardLeftArrow: 123, .keyboardRightArrow: 124, .keyboardDownArrow: 125, .keyboardUpArrow: 126,
        .keyboardEscape: 53, .keyboardHome: 115, .keyboardEnd: 119, .keyboardPageUp: 116, .keyboardPageDown: 121,
        .keyboardDeleteForward: 117,
    ]

    /// Paste from the edit menu, or ⌘V on an iPad's keyboard, sends the pasteboard's text.
    /// Copy, Cut and Select All (⌘C, ⌘X, ⌘A) act in the page, and a copy comes back to
    /// this device's pasteboard (#5119).
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(paste(_:)): UIPasteboard.general.hasStrings
        case #selector(copy(_:)), #selector(cut(_:)), #selector(selectAll(_:)), #selector(undoInPage),
             #selector(redoInPage): true
        default: super.canPerformAction(action, withSender: sender)
        }
    }

    override func copy(_ sender: Any?) { send(DaemonAPI.BrowserInputRequest(kind: .edit, command: .copy)) }
    override func cut(_ sender: Any?) { send(DaemonAPI.BrowserInputRequest(kind: .edit, command: .cut)) }
    override func selectAll(_ sender: Any?) { send(DaemonAPI.BrowserInputRequest(kind: .edit, command: .selectAll)) }

    /// ⌘Z and ⇧⌘Z on an iPad's keyboard undo and redo in the page's field.
    override var keyCommands: [UIKeyCommand]? {
        let undo = UIKeyCommand(input: "z", modifierFlags: .command, action: #selector(undoInPage))
        let redo = UIKeyCommand(input: "z", modifierFlags: [.command, .shift], action: #selector(redoInPage))
        for command in [undo, redo] { command.wantsPriorityOverSystemBehavior = true }
        return [undo, redo]
    }

    @objc private func undoInPage() { send(DaemonAPI.BrowserInputRequest(kind: .edit, command: .undo)) }
    @objc private func redoInPage() { send(DaemonAPI.BrowserInputRequest(kind: .edit, command: .redo)) }

    override func paste(_ sender: Any?) {
        if let text = UIPasteboard.general.string, !text.isEmpty {
            send(DaemonAPI.BrowserInputRequest(kind: .text, text: text))
        }
    }
}
