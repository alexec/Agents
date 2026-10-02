import AgentsKitCore
import SwiftUI

/// Settings ▸ Resources (#116): what the person declares agents should take turns with,
/// and what the Mac finds by itself.
///
/// A declared resource is this Mac's host's, kept beside its leases, because how many
/// builds a machine can take is that machine's. It has a description agents read and
/// are told to follow, a count of how many may hold it at once, and lengths. The
/// screen, simulators and browsers are found, one agent at a time, and shown here only
/// so the page says everything there is to lease.
struct ResourcesSettingsView: View {
    @Environment(AppModel.self) private var model
    /// The one being edited, or a blank one being added.
    @State private var editing: Editing?

    struct Editing: Identifiable {
        var id = UUID()
        var original: DeclaredResource?
    }

    private var resources: [DaemonAPI.ResourceState] { model.leases?.resources ?? [] }
    private var declared: [DeclaredResource] { resources.compactMap(\.declared) }

    var body: some View {
        Form {
            Section {
                if declared.isEmpty {
                    Text("Nothing declared yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(declared) { resource in
                    DeclaredRow(resource: resource,
                                state: resources.first { $0.name == resource.name },
                                edit: { editing = Editing(original: resource) })
                }
                HStack {
                    Spacer()
                    Button("Add Resource\u{2026}") { editing = Editing(original: nil) }
                }
            } header: {
                Text("Declared")
            } footer: {
                Text("Agents see each one in list_resources with its description, even while it is free, "
                     + "and are told to lease it whenever the description applies. More than one holder "
                     + "lets that many agents hold it at once; the rest wait in line, in order.")
            }
            .paperListRow()

            Section {
                LabeledContent("Screen, mouse and keyboard") { Text("One at a time") }
                LabeledContent("Simulators") { Text(count(.simulator)) }
                LabeledContent("Browsers") { Text(count(.browser)) }
            } header: {
                Text("Found on this Mac")
            } footer: {
                Text("Found by the app, one agent at a time. These are not changed here.")
            }
            .foregroundStyle(.secondary)
            .paperListRow()
        }
        .paperForm()
        .task { await model.refreshLeases() }
        .sheet(item: $editing) { editing in
            DeclareResourceSheet(original: editing.original).paperSheet()
        }
    }

    private func count(_ kind: ResourceKind) -> String {
        let found = resources.filter { $0.kind == kind && !$0.isGone }.count
        return found == 0 ? "None" : "\(found), one at a time each"
    }
}

/// One declared resource: its name and rules on a line, its description under them.
private struct DeclaredRow: View {
    @Environment(AppModel.self) private var model
    let resource: DeclaredResource
    let state: DaemonAPI.ResourceState?
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(resource.displayName).fontWeight(.semibold)
                    Text(rules)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                Text(resource.description)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let held { Text(held).appText(.fine).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Button("Edit\u{2026}", action: edit)
            Button("Remove") { Task { await model.removeDeclaredResource(resource.name) } }
                .help("Stop declaring it. Anyone holding it keeps the lease.")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    /// "1 at a time · 30 min, at most 60".
    private var rules: String {
        let usual = min(resource.defaultMinutes ?? LeaseLimits.defaultMinutes, resource.rules.ceiling)
        return "\(LeaseWords.placesWords(resource.holders).capitalizedFirst) \u{00B7} \(usual) min, "
            + "at most \(resource.rules.ceiling)"
    }

    /// "2 of 3 held · 1 waiting", only while something is held or awaited.
    private var held: String? {
        guard let state, !state.holds.isEmpty || !state.line.isEmpty else { return nil }
        let holding = state.heldCount ?? "Held"
        return state.line.isEmpty ? holding : "\(holding) \u{00B7} \(state.line.count) waiting"
    }
}

/// Adding a declared resource, or changing one.
private struct DeclareResourceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let original: DeclaredResource?

    @State private var name = ""
    @State private var description = ""
    @State private var holders = 1
    @State private var usual = ""
    @State private var longest = ""
    @State private var problem: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "Declare a resource" : "Edit \(original!.displayName)")
                .appText(.reading).fontWeight(.semibold)
            Form {
                TextField("Name", text: $name, prompt: Text("build"))
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Description", text: $description,
                              prompt: Text("When an agent should lease it, and why"), axis: .vertical)
                        .lineLimit(3...6)
                    Text("Agents read this, and are told to lease the resource whenever it applies.")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                Stepper(value: $holders, in: 1...DeclaredResource.mostHolders) {
                    LabeledContent("Held by") {
                        Text(holders == 1 ? "1 agent at a time" : "\(holders) agents at once").monospacedDigit()
                    }
                }
                LabeledContent("Usual length") {
                    minutesField($usual, placeholder: "\(LeaseLimits.defaultMinutes)")
                }
                LabeledContent("Longest") {
                    minutesField($longest, placeholder: "\(LeaseLimits.maximumMinutes)")
                }
            }
            .formStyle(.columns)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .appText(.fine)
                    .tinted(.failure)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(original == nil ? "Declare" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: fill)
    }

    private func minutesField(_ text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 6) {
            TextField("", text: text, prompt: Text(placeholder))
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 60)
            Text("minutes").foregroundStyle(.secondary)
        }
    }

    private func fill() {
        guard let original else { return }
        name = original.displayName
        description = original.description
        holders = original.holders
        usual = original.defaultMinutes.map(String.init) ?? ""
        longest = original.maximumMinutes.map(String.init) ?? ""
    }

    /// A blank length is the app's own; anything else must be a whole number. Nil
    /// with `problem` said when it is neither.
    private func minutes(_ text: String, _ label: String) -> Int?? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .some(nil) }
        guard let value = Int(trimmed) else {
            problem = "\(label) is a whole number of minutes."
            return nil
        }
        return .some(value)
    }

    private func save() async {
        guard let key = ResourceName(name) else {
            problem = "Give it a name."
            return
        }
        guard let usualMinutes = minutes(usual, "The usual length"),
              let longestMinutes = minutes(longest, "The longest") else { return }
        let resource = DeclaredResource(name: key, displayName: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                        description: description, holders: holders,
                                        defaultMinutes: usualMinutes, maximumMinutes: longestMinutes)
        if let said = resource.problem {
            problem = said
            return
        }
        isSaving = true
        defer { isSaving = false }
        if let refused = await model.declareResource(resource, replacing: original?.name) {
            problem = refused
        } else {
            dismiss()
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
