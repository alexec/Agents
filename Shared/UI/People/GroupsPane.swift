import AgentsKitCore
import SwiftUI

/// Settings ▸ Groups (#1761, spec 736 FR-027, FR-028): each group, its people and the
/// machine providers it has. An admin makes, changes and removes groups; a member sees
/// the groups they are in, read only.
///
/// One view for the Mac's Settings pane and the Remote's Settings page (the web page's is
/// `Web/src/views/Groups.tsx`).
struct GroupsPane: View {
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?
    /// The people and groups this client keeps, loaded once per change (#2055).
    let state: PeopleState

    @State private var providers: [DaemonAPI.ProviderSummary] = []
    @State private var problem: String?
    @State private var editing: GroupSheet.Editing?
    @State private var removing: DaemonAPI.Group?
    /// Console ▸ People and Groups on the web page, for a SCIM group's Edit in Console (#1002, D17).
    @State private var console: URL?
    @Environment(\.openURL) private var openURL

    private struct Load: Hashable {
        var reachable: Bool
        var revision: Int
    }

    /// Nil until the control plane answers.
    private var groups: [DaemonAPI.Group]? { state.list == nil ? nil : state.groups }
    private var people: [DaemonAPI.PersonRow] { state.list?.people ?? [] }
    private var admin: Bool { state.list?.admin ?? false }

