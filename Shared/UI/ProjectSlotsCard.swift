import AgentsKitCore
import SwiftUI

/// A folder's project's tools on its Connectors page (#2669): Tasks, Code review and CI are
/// the project's, the same in every folder of it, and only its owner or an admin changes
/// them. For them, each slot has Use for the Whole Project (the folder's own, for every
/// folder) or Use Each Folder's Own. The Mac draws it as a card, the Remote as List rows
/// (#2757); the web page's is `ProjectSlots` in `Web/src/views/ConnectorSetup.tsx`.
struct ProjectSlotsCard: View {
    /// The control plane, which keeps the projects; nil when there is none.
    let control: DaemonClient?
    let setup: DaemonAPI.ConnectorSetup
    /// The project changed a slot: read the set-up again.
    let changed: () async -> Void

    @State private var project: DaemonAPI.Project?
    @State private var problem: String?
    /// Why the project could not be read (#2756): its rows wait on it, so say so.
    @State private var notRead: String?
    @State private var isAsking = false

    private var name: String { project?.name ?? setup.projectName ?? ProjectWords.title }

    var body: some View {
        #if os(macOS)
        card
        #else
        rows
        #endif
    }

    #if os(macOS)
    @ViewBuilder private var card: some View {
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
                if let notRead {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(notRead).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
                        Button(ProjectWords.tryAgain) { Task { await load() } }
                            .projectLinkStyle()
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
    #else
    /// List rows in the Remote's Project section (#2757): who owns the slots, a row per slot
    /// with its action under it, and Try Again as a row of its own.
    @ViewBuilder private var rows: some View {
        if setup.project != nil {
            Text(ProjectWords.slotsOwner(name))
                .foregroundStyle(.secondary)
                .task(id: setup.project) { await load() }
            if project?.mayChange == true {
                ForEach(setup.slots.filter { $0.slot != .workspace }) { slot in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ConnectorSetupWords.heading(slot.slot))
                        Text(ProjectWords.slotLine(slot, name: name))
                            .appText(.supporting)
                            .foregroundStyle(.secondary)
                        if let action = action(slot) {
                            Button(action.label) { Task { await set(slot.slot, action.value) } }
                                .buttonStyle(.borderless)
                                .tint(Paper.accent)
                                .disabled(isAsking)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            }
            if let notRead {
                Text(notRead).tinted(.failure)
                Button(ProjectWords.tryAgain) { Task { await load() } }
            }
            if let problem {
                Text(problem).tinted(.failure)
            }
        }
    }

    /// The slot's one action: back to each folder's own, or the folder's own for the project.
    private func action(_ slot: DaemonAPI.ConnectorSlot) -> (label: String, value: DaemonAPI.ProjectSlot?)? {
        if slot.isFromProject { return (ProjectWords.useFolderOwn, nil) }
        return DaemonAPI.ProjectSlot.from(setup, slot).map { (ProjectWords.useForProject, $0) }
    }
    #endif

    #if os(macOS)
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
    #endif

    /// The folder's project, for whether this person may change it. A control plane before
    /// projects has none; any other failure says why, with Try Again (#2756).
    private func load() async {
        guard let control, let id = setup.project else { return }
        do {
            let list = try await control.call(DaemonAPI.Method.projectsList, DaemonAPI.Empty(),
                                              returning: DaemonAPI.ProjectList.self)
            project = list.projects.first { $0.id == id }
            notRead = nil
        } catch {
            notRead = ProjectWords.notRead(error)
            if notRead == nil { project = nil }
        }
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

#if os(macOS)
private extension View {
    /// A link, in the card's fine text.
    func projectLinkStyle() -> some View {
        buttonStyle(.link).appText(.fine)
    }
}
#endif
