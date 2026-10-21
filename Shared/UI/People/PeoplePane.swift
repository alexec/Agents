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
    /// Goes up when the control plane says people changed, to load them again.
    let revision: Int

    @State private var list: DaemonAPI.PeopleList?
    @State private var problem: String?
    @State private var isInviting = false
    @State private var removing: DaemonAPI.PersonRow?
    /// `control/status`'s line to run on a server so it asks to join as this person.
    @State private var joinCommand: String?

    private struct Load: Hashable {
        var reachable: Bool
        var revision: Int
    }

    var body: some View {
        Form {
            if let problem {
                Section {
                    Text(problem).appText(.supporting).tinted(.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .paperListRow()
            }
            if let list {
                ForEach(list.people) { person in
                    PersonSection(person: person, admin: list.admin,
                                  setRole: { role in Task { await setRole(person, role) } },
                                  remove: { removing = person })
                    if person.isYou, let joinCommand, !joinCommand.isEmpty {
                        JoinCommandSection(command: joinCommand)
                    }
                }
                Section {
                    if list.admin {
                        Button("Invite a Person…") { isInviting = true }
                    }
                } footer: {
                    Text(PeopleWords.foot(admin: list.admin))
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                .paperListRow()
            } else if problem == nil {
                Text("Loading…").appText(.supporting).foregroundStyle(.secondary).paperListRow()
            }
        }
        .paperForm()
        .task(id: Load(reachable: control != nil, revision: revision)) {
            // Until the control plane answers: Settings can open before the window's
            // connection to it is up.
            while !(await load()), !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .refreshable { await load() }
        .sheet(isPresented: $isInviting) {
            InvitePersonSheet(control: control)
                .paperSheet()
        }
        .onChange(of: isInviting) { _, open in if !open { Task { await load() } } }
        .confirmationDialog(removing.map(PeopleWords.removeTitle) ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { person in
            Button("Remove", role: .destructive) { Task { await remove(person) } }
            Button("Cancel", role: .cancel) {}
        } message: { person in
            Text(PeopleWords.removeMessage(person))
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
        do {
            list = try await control.call(DaemonAPI.Method.peopleList, DaemonAPI.Empty(),
                                          returning: DaemonAPI.PeopleList.self)
            joinCommand = (try? await control.call(DaemonAPI.Method.controlStatus,
                                                   returning: DaemonAPI.ControlStatus.self))?.joinCommand
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
            return error is JSONRPCError
        }
        return true
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
        await reload()
    }

    private func remove(_ person: DaemonAPI.PersonRow) async {
        guard let control else { return }
        do {
            _ = try await control.call(DaemonAPI.Method.peopleRemove, DaemonAPI.PersonRequest(user: person.id))
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
        }
        await reload()
    }

    /// Loads again and keeps a refusal on show.
    private func reload() async {
        let said = problem
        await load()
        if let said { problem = said }
    }
}

/// One person: their name, who they are to this client and their role, then their
/// machines and clients. For an admin, a role picker and Remove….
private struct PersonSection: View {
    let person: DaemonAPI.PersonRow
    let admin: Bool
    let setRole: (DaemonAPI.UserRole) -> Void
    let remove: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).appText(.reading)
                Text(PeopleWords.badges(person))
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if admin {
                Picker("Role", selection: Binding(get: { person.role }, set: setRole)) {
                    ForEach(DaemonAPI.UserRole.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            }
            ListLine(title: "Machines", words: PeopleWords.machines(person) ?? "None")
            ListLine(title: "Clients", words: PeopleWords.clients(person) ?? "None")
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
