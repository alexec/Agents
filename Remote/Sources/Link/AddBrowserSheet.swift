import AgentsKitCore
import SwiftUI
import UIKit

/// Why a browser's code could not be made, in words to show.
struct BrowserCodeProblem: Error {
    let words: String
}

/// Add a Browser… (#1459), as the window's: a one-use code for a browser, shown as text to
/// copy, and where to paste it. A browser anywhere pairs at the page on the control plane's
/// own domain; with no page there, only a browser on the control plane's Mac can.
struct AddBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RemoteModel.self) private var model
    @State private var shown: DaemonAPI.ControlCodeShown?
    @State private var page: String?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                if let shown {
                    Section {
                        Text(shown.text)
                            .appText(.code)
                            .textSelection(.enabled)
                            .accessibilityLabel("Code")
                            .accessibilityValue(shown.text)
                        Button("Copy") { UIPasteboard.general.string = shown.text }
                    } footer: {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(instructions(until: shown.expires, now: context.date))
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
                shown = made.shown
                page = made.page
            case .failure(let failed):
                problem = failed.words
            }
        }
        .onDisappear { Task { await model.stopBrowserCode() } }
    }

    private func instructions(until expires: Date, now: Date) -> String {
        let left = max(0, Int(expires.timeIntervalSince(now)))
        let time = left == 0 ? "It has run out; close this and ask again."
            : "It works once, for \(left / 60):\(String(format: "%02d", left % 60))."
        let place = page.map { "In any browser, open \($0) and paste it in." }
            ?? "In a browser on the Mac that runs the control plane, open its Agents page and paste it in."
        return "\(place) That browser can then do all this \(UIDevice.current.model) can. \(time)"
    }
}
