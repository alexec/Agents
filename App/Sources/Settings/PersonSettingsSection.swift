import AgentsKitCore
import Foundation
import SwiftUI

/// Settings ▸ General ▸ What agents call you (#121). The name every agent is told to use
/// for the person, in questions above all, and the pronouns they gave, if any.
///
/// Blank follows this Mac's account (the placeholder shows what that gives). Kept by the
/// Mac's daemon and copied to every server, so an agent anywhere uses the same name.
/// Saved on Return or on leaving the field, not per keystroke: each save goes to every
/// server too.
struct PersonSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var pronouns = ""
    @FocusState private var focused: Field?

    private enum Field { case name, pronouns }

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

    private static func kept(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
