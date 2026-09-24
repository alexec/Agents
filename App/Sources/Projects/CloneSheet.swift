import AgentsKit
import AppKit
import SwiftUI

/// New project from a Git URL (027): paste it, see where it will go, clone.
///
/// The sheet closes as soon as the clone begins. How it is going is a row in the
/// Projects column, where the project will appear, and a clone that fails says why in
/// the window's alert — a sheet held open for a big repository would be minutes of a
/// window you cannot use.
struct CloneSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var remote: GitRemote? { GitRemote(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone a Git repository")
                .appText(.reading).fontWeight(.semibold)
            TextField("https://github.com/owner/repository.git", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(clone)
            Group {
                if let remote {
                    Text("Clones into \(destination(for: remote)) and adds it as a project.")
                        .foregroundStyle(.secondary)
                } else if text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Paste an HTTPS or SSH address.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("That is not a Git URL this app can clone. Paste an HTTPS or SSH address.")
                        .foregroundStyle(StateTint.failure.style(or: .secondary))
                }
            }
            .appText(.fine)
            .lineLimit(2, reservesSpace: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Clone", action: clone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(remote == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            // The URL is nearly always what was just copied.
            if let copied = NSPasteboard.general.string(forType: .string), GitRemote(copied) != nil {
                text = copied.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            isFocused = true
        }
    }

    private func destination(for remote: GitRemote) -> String {
        let folder = DaemonCore.defaultCloneParent().appending(path: remote.folderName)
        return (folder.path as NSString).abbreviatingWithTildeInPath
    }

    private func clone() {
        guard let remote else { return }
        dismiss()
        Task { await model.cloneProject(remote.url) }
    }
}

/// A clone under way, where the project it becomes will be.
struct CloningRow: View {
    let clone: DaemonAPI.CloneSummary

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(clone.folder.lastPathComponent)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Text("Cloning…")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            ProgressView().controlSize(.small)
        }
        .help(clone.url)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cloning \(clone.folder.lastPathComponent) from \(clone.url)")
    }
}
