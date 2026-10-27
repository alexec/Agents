import AgentsKitCore
import SwiftUI

/// A folder's project's tools on its Connectors page (#2669): Tasks, Code review and CI are
/// the project's, the same in every folder of it, and only its owner or an admin changes
/// them. For them, each slot has Use for the Whole Project (the folder's own, for every
/// folder) or Use Each Folder's Own. The Mac and the Remote draw it; the web page's is
/// `ProjectSlots` in `Web/src/views/ConnectorSetup.tsx`.
struct ProjectSlotsCard: View {
    /// The control plane, which keeps the projects; nil when there is none.
    let control: DaemonClient?
    let setup: DaemonAPI.ConnectorSetup
    /// The project changed a slot: read the set-up again.
    let changed: () async -> Void

    @State private var project: DaemonAPI.Project?
    @State private var problem: String?
    @State private var isAsking = false

    private var name: String { project?.name ?? setup.projectName ?? ProjectWords.title }

    var body: some View {
        if setup.project != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text(ProjectWords.slotsOwner(name))
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if project?.mayChange == true {
                    ForEach(setup.slots.filter { $0.slot != .workspace }) { slot in
                        row(slot)
                    }
                }
                if let problem {
                    Text(problem).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperRaised(in: RoundedRectangle(cornerRadius: 10))
            .task(id: setup.project) { await load() }
        }
    }

    private func row(_ slot: DaemonAPI.ConnectorSlot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(ConnectorSetupWords.heading(slot.slot)).appText(.fine).fontWeight(.semibold)
                .foregroundStyle(.secondary).textCase(.uppercase)
                .frame(minWidth: 90, alignment: .leading)
            Text(ProjectWords.slotLine(slot, name: name))
                .appText(.fine)
                .lineLimit(2)
            Spacer(minLength: 8)
            if slot.isFromProject {
                Button(ProjectWords.useFolderOwn) { Task { await set(slot.slot, nil) } }
                    .projectLinkStyle()
                    .disabled(isAsking)
            } else if let value = DaemonAPI.ProjectSlot.from(setup, slot) {
                Button(ProjectWords.useForProject) { Task { await set(slot.slot, value) } }
                    .projectLinkStyle()
                    .disabled(isAsking)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The folder's project, for whether this person may change it. A control plane before
    /// projects has none.
    private func load() async {
        guard let control, let id = setup.project else { return }
        let list = try? await control.call(DaemonAPI.Method.projectsList, DaemonAPI.Empty(),
                                           returning: DaemonAPI.ProjectList.self)
        project = list?.projects.first { $0.id == id }
    }

    private func set(_ slot: DaemonAPI.ConnectorSlotKind, _ value: DaemonAPI.ProjectSlot?) async {
        guard let control, let id = setup.project else { return }
        isAsking = true
        defer { isAsking = false }
        do {
            project = try await control.call(DaemonAPI.Method.projectsSetSlot,
                                             DaemonAPI.ProjectSlotSet(id: id, slot: slot, value: value),
                                             returning: DaemonAPI.Project.self)
            problem = nil
            // The machine hears it from the control plane (host/projects): give it a moment.
            try? await Task.sleep(for: .milliseconds(400))
            await changed()
        } catch {
            problem = PeopleWords.refusal(error)
        }
    }
}

private extension View {
    /// A link on the Mac, a borderless accent button on the iPhone and iPad.
    @ViewBuilder func projectLinkStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link).appText(.fine)
        #else
        buttonStyle(.borderless).tint(Paper.accent).appText(.fine)
        #endif
    }
}
