import AgentsKitCore
import Foundation
import SwiftUI

/// Settings ▸ Account ▸ What agents call you (#121). The name every agent is told to use
/// for the person, in questions above all, and the pronouns they gave, if any.
///
/// Blank follows this Mac's account (the placeholder shows what that gives). Kept by the
/// Mac's daemon and copied to every server, so an agent anywhere uses the same name.
/// Saved on Return or on leaving the field, not per keystroke: each save goes to every
/// server too.
///
/// A second section (#2951) keeps the person's GitHub, GitLab and Linear logins: named on
/// the Pull requests, Merge requests and Issues pages' Team section, and used to say an
/// agent is on one of the viewer's own rows. Filled in from this Mac's own connection
/// (Activity ▸ Connectors) when it is signed in; given here only when it is not.
struct PersonSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var pronouns = ""
    @State private var github = ""
    @State private var gitlab = ""
    @State private var linear = ""
    @State private var connectionLogins: [DaemonAPI.ConnectionProvider: String] = [:]
    /// False until loadLogins answers, so a save before then cannot clear what is kept.
    @State private var loginsLoaded = false
    @FocusState private var focused: Field?

    private enum Field { case name, pronouns, github, gitlab, linear }

    /// What a blank name gives: the first word of this Mac account's full name.
    private var accountName: String { PersonSettings().effectiveName() }

    var body: some View {
        if let person = model.person {
            Section {
                TextField("What agents call you", text: $name, prompt: Text(accountName))
                    .focused($focused, equals: .name)
                    .onSubmit(save)
                TextField("Pronouns", text: $pronouns, prompt: Text("Not given"))
                    .focused($focused, equals: .pronouns)
                    .onSubmit(save)
            } header: {
                Text("You")
            } footer: {
                Text("Agents name themselves and you in what they ask, rather than writing “I” and “you”. Without pronouns, they use your name or “they”.")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            .paperListRow()
            .onAppear { fill(from: person) }
            .onChange(of: person) { _, fresh in if focused == nil { fill(from: fresh) } }
            .onChange(of: focused) { _, now in if now == nil { save() } }

            Section {
                TextField("GitHub login", text: $github, prompt: Text(connectionLogins[.github] ?? "Not given"))
                    .focused($focused, equals: .github)
                    .onSubmit(saveLogins)
                TextField("GitLab login", text: $gitlab, prompt: Text(connectionLogins[.gitlab] ?? "Not given"))
                    .focused($focused, equals: .gitlab)
                    .onSubmit(saveLogins)
                TextField("Linear login", text: $linear, prompt: Text(connectionLogins[.linear] ?? "Not given"))
                    .focused($focused, equals: .linear)
                    .onSubmit(saveLogins)
            } header: {
                Text("GitHub, GitLab and Linear")
            } footer: {
                Text("Named on the Pull requests, Merge requests and Issues pages’ Team section, and used to say an agent is on one of your own. Filled in from this Mac’s own connection (Activity ▸ Connectors) when it is signed in; given here only when it is not.")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            .paperListRow()
            .onAppear { Task { await loadLogins(); await loadConnections() } }
            .onChange(of: focused) { _, now in if now == nil { saveLogins() } }
        }
    }

    private func fill(from person: PersonSettings) {
        name = person.name ?? ""
        pronouns = person.pronouns ?? ""
    }

    private func save() {
        let next = PersonSettings(name: Self.kept(name), pronouns: Self.kept(pronouns))
        guard next != model.person else { return }
        Task { await model.setPerson(next) }
    }

    /// The control plane's own answer for "me" (#2951), to fill the three fields.
    private func loadLogins() async {
        guard let control = model.controlRequests,
              let list = try? await control.call(DaemonAPI.Method.peopleForViews, DaemonAPI.Empty(),
                                                  returning: DaemonAPI.PeopleForViews.self) else { return }
        defer { loginsLoaded = true }
        guard let me = list.people.first(where: { $0.you == true }) else { return }
        github = me.githubLogin ?? ""
        gitlab = me.gitlabLogin ?? ""
        linear = me.linearLogin ?? ""
    }

    /// This Mac's own connections (#2951), for the fields' placeholders.
    private func loadConnections() async {
        guard case .success(let list) = await model.connections(on: .mac) else { return }
        for c in list {
            if let login = c.login, !login.isEmpty {
                connectionLogins[c.provider] = login
            }
        }
    }

    private func saveLogins() {
        guard loginsLoaded, let control = model.controlRequests else { return }
        let logins = DaemonAPI.ForgeLogins(github: Self.kept(github) ?? "", gitlab: Self.kept(gitlab) ?? "", linear: Self.kept(linear) ?? "")
        Task { _ = try? await control.call(DaemonAPI.Method.peopleSetForgeLogins, logins) }
    }

    private static func kept(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
