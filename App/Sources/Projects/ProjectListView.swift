import AgentsKit
import SwiftUI

/// The folders you work in, and nothing else.
///
/// This used to be every agent ever started. A list of folders is the length of the
/// work rather than the length of the history, which is the whole point of the change.
struct ProjectListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: URL?
    @Binding var isStarting: Bool

    @AppStorage("showsArchivedProjects") private var showsArchived = false
    @State private var isChoosingFolder = false

    var body: some View {
        List(selection: $selection) {
            ForEach(model.liveProjects) { summary in
                ProjectRow(summary: summary)
                    .tag(summary.folder)
                    .contextMenu { menu(for: summary) }
            }

            if !model.archivedProjects.isEmpty {
                Section(isExpanded: $showsArchived) {
                    ForEach(model.archivedProjects) { summary in
                        ArchivedProjectRow(summary: summary)
                    }
                } header: {
                    Text("Archived")
                }
            }

            if model.projects.isEmpty {
                EmptyProjectList(isStarting: $isStarting, isChoosingFolder: $isChoosingFolder)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem {
                Button {
                    isStarting = true
                } label: {
                    Label("New agent", systemImage: "plus")
                }
                .disabled(model.availableRuntimes.isEmpty)
                .help(model.availableRuntimes.isEmpty
                      ? "No agent runtime was found on this Mac."
                      : "Start an agent in this project")
            }
            ToolbarItem {
                Button {
                    isChoosingFolder = true
                } label: {
                    Label("Add project", systemImage: "folder.badge.plus")
                }
                .help("Add a folder as a project")
            }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            Task { await model.addProject(folder) }
        }
    }

    @ViewBuilder
    private func menu(for summary: DaemonAPI.ProjectSummary) -> some View {
        Button("Archive") {
            Task { await model.archiveProject(summary.folder) }
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([summary.folder])
        }
        .disabled(!summary.exists)
    }
}

/// An archived project, with when it was put away.
private struct ArchivedProjectRow: View {
    @Environment(AppModel.self) private var model
    let summary: DaemonAPI.ProjectSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.name).lineLimit(1).foregroundStyle(.secondary)
                if let archivedAt = summary.project.archivedAt {
                    Text("Archived \(archivedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("Unarchive") {
                Task { await model.unarchiveProject(summary.folder) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .contextMenu {
            Button("Unarchive") {
                Task { await model.unarchiveProject(summary.folder) }
            }
        }
    }
}

/// The first thing anybody sees. It says what to do, not that something is wrong.
private struct EmptyProjectList: View {
    @Environment(AppModel.self) private var model
    @Binding var isStarting: Bool
    @Binding var isChoosingFolder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.availableRuntimes.isEmpty {
                Text("No agent runtime found")
                    .font(.headline)
                Text("Agents runs the coding CLIs you already have. Install one and it appears here.")
                    .foregroundStyle(.secondary)
                ForEach(model.runtimes) { status in
                    RuntimeMissingLine(status: status)
                }
            } else {
                Text("No projects yet")
                    .font(.headline)
                Text("A project is a folder you work in. Pick one and say what you want done.")
                    .foregroundStyle(.secondary)
                Button("Add a project") { isChoosingFolder = true }
                    .buttonStyle(.borderedProminent)
                Button("Start an agent") { isStarting = true }
                    .buttonStyle(.link)
            }
        }
        .padding(.vertical, 8)
    }
}

/// Why a runtime this app knows about is not usable, in the runtime's own terms.
private struct RuntimeMissingLine: View {
    let status: RuntimeStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(status.runtime.name).font(.callout.weight(.medium))
            switch status.availability {
            case .missing(let lookedIn):
                Text("Looked for \(status.runtime.executable) in \(lookedIn.prefix(4).joined(separator: ", "))…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .needsSignIn(_, let fixCommand):
                Text(fixCommand.map { "Signed out. Run \($0)." } ?? "Signed out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Text(reason).font(.caption).foregroundStyle(.secondary)
            case .available:
                EmptyView()
            }
        }
    }
}