    var body: some View {
        Form {
            if let problem = problem ?? state.listProblem {
                Section {
                    Text(problem).appText(.supporting).tinted(.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .paperListRow()
            }
            if let groups {
                ForEach(groups) { group in
                    Section {
                        Text(group.name).appText(.reading)
                        // A SCIM group (#1002, FR-031): where it comes from, and whether it makes admins.
                        // Read only here: an admin marks it in Console ▸ People and Groups (D17).
                        if let source = group.source {
                            Text(GroupWords.orgLine(group, provider: state.providerName(source.scim)))
                                .appText(.fine).foregroundStyle(.secondary)
                            if admin, let console {
                                Button(PeopleWords.editInConsole) { openURL(console) }.buttonStyle(.borderless)
                            }
                        }
                        GroupLine(title: "People", words: GroupWords.members(group, people: people))
                        // Its bots apart from its people (#2132).
                        GroupLine(title: BotWords.title, words: GroupWords.bots(group, people: people))
                        GroupLine(title: "Machine providers", words: GroupWords.providers(group, of: providers) ?? "None")
                        // What its bots may spend together in a day (#2074).
                        GroupLine(title: "Daily cap", words: GroupWords.capLine(group, people: people))
                        if admin {
                            HStack {
                                Button("Edit…") { editing = .init(group: group) }
                                Spacer()
                                Button("Remove…", role: .destructive) { removing = group }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .paperListRow()
                }
                Section {
                    if admin {
                        Button("Make a Group…") { editing = .init(group: nil) }
                    } else if groups.isEmpty {
                        Text("You are in no group.").appText(.supporting).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(GroupWords.foot(admin: admin)).appText(.fine).foregroundStyle(.secondary)
                }
                .paperListRow()
            } else if problem == nil, state.listProblem == nil {
                Text("Loading…").appText(.supporting).foregroundStyle(.secondary).paperListRow()
            }
        }
        .paperForm()
        // The providers each group has change with the groups.
        .task(id: Load(reachable: control != nil, revision: state.revision)) {
            while !(await load()), !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
            }
            if let control, admin, console == nil {
                let status = try? await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
                console = PeopleWords.consoleURL(status)
            }
        }
        .refreshable { await load() }
        .sheet(item: $editing) { editing in
            // A group saved is told as control/groupsChanged: the groups load then.
            GroupSheet(control: control, editing: editing, people: people.filter { $0.kind == .person }) {}
            .paperSheet()
        }
        .confirmationDialog(removing.map(GroupWords.removeTitle) ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { group in
            Button("Remove", role: .destructive) { Task { await remove(group) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(GroupWords.removeMessage)
        }
    }

    /// False when the control plane did not answer at all, so it is worth asking again.
    @discardableResult
    private func load() async -> Bool {
        guard let control else {
            problem = "The control plane can’t be reached."
            return true
        }
        // A control plane with several copies has no providers: the groups still show.
        let answer = try? await control.call(DaemonAPI.Method.providersList, DaemonAPI.Empty())
        providers = (try? answer?["providers"]?.decode([DaemonAPI.ProviderSummary].self)) ?? []
        problem = nil
        if state.list != nil { return true }
        return await state.loadList(control)
    }

    private func remove(_ group: DaemonAPI.Group) async {
        guard let control else { return }
        do {
            _ = try await control.call(DaemonAPI.Method.groupsRemove, DaemonAPI.GroupRequest(id: group.id))
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
        }
    }
}

/// A heading word over a line of names.
private struct GroupLine: View {
    let title: String
    let words: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).appText(.fine).foregroundStyle(.secondary)
            Text(words).appText(.supporting)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Make a Group… and Edit…: a name, and everyone or the people named.
struct GroupSheet: View {
    struct Editing: Identifiable {
        var group: DaemonAPI.Group?
        var id: String { group?.id ?? "new" }
    }

    @Environment(\.dismiss) private var dismiss
    let control: DaemonClient?
    let editing: Editing
    let people: [DaemonAPI.PersonRow]
    let saved: () -> Void

    @State private var name = ""
    @State private var everyone = false
    @State private var members: Set<String> = []
    /// What its bots may spend together in a day (#2074), as typed.
    @State private var cap = ""
    @State private var problem: String?
    @State private var isAsking = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var title: String { editing.group == nil ? "Make a Group" : "Edit \(editing.group?.name ?? "Group")" }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 16) {
            Text(title).appText(.title)
            form
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editing.group == nil ? "Make Group" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || isAsking)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear(perform: fill)
        #else
        NavigationStack {
            form
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(editing.group == nil ? "Make" : "Save") { Task { await save() } }
                            .disabled(trimmed.isEmpty || isAsking)
                    }
                }
        }
        .onAppear(perform: fill)
        #endif
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("Platform"))
                Toggle("Everyone", isOn: $everyone)
            } footer: {
                Text("Everyone takes in each person who joins later too.")
                    .appText(.fine).foregroundStyle(.secondary)
            }
            .paperListRow()
            Section {
                TextField("Daily cap", text: $cap, prompt: Text("No cap, or dollars a day"))
            } footer: {
                Text(GroupWords.capFoot).appText(.fine).foregroundStyle(.secondary)
            }
            .paperListRow()
            if !everyone {
                Section("People") {
                    ForEach(people) { person in
                        Toggle(person.name, isOn: Binding(
                            get: { members.contains(person.id) },
                            set: { on in if on { members.insert(person.id) } else { members.remove(person.id) } }))
                    }
                }
                .paperListRow()
            }
            if let problem {
                Text(problem).appText(.supporting).tinted(.failure).paperListRow()
            }
        }
        .paperForm()
    }

    private func fill() {
        guard let group = editing.group else { return }
        name = group.name
        everyone = group.everyone
        members = Set(group.members)
        if let usd = group.caps?.dailyUSD { cap = BotWords.dollars(usd) }
    }

    private func save() async {
        guard let control else {
            problem = "The control plane can’t be reached."
            return
        }
        guard !trimmed.isEmpty, !isAsking else { return }
        let caps: DaemonAPI.SpendCaps
        switch BotWords.readCap(cap) {
        case .none: caps = DaemonAPI.SpendCaps(dailyUSD: nil)
        case .dollars(let usd): caps = DaemonAPI.SpendCaps(dailyUSD: usd)
        case .refused(let why):
            problem = why
            return
        }
        isAsking = true
        defer { isAsking = false }
        // In the order People lists them.
        let named = people.map(\.id).filter(members.contains)
        do {
            _ = try await control.call(DaemonAPI.Method.groupsSet,
                                       DaemonAPI.GroupSet(id: editing.group?.id, name: trimmed, everyone: everyone,
                                                          members: everyone ? [] : named, caps: caps),
                                       returning: DaemonAPI.Group.self)
            saved()
            dismiss()
        } catch {
            problem = PeopleWords.refusal(error)
        }
    }
}

/// A provider's group, for an admin: a menu of the groups and Admins Only (#1761).
struct ProviderGroupPicker: View {
    let provider: DaemonAPI.ProviderSummary
    let groups: [DaemonAPI.Group]
    let set: (String?) -> Void

    var body: some View {
        Picker("Group", selection: Binding(get: { provider.group ?? "" }, set: { set($0.isEmpty ? nil : $0) })) {
            Text(GroupWords.adminsOnly).tag("")
            ForEach(groups) { Text($0.name).tag($0.id) }
        }
    }
}
