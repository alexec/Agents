import AgentsKitCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Settings ▸ People (#994, spec 736 Team T1): each person, their role, and the machines
/// and clients that belong to them. An admin sets roles, invites a person and removes one;
/// a member sees only themselves, read only. With one person it shows them as
/// "You · Local owner · Admin", with Invite a Person….
///
/// One view for the Mac's Settings pane and the Remote's Settings page (the web page's is
/// `Web/src/views/People.tsx`).
struct PeoplePane: View {
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?
    /// The people and groups this client keeps, loaded once per change (#2055).
    let people: PeopleState

    @State private var problem: String?
    @State private var isInviting = false
    /// Remove…'s sheet (#2077): it opens at once, and asks what would go while it shows.
    @State private var removing: DaemonAPI.PersonRow?
    @State private var isRotating = false
    /// Said once the control key was rotated (#997).
    @State private var rotated = false
    /// Make a Bot… (nil bot) and Group and Cap… (#1761).
    @State private var botSheet: BotSheetItem?
    @State private var machineFor: DaemonAPI.PersonRow?

    struct BotSheetItem: Identifiable {
        var bot: DaemonAPI.PersonRow?
        var id: String { bot?.id ?? "new" }
    }

    private var list: DaemonAPI.PeopleList? { people.list }
    /// The groups a bot may be in (#1761).
    private var groups: [DaemonAPI.Group] { people.groups }

    var body: some View {
        Form {
            if let problem = problem ?? people.listProblem {
                Section {
                    Text(problem).appText(.supporting).tinted(.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .paperListRow()
            }
            // Each bot stopped at a cap, for an admin (#1761, #2073).
            if list?.admin == true, !people.capped.isEmpty {
                Section {
                    ForEach(people.capped, id: \.user) { reached in
                        Text(BotWords.capReached(reached)).appText(.supporting).tinted(.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .paperListRow()
            }
            if let list {
                ForEach(list.people) { person in
                    PersonSection(person: person, admin: list.admin, groups: groups,
                                  setRole: { role in Task { await setRole(person, role) } },
                                  remove: { removing = person },
                                  setCap: { botSheet = BotSheetItem(bot: person) },
                                  addMachine: { machineFor = person })
                    if person.isYou, let joinCommand = people.joinCommand, !joinCommand.isEmpty {
                        JoinCommandSection(command: joinCommand)
                    }
                }
                Section {
                    if list.admin {
                        Button("Invite a Person…") { isInviting = true }
                        // A bot runs the team's workflows (#1761).
                        Button(BotWords.make) { botSheet = BotSheetItem(bot: nil) }
                    }
                } footer: {
                    Text(PeopleWords.foot(admin: list.admin))
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                .paperListRow()
                if list.admin {
                    Section {
                        Button("Rotate Control Key…") { isRotating = true }
                        if rotated {
                            Text(PeopleWords.rotated).appText(.supporting)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } footer: {
                        Text(PeopleWords.rotateFoot)
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                    }
                    .paperListRow()
                }
            } else if problem == nil, people.listProblem == nil {
                Text("Loading…").appText(.supporting).foregroundStyle(.secondary).paperListRow()
            }
        }
        .paperForm()
        .task(id: control != nil) {
            // Until the control plane answers: Settings can open before the window's
            // connection to it is up. Once loaded, the model keeps the list true.
            while people.list == nil, !(await load()), !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .refreshable { await load() }
        .sheet(isPresented: $isInviting) {
            InvitePersonSheet(control: control)
                .paperSheet()
        }
        .sheet(item: $botSheet) { item in
            // A bot made or changed is told as control/peopleChanged: the list loads then.
            BotSheet(control: control, bot: item.bot, groups: groups) {}
                .paperSheet()
        }
        .sheet(item: $machineFor) { bot in
            BotMachineSheet(control: control, bot: bot).paperSheet()
        }
        .sheet(item: $removing) { person in
            RemovePersonSheet(control: control, person: person)
                .paperSheet()
        }
        .confirmationDialog(PeopleWords.rotateTitle, isPresented: $isRotating, titleVisibility: .visible) {
            Button("Rotate") { Task { await rotate() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(PeopleWords.rotateMessage)
        }
    }

    // MARK: Asking

    /// False when the control plane did not answer at all, so it is worth asking again.
    @discardableResult
    private func load() async -> Bool {
        guard let control else {
            problem = "The control plane can’t be reached."
            return true
        }
        problem = nil
        return await people.loadList(control)
    }

    private func setRole(_ person: DaemonAPI.PersonRow, _ role: DaemonAPI.UserRole) async {
        guard let control, role != person.role else { return }
        do {
            _ = try await control.call(DaemonAPI.Method.peopleSetRole, DaemonAPI.PersonRoleRequest(user: person.id, role: role))
            problem = nil
        } catch {
            // Refused when it would leave no admin: said, and the picker shows the role kept.
            problem = PeopleWords.refusal(error)
        }
        // A change is told as control/peopleChanged, which loads the list once for every pane.
    }

    /// control/rotate (#997). This client's own connection closes a moment later, and it
    /// takes the new key as it connects again.
    private func rotate() async {
        guard let control else { return }
        do {
            _ = try await control.call(DaemonAPI.Method.controlRotate, DaemonAPI.Empty())
            rotated = true
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
        }
    }
}

/// One person: their name, who they are to this client and their role, then their
/// machines and clients. For an admin, a role picker and Remove….
private struct PersonSection: View {
    let person: DaemonAPI.PersonRow
    let admin: Bool
    let groups: [DaemonAPI.Group]
    let setRole: (DaemonAPI.UserRole) -> Void
    let remove: () -> Void
    let setCap: () -> Void
    let addMachine: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).appText(.reading)
                Text(PeopleWords.badges(person))
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if person.kind == .bot {
                // A bot has no role, clients or sign-in: its group, cap and spend (#1761).
                ListLine(title: "Group and cap", words: BotWords.line(person, groups: groups))
                ListLine(title: "Machines", words: PeopleWords.machines(person) ?? "None")
                if admin {
                    Button(BotWords.setCap, action: setCap)
                    Button(BotWords.addMachine, action: addMachine)
                }
            } else {
                if admin {
                    Picker("Role", selection: Binding(get: { person.role }, set: setRole)) {
                        ForEach(DaemonAPI.UserRole.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                ListLine(title: "Machines", words: PeopleWords.machines(person) ?? "None")
                ListLine(title: "Clients", words: PeopleWords.clients(person) ?? "None")
            }
            if admin, PeopleWords.canRemove(person) {
                Button("Remove…", role: .destructive, action: remove)
            }
        }
        .paperListRow()
    }
}

/// Add a machine without a code (#994): the line to run on a server so that it asks to
/// join as this person, with Copy. The machine then shows a code, approved on its card.
private struct JoinCommandSection: View {
    let command: String
    @State private var copied = false

    var body: some View {
        Section {
            Text(command)
                .appText(.code)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button(copied ? "Copied" : "Copy") {
                copyToPasteboard(command)
                copied = true
            }
        } header: {
            Text(PeopleWords.joinCommandTitle)
        } footer: {
            Text(PeopleWords.joinCommandFoot)
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .paperListRow()
    }
}

/// A heading word over a line of names, for a narrow phone as much as a wide pane.
private struct ListLine: View {
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

/// Remove… (FR-029, #1763, #2077): opens at once, asks the control plane what would go (the
/// person's started machines with their work that is not pushed) while it shows, then says
/// it a line each, as the web page's sheet does. An older control plane does not know
/// `people/removePreview`: the sheet then says what it did before.
struct RemovePersonSheet: View {
    @Environment(\.dismiss) private var dismiss
    let control: DaemonClient?
    let person: DaemonAPI.PersonRow

    @State private var preview: DaemonAPI.PersonRemovePreview?
    @State private var isAsking = true
    @State private var isRemoving = false
    @State private var problem: String?

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 16) {
            Text(PeopleWords.removeTitle(person)).appText(.title)
            form
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) { Task { await remove() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isAsking || isRemoving)
            }
        }
        .padding(24)
        .frame(width: 460)
        .task { await ask() }
        #else
        NavigationStack {
            form
                .navigationTitle(PeopleWords.removeTitle(person))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Remove", role: .destructive) { Task { await remove() } }
                            .disabled(isAsking || isRemoving)
                    }
                }
        }
        .task { await ask() }
        #endif
    }

    private var form: some View {
        Form {
            Section {
                if isAsking {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(PeopleWords.asking(person)).appText(.supporting).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ForEach(PeopleWords.removeLines(person, preview: preview), id: \.self) { line in
                        Text(line).appText(.supporting)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .paperListRow()
            if let problem {
                Text(problem).appText(.supporting).tinted(.failure)
                    .fixedSize(horizontal: false, vertical: true)
                    .paperListRow()
            }
        }
        .paperForm()
    }

    private func ask() async {
        guard let control else {
            problem = "The control plane can’t be reached."
            isAsking = false
            return
        }
        defer { isAsking = false }
        do {
            preview = try await control.call(DaemonAPI.Method.peopleRemovePreview, DaemonAPI.PersonRequest(user: person.id),
                                             returning: DaemonAPI.PersonRemovePreview.self)
        } catch let error as JSONRPCError where error.code == JSONRPCError.methodNotFound {
            preview = nil
        } catch {
            problem = PeopleWords.refusal(error)
        }
    }

    /// The change is told as control/peopleChanged, which loads the list once for every pane.
    private func remove() async {
        guard let control, !isRemoving else { return }
        isRemoving = true
        defer { isRemoving = false }
        do {
            _ = try await control.call(DaemonAPI.Method.peopleRemove, DaemonAPI.PersonRequest(user: person.id))
            dismiss()
        } catch {
            problem = PeopleWords.refusal(error)
        }
    }
}

/// Invite a Person…: a name and a role, then the code to send them. It is a pairing code,
/// good once for 7 days: pasted where a code is asked for, the client pairs as them.
struct InvitePersonSheet: View {
    @Environment(\.dismiss) private var dismiss
    let control: DaemonClient?

    @State private var name = ""
    @State private var role: DaemonAPI.UserRole = .member
    @State private var invited: DaemonAPI.PersonInvited?
    @State private var problem: String?
    @State private var isAsking = false
    @State private var copied = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 16) {
            Text("Invite a Person").appText(.title)
            form
            HStack {
                Spacer()
                if invited == nil {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Make Invite Code") { Task { await invite() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmed.isEmpty || isAsking)
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        #else
        NavigationStack {
            form
                .navigationTitle("Invite a Person")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if invited == nil {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Make Code") { Task { await invite() } }
                                .disabled(trimmed.isEmpty || isAsking)
                        }
                    } else {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    }
                }
        }
        #endif
    }

    private var form: some View {
        Form {
            if let invited {
                Section {
                    Text(invited.text)
                        .appText(.code)
                        .textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy") { copy(invited.text) }
                } header: {
                    Text("Invite code for \(invited.name), as \(invited.role.title)")
                } footer: {
                    Text(PeopleWords.inviteFoot(invited))
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                .paperListRow()
            } else {
                Section {
                    TextField("Name", text: $name, prompt: Text("Their name"))
                        .onSubmit { if !trimmed.isEmpty { Task { await invite() } } }
                    Picker("Role", selection: $role) {
                        ForEach(DaemonAPI.UserRole.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("An admin adds and removes people. A member sees only their own clients and machines.")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                .paperListRow()
                if let problem {
                    Text(problem).appText(.supporting).tinted(.failure).paperListRow()
                }
            }
        }
        .paperForm()
    }

    private func invite() async {
        guard let control else {
            problem = "The control plane can’t be reached."
            return
        }
        guard !trimmed.isEmpty, !isAsking else { return }
        isAsking = true
        defer { isAsking = false }
        do {
            invited = try await control.call(DaemonAPI.Method.peopleInvite, DaemonAPI.PersonInvite(name: trimmed, role: role),
                                             returning: DaemonAPI.PersonInvited.self)
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
        }
    }

    private func copy(_ text: String) {
        copyToPasteboard(text)
        copied = true
    }
}

/// Puts a code or a command on the pasteboard, on the Mac and the Remote alike.
private func copyToPasteboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}
