import AgentsKitCore
import SwiftUI
import WebKit

extension EnvironmentValues {
    /// What the chat's views need from the app (#187). Nil draws a view as its words alone.
    @Entry var appViewActions: AppViewActions? = nil
    /// The open chat's views.
    @Entry var appViewStore: AppViewStore? = nil
}

/// A tool's view, inline in the chat where the call began (#187).
struct AppViewRow: View {
    let call: AppViewCall
    @Environment(\.appViewActions) private var actions
    @Environment(\.appViewStore) private var store

    var body: some View {
        if let actions, let store {
            AppViewInline(host: store.host(for: call, actions: actions))
        } else {
            // Somewhere with no host to ask: what the model was told, as words.
            VStack(alignment: .leading, spacing: 3) {
                Text(call.tool).appText(.fine).foregroundStyle(.secondary)
                if let text = call.resultText { Text(text).appText(.reading) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AppViewInline: View {
    let host: AppViewHost
    @Environment(\.colorScheme) private var scheme
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AppViewCaption(host: host)
            Group {
                switch host.phase {
                case .failed(let words):
                    Text(words).appText(.supporting).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                case .asking(let ask):
                    AppViewShowAsk(host: host, ask: ask)
                case .gone:
                    Text("This view was closed.").appText(.supporting).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                default:
                    if host.isFullscreen {
                        Button("Showing full screen. Back to the chat") { host.setFullscreen(false) }
                            .buttonStyle(.plain)
                            .appText(.supporting)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    } else {
                        AppViewWeb(host: host)
                            .frame(height: host.height)
                            .accessibilityLabel(host.title)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .modifier(AppViewEdge(on: host.prefersBorder))
            AppViewAsks(host: host)
        }
        .onAppear { host.start() }
        .onChange(of: width, initial: true) { placeInline() }
        .onChange(of: scheme) { placeInline() }
        .onChange(of: host.isFullscreen) { if !host.isFullscreen { placeInline() } }
    }

    private func placeInline() {
        guard width > 0, !host.isFullscreen else { return }
        host.place(width: width, height: nil, theme: scheme)
    }
}

/// A person's own server's view, before it is drawn: Show or Don't Show, in its place (#191).
/// Asked once for each version of the view; a view that changes asks again.
struct AppViewShowAsk: View {
    let host: AppViewHost
    let ask: DaemonAPI.ViewAsk

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ask.isNew ? "\(ask.server) wants to show a view here." : "\(ask.server)'s view has changed since you said Show.")
                .appText(.reading)
            Text("It is drawn in a sandbox, and reaches only what it declared.")
                .appText(.supporting).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Show") { host.answerShow(true) }.buttonStyle(.paperProminent)
                Button("Don't Show") { host.answerShow(false) }.buttonStyle(.paper)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
    }
}

/// A view filling the page it was opened on (#188). No way back to a chat: this page is the
/// destination, as the project's Dashboard is.
struct AppViewPage: View {
    let host: AppViewHost
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { proxy in
            Group {
                switch host.phase {
                case .failed(let words):
                    Text(words)
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(24)
                case .asking(let ask):
                    AppViewShowAsk(host: host, ask: ask)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(24)
                case .gone:
                    Text("This view was closed.")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                default:
                    AppViewWeb(host: host)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onChange(of: proxy.size, initial: true) { place(proxy) }
            .onChange(of: scheme) { place(proxy) }
        }
        .onAppear { host.start() }
    }

    private func place(_ proxy: GeometryProxy) {
        let insets = proxy.safeAreaInsets
        host.place(width: proxy.size.width, height: proxy.size.height, theme: scheme,
                   safeArea: (Double(insets.top), Double(insets.trailing), Double(insets.bottom), Double(insets.leading)))
    }
}

/// The view in the chat's place: `fullscreen`, as a pinned page is drawn there.
struct AppViewFullscreen: View {
    let host: AppViewHost
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(host.title).appText(.supporting).fontWeight(.semibold)
                Spacer(minLength: 0)
                if let note = host.pinNote {
                    Text(note).appText(.fine).foregroundStyle(.secondary).lineLimit(2)
                }
                AppViewMenu(host: host)
                Button("Back to the chat") { host.setFullscreen(false) }
                    .buttonStyle(.paper)
                    .appText(.fine)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            GeometryReader { proxy in
                AppViewWeb(host: host)
                    .onChange(of: proxy.size, initial: true) { place(proxy) }
                    .onChange(of: scheme) { place(proxy) }
            }
            AppViewAsks(host: host).padding(12)
        }
        .paperGround()
    }

    private func place(_ proxy: GeometryProxy) {
        let insets = proxy.safeAreaInsets
        host.place(width: proxy.size.width, height: proxy.size.height, theme: scheme,
                   safeArea: (Double(insets.top), Double(insets.trailing), Double(insets.bottom), Double(insets.leading)))
    }
}

/// The name above a view, and the way to full screen and back.
private struct AppViewCaption: View {
    let host: AppViewHost

    var body: some View {
        HStack(spacing: 8) {
            Text(host.title).appText(.fine).foregroundStyle(.secondary)
            if host.call.state == .cancelled {
                Text("Cancelled").appText(.fine).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if let note = host.pinNote {
                Text(note).appText(.fine).foregroundStyle(.secondary).lineLimit(2)
            }
            if host.phase == .ready, !host.isFullscreen {
                Button {
                    host.setFullscreen(true)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .accessibilityLabel("Full screen")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show this view in the chat's place")
            }
            AppViewMenu(host: host)
        }
    }
}

/// The view's menu: Pin to Project (#189), when the call can feed a pin. Nothing else yet,
/// so no menu at all without it.
private struct AppViewMenu: View {
    let host: AppViewHost

    var body: some View {
        if host.canPin {
            Menu {
                Button("Pin to Project") { host.pinToProject() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("View menu")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Pin this view under the project, opened by the same call")
        }
    }
}

/// What the view asked that needs the person: a message to send, and the context the
/// agent will be told.
private struct AppViewAsks: View {
    let host: AppViewHost

    var body: some View {
        if let message = host.askedMessage {
            VStack(alignment: .leading, spacing: 6) {
                Text("The view asks to send this as your message:").appText(.fine).foregroundStyle(.secondary)
                Text(message).appText(.reading).textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("Send") { host.answerMessage(send: true) }.buttonStyle(.paperProminent)
                    Button("Don't Send") { host.answerMessage(send: false) }.buttonStyle(.paper)
                }
                .appText(.fine)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperWell(in: RoundedRectangle(cornerRadius: Paper.Radius.card))
        }
        if let context = host.contextLine {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("With your next message the agent is told: \(context)")
                    .appText(.fine).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                Button("Don't Tell") { host.dropContext() }.buttonStyle(.plain).appText(.fine).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AppViewEdge: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on {
            content
                .clipShape(RoundedRectangle(cornerRadius: Paper.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule, lineWidth: 1))
        } else {
            content
        }
    }
}

#if os(macOS)
private struct AppViewWeb: NSViewRepresentable {
    let host: AppViewHost
    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        attach(to: box)
        return box
    }
    func updateNSView(_ box: NSView, context: Context) {
        if host.web.superview !== box { attach(to: box) }
    }
    private func attach(to box: NSView) {
        host.web.removeFromSuperview()
        host.web.frame = box.bounds
        host.web.autoresizingMask = [.width, .height]
        box.addSubview(host.web)
    }
}
#else
private struct AppViewWeb: UIViewRepresentable {
    let host: AppViewHost
    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.backgroundColor = .clear
        attach(to: box)
        return box
    }
    func updateUIView(_ box: UIView, context: Context) {
        if host.web.superview !== box { attach(to: box) }
    }
    private func attach(to box: UIView) {
        host.web.removeFromSuperview()
        host.web.frame = box.bounds
        host.web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        box.addSubview(host.web)
    }
}
#endif
