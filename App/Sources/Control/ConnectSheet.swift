#if !AGENTS_STORE
import AgentsKit
#endif
import AgentsKitCore
import Network
import SwiftUI

/// Frame C: control planes on this network by name, and the code one shows (T029). The
/// code says where to reach it and what this window may do there; Connect pairs with it
/// and the window becomes that control plane's client.
///
/// A host code instead (Hosts ▸ Add by Code…) makes this Mac one of its hosts, and only
/// that (US7): its agents run for the control plane, and this window stays unpaired.
struct ConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var connecting = false
    @State private var browser = ControlPlaneBrowser()
    @State private var code = ""
    @State private var chosen: String?
    @State private var answer: String?
    @State private var joined: String?

    /// What the pasted code is for, as soon as it reads as one.
    private var parsed: ControlCode? { ControlCode(text: code.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var isHostCode: Bool { if case .host = parsed?.purpose { true } else { false } }

    private var hostCodeWords: String {
        #if AGENTS_STORE
        "This is a code for a host. Give it to Agents Host on the Mac or server that should run the agents. To connect this window, use a code from Pair a Mac."
        #else
        "This is a code for a host. This Mac will run agents for \(parsed?.name ?? "that control plane"), and keep running them with this window closed. This window won’t be connected to it; for that, use a code from Pair a Mac."
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to a control plane").appText(.reading).fontWeight(.semibold)
            Text("ON THIS NETWORK").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                if browser.found.isEmpty {
                    Text("None found yet.").appText(.supporting).foregroundStyle(.secondary)
                        .padding(12)
                } else {
                    ForEach(browser.found, id: \.self) { name in
                        HStack {
                            Circle().frame(width: 8, height: 8).tinted(.vouched)
                            Text(name).appText(.reading)
                            Spacer()
                            Button(chosen == name ? "Chosen" : "Choose") { chosen = name }
                                .buttonStyle(.link)
                                .disabled(chosen == name)
                        }
                        .padding(12)
                        if name != browser.found.last { Divider() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)) }

            Text("CODE").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
            TextField("AGT-…", text: $code)
                .textFieldStyle(.roundedBorder)
                .appText(.code)
            Text("Paste the code, or its link. It works once, for five minutes.")
                .appText(.supporting).foregroundStyle(.secondary)
            if isHostCode, joined == nil {
                Text(hostCodeWords)
                    .appText(.supporting)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let joined {
                Text("This Mac is a host of \(joined) now. Its projects are listed wherever that control plane is used.")
                    .appText(.supporting).tinted(.vouched)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let answer {
                Text(answer).appText(.supporting).tinted(.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if joined != nil {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }
                    if connecting { ProgressView().controlSize(.small) }
                    #if AGENTS_STORE
                    Button("Connect") { connect() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || connecting || isHostCode)
                    #else
                    Button(isHostCode ? "Run a Host Here" : "Connect") { connect() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || connecting)
                    #endif
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func connect() {
        guard let parsed else {
            answer = "That isn’t a control plane’s code. It starts with agents-control:."
            return
        }
        if case .host = parsed.purpose {
            #if !AGENTS_STORE
            runHostHere(parsed)
            #endif
            return
        }
        connecting = true
        answer = nil
        Task {
            do {
                let membership = try await ControlConfig.pair(with: parsed)
                await model.adopt(.remote(membership))
                dismiss()
            } catch {
                answer = "\(error)"
            }
            connecting = false
        }
    }
}

#if !AGENTS_STORE
extension ConnectSheet {
    private func runHostHere(_ parsed: ControlCode) {
        connecting = true
        answer = nil
        Task {
            do {
                let membership = try await ControlConfig.runHostHere(with: parsed, services: .forThisWindow)
                model.becameHost(of: membership.name)
                joined = membership.name
            } catch {
                answer = "\(error)"
            }
            connecting = false
        }
    }
}
#endif

/// Control planes advertising themselves on this network, by name.
@MainActor
@Observable
final class ControlPlaneBrowser {
    private(set) var found: [String] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: ControlBonjour.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                if case .service(let name, _, _, _) = result.endpoint { return name }
                return nil
            }
            Task { @MainActor in self?.found = Array(Set(names)).sorted() }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
