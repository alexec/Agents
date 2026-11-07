import AgentsKitCore
import AppKit
import SwiftUI

/// Help ▸ Report a Problem… (#3718): what happened and what the person expected, made into
/// a GitHub issue they post from their own account. This Mac's host adds the versions and,
/// when asked, its recent log lines, and cuts out tokens and home folders; the sheet shows
/// all of it before the browser opens, and nothing is sent until the person posts it there.
struct ReportProblemSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var happened = ""
    @State private var expected = ""
    @State private var withLog = true
    @State private var report: DaemonAPI.ProblemReport?
    @State private var making = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report a Problem")
                .appText(.reading).fontWeight(.semibold)
            if let report {
                review(report)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This makes a new issue on GitHub, posted from your own account. You see all of it first.")
                .appText(.fine).foregroundStyle(.secondary)
            field("What happened", id: "report-happened", text: $happened)
            field("What you expected", id: "report-expected", text: $expected)
            Toggle("Add this Mac’s recent log lines", isOn: $withLog)
            Text("Tokens and the paths in home folders are cut out.")
                .appText(.fine).foregroundStyle(.secondary)
            if let failure {
                Text(failure)
                    .appText(.fine)
                    .foregroundStyle(StateTint.failure.style(or: .secondary))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Review…", action: make)
                    .keyboardShortcut(.defaultAction)
                    .disabled(making || happened.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func field(_ label: String, id: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // The editor says it to VoiceOver.
            Text(label).appText(.fine).accessibilityHidden(true)
            TextEditor(text: text)
                .font(.body)
                .frame(height: 72)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .accessibilityLabel(label)
                .accessibilityIdentifier(id)
        }
    }

    private func review(_ report: DaemonAPI.ProblemReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This is what GitHub gets. Change it there before you post it, if you like.")
                .appText(.fine).foregroundStyle(.secondary)
            Text(report.title).fontWeight(.semibold)
            ScrollView {
                Text(report.body)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 260)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Button("Back") { self.report = nil }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open on GitHub") {
                    if let url = URL(string: report.url) { NSWorkspace.shared.open(url) }  // store-ok: a web page
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func make() {
        making = true
        failure = nil
        let request = DaemonAPI.ProblemReportRequest(
            happened: happened, expected: expected, client: Self.client, clientOS: Self.clientOS,
            runtime: model.selectedAgent?.runtimeID, withLog: withLog)
        Task {
            defer { making = false }
            do {
                report = try await model.problemReport(request)
            } catch {
                failure = "This Mac’s Agents Host could not make the report: \(error.localizedDescription)"
            }
        }
    }

    static var client: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "Mac window" + (version.map { " " + $0 } ?? "")
    }

    static var clientOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
