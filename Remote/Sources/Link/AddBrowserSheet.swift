import AgentsKitCore
import SwiftUI
import UIKit

/// Why a browser's code could not be made, in words to show.
struct BrowserCodeProblem: Error {
    let words: String
}

/// A browser's code as made: where its page is, and who was paired before it (#1537).
struct BrowserCode {
    let shown: DaemonAPI.ControlCodeShown
    /// The page on the control plane's own domain (#1459), for a browser anywhere.
    let page: String?
    /// The page on the control plane's Mac, and whether it is served there.
    let web: DaemonAPI.WebRemoteStatus?
    /// The clients paired before the code was made.
    let before: Set<UUID>
}

/// Add a Browser… (#1459), as the window's: a one-use code for a browser, shown as text to
/// copy, and where to paste it. A browser anywhere pairs at the page on the control plane's
/// own domain; with no page there, a browser on the control plane's Mac pairs at its address.
/// Once a browser joins with the code, the sheet says so, as the window's does (#1537).
struct AddBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RemoteModel.self) private var model
    @State private var code: BrowserCode?
    @State private var joined: String?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                if let joined {
                    Text("\(joined) joined with this code. It can’t be used again.")
                } else if let code {
                    Section {
                        Text(code.shown.text)
                            .appText(.code)
                            .textSelection(.enabled)
                            .accessibilityLabel("Code")
                            .accessibilityValue(code.shown.text)
                        Button("Copy") { UIPasteboard.general.string = code.shown.text }
                    } footer: {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(instructions(for: code, now: context.date))
                        }
                    }
                } else if let problem {
                    Text(problem).tinted(.failure)
                } else {
                    ProgressView()
                }
            }
            .scrollContentBackground(.hidden)
            .background(Paper.ground)
            .navigationTitle("Add a Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task {
            switch await model.startBrowserCode() {
            case .success(let made):
                code = made
                await watchForJoin(after: made)
            case .failure(let failed):
                problem = failed.words
            }
        }
        .onDisappear { Task { await model.stopBrowserCode() } }
    }

    /// Asks the control plane who is paired every two seconds while the code is shown and
    /// unspent. A browser that was not there before joined with this code, which is then spent.
    private func watchForJoin(after made: BrowserCode) async {
        while !Task.isCancelled, joined == nil, made.shown.expires > .now {
            try? await Task.sleep(for: .seconds(2))
            guard let listed = await model.pairedClients() else { continue }
            if let new = listed.first(where: { $0.kind == .browser && !made.before.contains($0.id) }) {
                joined = new.name
            }
        }
    }

    private func instructions(for code: BrowserCode, now: Date) -> String {
        let left = max(0, Int(code.shown.expires.timeIntervalSince(now)))
        let time = left == 0 ? "It has run out; close this and ask again."
            : "It works once, for \(left / 60):\(String(format: "%02d", left % 60))."
        return "\(Self.place(page: code.page, web: code.web)) That browser can then do all this \(UIDevice.current.model) can. \(time)"
    }

    /// Where to paste the code: the page on the control plane's own domain, for a browser
    /// anywhere; else the page's address on the control plane's Mac, or why it isn't served
    /// there, as the window's sheet says it.
    static func place(page: String?, web: DaemonAPI.WebRemoteStatus?) -> String {
        if let page { return "In any browser, open \(page) and paste it in." }
        guard let web else {
            return "Turn on Serve Agents to browsers on this Mac in Agents Host, on the Mac that runs the control plane."
        }
        let there = "In a browser on the Mac that runs the control plane, open \(web.address) and paste it in."
        return web.served ? there : "\(web.summary) Try again in Agents Host on that Mac. Then: \(there)"
    }
}
