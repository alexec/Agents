import AgentsKitCore
import SwiftUI

/// Control plane ▸ Sign-ins (#995, spec 736 FR-005; a pane of its own on the Mac too, #2197): how this person signs in, with Add a
/// Sign-in… (Apple, Google or GitHub, on this device) and Remove for an outside one. A
/// sign-in added here pairs this person's other Macs, iPhones and iPads with no code.
///
/// A section, for the Mac's Sign-ins pane and the Remote's Sign-ins page (the web page lists
/// them in `Web/src/views/SignInSection.tsx`, and cannot add one: a browser pairs by code).
struct SignInsSection: View {
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?
    /// The control key this client trusts, which the nonce is bound to; nil when not paired.
    let controlKey: Data?
    /// The people this client keeps, loaded once per change (#2055): this person's sign-ins.
    let people: PeopleState

    @State private var problem: String?
    @State private var adding: Adding?
    @State private var removing: DaemonAPI.SignIn?

    /// The providers on, and the nonce for this one sign-in.
    struct Adding: Identifiable {
        var providers: DaemonAPI.SignInProviders
        var nonce: String
        var ask: ControlSignIn.Asking
        var id: String { nonce }
    }

    private var signIns: [DaemonAPI.SignIn]? { people.list?.people.first(where: \.isYou)?.signIns }

    var body: some View {
        Section {
            if let problem = problem ?? people.listProblem {
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
        .task(id: control != nil) { await load() }
        .sheet(item: $adding) { adding in
            AddSignInSheet(adding: adding, add: { answer in await add(answer) })
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
        guard let control, people.list == nil else { return }
        await people.loadList(control)
    }

    /// Asks for the providers and a fresh challenge, and makes the nonce from the control key
    /// this client trusts.
    private func startAdding() async {
        guard let control, let controlKey else { return }
        do {
            let providers = try await control.call(DaemonAPI.Method.signInProviders, DaemonAPI.Empty(),
                                                   returning: DaemonAPI.SignInProviders.self)
            guard providers.anyOn else {
                problem = SignInWords.noneOn
                return
            }
            guard let nonce = ControlSignIn.nonce(controlKey: controlKey, providers: providers) else {
                problem = "This control plane gave no challenge to sign in with. Update it."
                return
            }
            // An org provider's flow on this connection, as purpose addToMe (#1002).
            let ask = ControlSignIn.Asking(orgStart: { provider, hint in
                let started = try await control.call(DaemonAPI.Method.signInOrgStart,
                                                     DaemonAPI.SignInOrgStart(provider: provider, purpose: .addToMe, loginHint: hint),
                                                     returning: DaemonAPI.SignInOrgStarted.self)
                guard let address = URL(string: started.url) else { throw ControlSignIn.Failure("The control plane gave no address.") }
                return address
            }, discover: { email in
                try await control.call(DaemonAPI.Method.signInDiscover, DaemonAPI.SignInDiscover(email: email),
                                       returning: DaemonAPI.SignInDiscovered.self)
            })
            adding = Adding(providers: providers.forScreen, nonce: nonce, ask: ask)
        } catch {
            problem = PeopleWords.refusal(error)
        }
    }

    /// Nil once added; else why not.
    private func add(_ answer: ControlSignIn.Answer) async -> String? {
        guard let control else { return "The control plane can’t be reached." }
        do {
            // Told as control/peopleChanged: the list loads then.
            switch answer {
            case .token(let provider, let token):
                _ = try await control.call(DaemonAPI.Method.signInAddToMe, DaemonAPI.SignInAdd(provider: provider, token: token))
            case .ticket(let ticket):
                _ = try await control.call(DaemonAPI.Method.signInTicket, DaemonAPI.SignInTicket(ticket: ticket))
            }
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
    }
}

/// Add a Sign-in: the providers' buttons, then the control plane's answer.
private struct AddSignInSheet: View {
    let adding: SignInsSection.Adding
    let add: (ControlSignIn.Answer) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?
    @State private var isAdding = false

    private static let title = "Add a Sign-in"

    var body: some View {
        #if os(iOS)
        // An iOS sheet (#2081): the title in the bar and Cancel where iOS puts it.
        NavigationStack {
            Form {
                Section { content }
                    .paperListRow()
            }
            .paperForm()
            .navigationTitle(Self.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
        #else
        VStack(alignment: .leading, spacing: 14) {
            Text(Self.title).appText(.title)
            content
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
            }
        }
        .padding(20)
        .frame(minWidth: 320)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        Text("Sign in on this device. Then sign in the same way on your other Macs, iPhones and iPads to pair them with no code.")
            .appText(.supporting).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        SignInButtons(providers: adding.providers, nonce: adding.nonce, asking: adding.ask, answered: { answer in
            Task {
                isAdding = true
                problem = await add(answer)
                isAdding = false
                if problem == nil { dismiss() }
            }
        }, failed: { problem = $0 })
        .disabled(isAdding)
        if let problem {
            Text(problem).appText(.supporting).tinted(.failure).fixedSize(horizontal: false, vertical: true)
        }
    }
}
