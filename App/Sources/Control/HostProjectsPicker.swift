import AgentsKitCore
import SwiftUI

/// The projects to add on a host (#656): the git repositories found under the auto-detect
/// paths, each unticked, and any folder the person types. Nothing is added until Add, and
/// only what is ticked. Shown as Add a Server's last step and by a host row's Choose
/// Projects….
struct HostProjectsPicker: View {
    @Environment(AppModel.self) private var model
    let host: HostID
    let hostName: String
    /// Where to look; empty with auto-detect off, which leaves only the folder box.
    let paths: [String]
    /// The button that adds nothing: Skip at the end of Add a Server, Cancel elsewhere.
    var leaveTitle = "Cancel"
    let done: () -> Void

    @State private var found: [DaemonAPI.FoundFolder] = []
    @State private var ticked: Set<String> = []
    @State private var looking = true
    @State private var typed = ""
    @State private var problem: String?
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(paths.isEmpty
                 ? "Add folders on \(hostName) as projects."
                 : "Projects found on \(hostName). Tick the ones to add.")
                .appText(.reading).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            list
            HStack(spacing: 8) {
                TextField("A folder on \(hostName), such as ~/work/app", text: $typed)
                    .textFieldStyle(.roundedBorder).appText(.code)
                    .accessibilityLabel("Folder")
                    .onSubmit { addTyped() }
                Button("Add Folder") { addTyped() }
                    .buttonStyle(.paper)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty || adding)
            }
            if let problem {
                Text(problem).appText(.supporting).tinted(.failure).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(leaveTitle) { done() }.buttonStyle(.paper).disabled(adding)
                Button(addTitle) { addTicked() }
                    .buttonStyle(.paperProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ticked.isEmpty || adding)
            }
        }
        .task { await look() }
    }

    @ViewBuilder
    private var list: some View {
        if looking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking in \(paths.joined(separator: ", "))…").appText(.supporting).foregroundStyle(.secondary)
            }
        } else if found.isEmpty {
            if !paths.isEmpty {
                Text("No git repositories directly inside \(paths.joined(separator: ", ")).")
                    .appText(.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(found) { folder in row(folder) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .frame(maxHeight: 240)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)) }
        }
    }

    private func row(_ folder: DaemonAPI.FoundFolder) -> some View {
        Toggle(isOn: Binding(get: { folder.isProject || ticked.contains(folder.id) },
                             set: { on in if on { ticked.insert(folder.id) } else { ticked.remove(folder.id) } })) {
            HStack(spacing: 6) {
                Text(folder.folder.lastPathComponent)
                Text(folder.id).appText(.supporting).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if folder.isProject {
                    Text("· already a project").appText(.supporting).foregroundStyle(.secondary)
                } else if !folder.isRepository {
                    Text("· not a git repository").appText(.supporting).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(folder.isProject || adding)
        .accessibilityLabel(folder.folder.lastPathComponent)
    }

    private var addTitle: String {
        ticked.count == 1 ? "Add 1 Project" : "Add \(ticked.count) Projects"
    }

    private func look() async {
        defer { looking = false }
        guard !paths.isEmpty else { return }
        // A server that has only just joined reaches the window a moment later.
        for attempt in 1...10 {
            do {
                found = try await find(.init(paths: paths))
                problem = nil
                return
            } catch {
                problem = "\(hostName) could not be asked for its projects: \(model.describe(error))"
                guard attempt < 10, !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// A folder the person typed: said back as it stands on the host, and ticked.
    private func addTyped() {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        Task {
            do {
                guard let folder = try await find(.init(folders: [text])).first else { return }
                guard folder.exists else {
                    problem = "There is no folder \(text) on \(hostName)."
                    return
                }
                problem = nil
                typed = ""
                if !found.contains(where: { $0.id == folder.id }) { found.append(folder) }
                if !folder.isProject { ticked.insert(folder.id) }
            } catch {
                problem = "\(hostName) could not be asked about \(text): \(model.describe(error))"
            }
        }
    }

    private func addTicked() {
        let folders = found.filter { ticked.contains($0.id) && !$0.isProject }.map(\.folder)
        adding = true
        Task {
            let failed = await model.addProjects(folders, on: host)
            adding = false
            for index in found.indices where ticked.contains(found[index].id) && failed[found[index].folder] == nil {
                found[index].isProject = true
            }
            ticked.subtract(found.filter(\.isProject).map(\.id))
            if failed.isEmpty {
                done()
            } else {
                problem = "Not added: " + failed.map { "\($0.key.lastPathComponent) (\($0.value))" }.sorted().joined(separator: "; ")
            }
        }
    }

    private func find(_ request: DaemonAPI.ProjectsFindRequest) async throws -> [DaemonAPI.FoundFolder] {
        try await model.client(for: host).call(DaemonAPI.Method.projectsFind, request, returning: [DaemonAPI.FoundFolder].self)
    }
}

/// Choose Projects… on a host row (#656): the picker in a sheet of its own.
struct ChooseProjectsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let host: HostID
    let hostName: String
    let paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose Projects").appText(.title).fontWeight(.semibold)
            HostProjectsPicker(host: host, hostName: hostName, paths: paths) { dismiss() }
        }
        .padding(28)
        .frame(width: 620)
    }
}
