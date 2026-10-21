import AgentsKitCore
import SwiftUI

/// You ▸ Account ▸ Sign-ins (#995, spec 736 FR-005): how this person signs in, with Add a
/// Sign-in… (Apple, Google or GitHub, on this device) and Remove for an outside one. A
/// sign-in added here pairs this person's other Macs, iPhones and iPads with no code.
///
/// A section, for the Mac's Account pane and the Remote's Account page (the web page lists
/// them in `Web/src/views/SignInSection.tsx`, and cannot add one: a browser pairs by code).
struct SignInsSection: View {
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?
    /// The control key this client trusts, which the nonce is bound to; nil when not paired.
    let controlKey: Data?
    /// Goes up when the control plane says people changed.
    let revision: Int

    @State private var signIns: [DaemonAPI.SignIn]?
    @State private var problem: String?
    @State private var adding: Adding?
    @State private var removing: DaemonAPI.SignIn?

    /// The providers on, and the nonce for this one sign-in.
    struct Adding: Identifiable {
        var providers: [DaemonAPI.SignInProvider]
        var nonce: String
        var id: String { nonce }
    }

    private struct Load: Hashable {
        var reachable: Bool
        var revision: Int
    }

    var body: some View {
        Section {
            if let problem {
                Text(problem).appText(.supporting).tinted(.failure).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(signIns ?? [], id: \.self) { signIn in
                HStack {
                    Text(SignInWords.row(signIn)).appText(.reading)
                    Spacer()
                    if SignInProviderName.isOutside(signIn.provider), signIn.account != nil {
                        Button("Remove…", role: .destructive) { removing = signIn }
                            .buttonStyle(.borderless)
                    }
                }
            }
            if control != nil, controlKey != nil {
                Button("Add a Sign-in…") { Task { await startAdding() } }
            }
        } header: {
            Text(SignInWords.signInsTitle)
        } footer: {
            Text(SignInWords.signInsFoot).appText(.fine).foregroundStyle(.secondary)
        }
        .task(id: Load(reachable: control != nil, revision: revision)) { await load() }
        .sheet(item: $adding) { adding in
            AddSignInSheet(adding: adding, add: { provider, token in await add(provider, token) })
        }
        .confirmationDialog(removing.map(SignInWords.removeTitle) ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { signIn in
            Button("Remove", role: .destructive) { Task { await remove(signIn) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(SignInWords.removeMessage)
        }
    }

    private func load() async {
        guard let control else { return }
        do {
            let list = try await control.call(DaemonAPI.Method.peopleList, DaemonAPI.Empty(), returning: DaemonAPI.PeopleList.self)
            signIns = list.people.first(where: \.isYou)?.signIns ?? []
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
        }
    }

    /// Asks for the providers and a fresh challenge, and makes the nonce from the control key
    /// this client trusts.
    private func startAdding() async {
        guard let control, let controlKey else { return }
        do {
            let providers = try await control.call(DaemonAPI.Method.signInProviders, DaemonAPI.Empty(),
                                                   returning: DaemonAPI.SignInProviders.self)
            guard !providers.turnedOn.isEmpty else {
                problem = SignInWords.noneOn
                return
            }
            guard let nonce = ControlSignIn.nonce(controlKey: controlKey, providers: providers) else {
                problem = "This control plane gave no challenge to sign in with. Update it."
                return
            }
            adding = Adding(providers: providers.turnedOn, nonce: nonce)
        } catch {
            problem = PeopleWords.refusal(error)
        }
    }

    /// Nil once added; else why not.
    private func add(_ provider: String, _ token: String) async -> String? {
        guard let control else { return "The control plane can’t be reached." }
        do {
            _ = try await control.call(DaemonAPI.Method.signInAddToMe, DaemonAPI.SignInAdd(provider: provider, token: token))
            await load()
            return nil
        } catch {
            return PeopleWords.refusal(error)
        }
    }

    private func remove(_ signIn: DaemonAPI.SignIn) async {
        guard let control, let account = signIn.account else { return }
        do {
            _ = try await control.call(DaemonAPI.Method.signInRemoveFromMe,
                                       DaemonAPI.SignInRemove(provider: signIn.provider, account: account))
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
        }
        await load()
    }
}

/// Add a Sign-in: the providers' buttons, then the control plane's answer.
private struct AddSignInSheet: View {
    let adding: SignInsSection.Adding
    let add: (_ provider: String, _ token: String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Sign-in").appText(.title)
            Text("Sign in on this device. Then sign in the same way on your other Macs, iPhones and iPads to pair them with no code.")
                .appText(.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SignInButtons(providers: adding.providers, nonce: adding.nonce, signedIn: { provider, token in
                Task {
                    isAdding = true
                    problem = await add(provider, token)
                    isAdding = false
                    if problem == nil { dismiss() }
                }
            }, failed: { problem = $0 })
            .disabled(isAdding)
            if let problem {
                Text(problem).appText(.supporting).tinted(.failure).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
            }
        }
        .padding(20)
        .frame(minWidth: 320)
    }
}
