import AgentsKitCore
import SwiftUI

/// Control plane ▸ Sign-in (#995, spec 736 FR-004, FR-006), for admins: turn Apple, Google
/// and GitHub sign-in on or off, and allow Google Workspace domains and GitHub organisations.
/// A provider this build has no client id for says so, and cannot be turned on.
///
/// One view for the Mac's Settings pane and the Remote's Settings page (the web page's is
/// `Web/src/views/SignInSection.tsx`).
struct SignInPane: View {
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?
    /// Goes up when the control plane says people changed (a provider changed too).
    let revision: Int

    @State private var providers: DaemonAPI.SignInProviders?
    @State private var problem: String?
    @State private var domains = ""
    @State private var organisations = ""
    @State private var isSaving = false

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
            if let providers {
                Section {
                    ForEach(providers.providers) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(SignInProviderName.title(row.provider), isOn: Binding(
                                get: { row.on },
                                set: { on in Task { await configure(.init(provider: row.provider, on: on)) } }))
                                .disabled(!row.available || isSaving)
                            if let why = row.why {
                                Text(why).appText(.fine).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text(SignInWords.paneFoot).appText(.fine).foregroundStyle(.secondary)
                }
                .paperListRow()
                Section {
                    TextField("example.com, example.org", text: $domains)
                        .onSubmit { Task { await saveDomains() } }
                    Button("Save Domains") { Task { await saveDomains() } }
                        .disabled(isSaving || list(domains) == (providers.domains ?? []))
                } header: {
                    Text(SignInWords.domainsTitle)
                } footer: {
                    Text(SignInWords.domainsFoot).appText(.fine).foregroundStyle(.secondary)
                }
                .paperListRow()
                Section {
                    TextField("acme", text: $organisations)
                        .onSubmit { Task { await saveOrganisations() } }
                    Button("Save Organisations") { Task { await saveOrganisations() } }
                        .disabled(isSaving || list(organisations) == (providers.organisations ?? []))
                } header: {
                    Text(SignInWords.organisationsTitle)
                } footer: {
                    Text(SignInWords.organisationsFoot).appText(.fine).foregroundStyle(.secondary)
                }
                .paperListRow()
            } else if problem == nil {
                Text("Loading…").appText(.supporting).foregroundStyle(.secondary).paperListRow()
            }
        }
        .paperForm()
        .task(id: Load(reachable: control != nil, revision: revision)) {
            while !(await load()), !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .refreshable { await load() }
    }

    private func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func shown(_ answer: DaemonAPI.SignInProviders) {
        providers = answer
        domains = (answer.domains ?? []).joined(separator: ", ")
        organisations = (answer.organisations ?? []).joined(separator: ", ")
    }

    /// False when the control plane did not answer at all, so it is worth asking again.
    @discardableResult
    private func load() async -> Bool {
        guard let control else {
            problem = "The control plane can’t be reached."
            return true
        }
        do {
            shown(try await control.call(DaemonAPI.Method.signInProviders, DaemonAPI.Empty(),
                                         returning: DaemonAPI.SignInProviders.self))
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
            return error is JSONRPCError
        }
        return true
    }

    private func configure(_ change: DaemonAPI.SignInConfigure) async {
        guard let control else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            shown(try await control.call(DaemonAPI.Method.signInConfigure, change, returning: DaemonAPI.SignInProviders.self))
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
        }
    }

    private func saveDomains() async {
        await configure(.init(provider: "google", domains: list(domains)))
    }

    private func saveOrganisations() async {
        await configure(.init(provider: "github", organisations: list(organisations)))
    }
}
