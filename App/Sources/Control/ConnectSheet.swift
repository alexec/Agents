import AgentsKit
import AgentsKitCore
import Network
import SwiftUI

/// Frame C: control planes on this network by name, and the code one shows (T029). The
/// code says where to reach it and what this window may do there; Connect pairs with it
/// and the window becomes that control plane's client.
struct ConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var connecting = false
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
            if let answer {
                Text(answer).appText(.supporting).tinted(.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                if connecting { ProgressView().controlSize(.small) }
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || connecting)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func connect() {
        guard let parsed = ControlCode(text: code) else {
            answer = "That isn’t a control plane’s code. It starts with agents-control:."
            return
        }
        guard case .client = parsed.purpose else {
            answer = "That code is for adding a host, not a window. Ask for Pair a Mac instead."
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

/// Control planes advertising themselves on this network, by name.
@MainActor
@Observable
final class ControlPlaneBrowser {
    private(set) var found: [String] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: ControlNet.serviceType, domain: nil), using: .tcp)
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
