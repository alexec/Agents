import AgentsKitCore
import Network
import SwiftUI

/// Frame C: control planes on this network by name, and the code one shows.
///
/// Pairing over the network is the next part of 058 (T018–T023, T029). Until it lands,
/// Connect says so rather than pretending: the list is real, the code is read, and the
/// window stays on the first-run page.
struct ConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var browser = ControlPlaneBrowser()
    @State private var code = ""
    @State private var chosen: String?
    @State private var answer: String?

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
                            Circle().fill(.green).frame(width: 8, height: 8)
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
                .font(.body.monospaced())
            Text("Paste the code, or its link. It works once, for five minutes.")
                .appText(.supporting).foregroundStyle(.secondary)
            if let answer {
                Text(answer).appText(.supporting).tinted(.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func connect() {
        answer = "This build can’t pair with a control plane on another machine yet. That comes next. For now, choose Run one on this Mac."
    }
}

/// Control planes advertising `_agents._tcp` on this network, by name.
@MainActor
@Observable
final class ControlPlaneBrowser {
    private(set) var found: [String] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_agents._tcp", domain: nil), using: .tcp)
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
