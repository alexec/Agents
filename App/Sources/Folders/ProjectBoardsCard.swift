import AgentsKitCore
import SwiftUI

/// The boards in a project's Tasks slot (#3282, specs/3273-project-unit "Boards"): a GitHub
/// Projects board, a Jira board, a Linear team or a GitLab group board, each with a name (the
/// team's). Work ▸ Issues and Features show one board at a time. The owner or an admin adds and
/// removes them; the control plane reads each board from its address. Mac + web: the Remote
/// keeps no settings (#2798).
struct ProjectBoardsCard: View {
    /// The control plane, which keeps the projects; nil when there is none.
    let control: DaemonClient?
    /// The folder's project id.
    let project: String

    @State private var read: DaemonAPI.Project?
    @State private var name = ""
    @State private var address = ""
    @State private var problem: String?
    @State private var isAsking = false

    private var boards: [DaemonAPI.ProjectBoard] { read?.boards ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ProjectBoardWords.heading).appText(.fine).fontWeight(.semibold)
                .foregroundStyle(.secondary).textCase(.uppercase)
            Text(ProjectBoardWords.note).appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if boards.isEmpty {
                Text(ProjectBoardWords.none).appText(.fine)
            }
            ForEach(boards) { board in row(board) }
            // Above the fields, beside what was typed.
            if let problem {
                Text(problem).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
            }
            if read?.mayChange == true {
                HStack(spacing: 8) {
                    TextField(ProjectBoardWords.namePrompt, text: $name)
                        .frame(width: 140)
                    TextField(ProjectBoardWords.addressPrompt, text: $address)
                        .onSubmit(add)
                    Button(ProjectBoardWords.add, action: add)
                        .disabled(isAsking || name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .textFieldStyle(.roundedBorder)
                .appText(.fine)
            } else if read != nil {
                Text(ProjectBoardWords.onlyOwner).appText(.fine).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperRaised(in: RoundedRectangle(cornerRadius: 10))
        .task(id: project) { await load() }
    }

    private func row(_ board: DaemonAPI.ProjectBoard) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(board.name).appText(.fine).fontWeight(.semibold)
                .frame(minWidth: 90, alignment: .leading)
            Text(ProjectBoardWords.forge(board)).appText(.fine).foregroundStyle(.secondary)
            if let url = URL(string: board.url) {
                Link(board.url, destination: url).appText(.fine).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if read?.mayChange == true {
                Button(ProjectBoardWords.remove) { save(boards.filter { $0.url != board.url }) }
                    .buttonStyle(.link).appText(.fine)
                    .disabled(isAsking)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func add() {
        let board = DaemonAPI.ProjectBoard(name: name.trimmingCharacters(in: .whitespaces),
                                           url: address.trimmingCharacters(in: .whitespaces))
        guard !board.name.isEmpty, !board.url.isEmpty else { return }
        save(boards + [board], clearing: true)
    }

    /// The project, for its boards and whether this person may change them.
    private func load() async {
        guard let control else { return }
        do {
            let list = try await control.call(DaemonAPI.Method.projectsList, DaemonAPI.Empty(),
                                              returning: DaemonAPI.ProjectList.self)
            read = list.projects.first { $0.id == project }
            problem = nil
        } catch {
            problem = ProjectWords.notRead(error)
        }
    }

    /// All the boards, each time: only the name and the address, which the control plane reads.
    private func save(_ next: [DaemonAPI.ProjectBoard], clearing: Bool = false) {
        guard let control else { return }
        isAsking = true
        Task {
            defer { isAsking = false }
            do {
                read = try await control.call(DaemonAPI.Method.projectsSetBoards,
                                              DaemonAPI.ProjectBoardsSet(id: project,
                                                                         boards: next.map { .init(name: $0.name, url: $0.url) }),
                                              returning: DaemonAPI.Project.self)
                problem = nil
                if clearing { name = ""; address = "" }
            } catch {
                problem = PeopleWords.refusal(error)
            }
        }
    }
}
