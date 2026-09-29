#if AGENTS_STORE
import AgentsKitCore
import SwiftUI

/// What the App Store window shows with no control plane (058, frames K and K2): the
/// window can run nothing itself, so *Set one up on this Mac* sends the person to Agents
/// Host, and the screen turns into K2 by itself once a control plane named for this Mac
/// appears on the network.
struct FirstRunView: View {
    @Environment(AppModel.self) private var model
    @State private var connecting = false
    @State private var browser = ControlPlaneBrowser()

    /// Agents Host names its control plane after this Mac, so one found by that name is here.
    private var thisMacs: String? {
        let name = Host.current().localizedName ?? ""
        return browser.found.first { !name.isEmpty && $0 == name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let found = thisMacs { foundHere(found) } else { choice }
        }
        // A floor on the width: laid out narrower, the words fixed to their height push
        // the window thousands of points tall.
        .frame(minWidth: 520, maxWidth: 640, alignment: .leading)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paperGround()
        .sheet(isPresented: $connecting) { ConnectSheet().paperSheet() }
        .onAppear { browser.start() }
        // A walk's window pairs itself from AGENTS_CONTROL; nothing else sets it.
        .task { await model.pairForWalk() }
        .onDisappear { browser.stop() }
    }

    // MARK: K · nothing on this Mac yet

    private var choice: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Where should your agents run?").appText(.title).fontWeight(.semibold)
            (Text("This window is where you work with your agents. They run on a ") + Text("control plane").bold()
             + Text(" you own: on this Mac, on another Mac, or on a server. Your iPhone and iPad connect to it too."))
                .appText(.reading).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 16) {
                card(title: "Set one up on this Mac",
                     body: "Install Agents Host, a free app from us. It runs your agents and the control plane on this Mac, and keeps them running with this window closed. It isn’t in the App Store because it runs programs for your agents.",
                     usual: true) {
                    Button("Get Agents Host…") { getAgentsHost() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                card(title: "Connect to a control plane",
                     body: "You already run one, on another Mac or a server. You’ll need a pairing code from it.",
                     usual: false) {
                    Button("Connect…") { connecting = true }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("Waiting for Agents Host… It appears here as soon as it’s running. Nothing passes through a service of ours.")
                .appText(.supporting).foregroundStyle(.secondary)
        }
    }

    // MARK: K2 · Agents Host found on this Mac

    private func foundHere(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Agents Host is running on this Mac").appText(.title).fontWeight(.semibold)
            HStack(spacing: 10) {
                Circle().frame(width: 8, height: 8).tinted(.vouched)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).appText(.reading).fontWeight(.semibold)
                    Text("Control plane").appText(.supporting).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Pair") { connecting = true }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25)) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(name)
            Text("Pairing lets this window do everything: start agents, sign runtimes in, add servers and pair your phone. Agents Host shows the code to type.")
                .appText(.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Connect to a different control plane…") { connecting = true }.buttonStyle(.link)
        }
    }

    private func card(title: String, body: String, usual: Bool,
                      @ViewBuilder action: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).appText(.reading).fontWeight(.semibold)
            Text(body).appText(.supporting).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            action()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(usual ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: usual ? 2 : 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func getAgentsHost() {
        let text = Bundle.main.object(forInfoDictionaryKey: "AgentsHostDownloadURL") as? String
        if let url = text.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }  // store-ok: a web page
    }
}
#endif
