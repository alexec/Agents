import AgentsKitCore
import SwiftUI

/// Every runtime on this Mac and where its allowance stands (065, US4).
///
/// A page like Resources, reached from the foot of the sidebar. It was in Settings ▸
/// Agent Runtimes, which is where a control belongs; what it says is the state of the
/// machine, and it changes without anybody touching a setting. Settings keeps what
/// changes the Mac: installing a runtime, its permission mode.
///
/// Every runtime the app knows is here, installed or not, so the page answers "what can
/// I start on" in one place. A runtime with no allowance of its own says so rather than
/// being left out, and one that is not on the Mac says what stopped it. **Mark available**
/// asks nothing first: a wrong mark costs one refused turn (FR-023).
///
/// The accounts of a runtime are here too (#2255), as the Remote and the web page send a person
/// here to sign one in: **Add Account…** on the runtime's row, **Sign In…** (the runtime's
/// sign-in sheet, which has the Accounts section) and **Remove…** on an account's row.
struct RuntimesView: View {
    @Environment(AppModel.self) private var model

    /// The runtime whose sign-in sheet is open.
    @State private var signingIn: String?
    @State private var addingTo: Runtime?
    @State private var newName = ""
    @State private var addProblem: String?
    @State private var removing: AccountProfile?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("What each runtime can be started on right now. An allowance that is "
                     + "spent is not a fault: a chat on it still takes a message, and the "
                     + "runtime says no until its plan comes back.")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(Array(runtimes.enumerated()), id: \.element.id) { index, status in
                        if index > 0 { Divider().padding(.leading, 14) }
                        RuntimeStatusRow(status: status,
                                         allowance: allowance(for: status.id),
                                         at: model.runtimeAllowances?.at ?? Date()) {
                            if case .needsSignIn = status.availability {
                                Button("Sign In…") { signingIn = status.id }
                                    .controlSize(.small)
                            }
                            if status.runtime.accountFolderVariable != nil, !status.availability.isMissing {
                                Button("Add Account…") {
                                    newName = ""
                                    addingTo = status.runtime
                                }
                                .controlSize(.small)
                            }
                        }
                        // Each account added to it (#840), then the organisation's (#999), under
                        // it, with its own allowance. Only one the person added can be signed in
                        // or removed here; the organisation's is the organisation's.
                        ForEach(accountRows(for: status.id)) { row in
                            Divider().padding(.leading, 14)
                            RuntimeStatusRow(status: status, allowance: row, at: model.runtimeAllowances?.at ?? Date(),
                                             title: row.title) {
                                if let account = account(of: row) {
                                    if !account.signedIn {
                                        Button("Sign In…") { signingIn = status.id }
                                            .controlSize(.small)
                                    }
                                    Button("Remove…") { removing = account }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .paperRaised(in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Runtimes")
        .overlay {
            if runtimes.isEmpty {
                Text("No runtimes known yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await model.refreshRuntimes()
            await model.refreshRuntimeAllowances()
            await model.refreshAccountProfiles()
        }
        .sheet(isPresented: Binding(get: { signingIn != nil }, set: { if !$0 { signingIn = nil } })) {
            if let signingIn {
                RuntimeAccountView(runtimeID: signingIn)
                    .paperSheet()
            }
        }
        .alert("Add a \(addingTo?.name ?? "") account", isPresented: Binding(get: { addingTo != nil },
                                                                           set: { if !$0 { addingTo = nil } })) {
            TextField("Name, such as Work", text: $newName)
            Button("Add") {
                guard let runtime = addingTo else { return }
                let name = newName.trimmingCharacters(in: .whitespaces)
                Task { addProblem = await model.addAccount(runtimeID: runtime.id, name: name) }
            }
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You choose it when you start a session. Then sign it in here.")
        }
        .alert("Not added", isPresented: Binding(get: { addProblem != nil }, set: { if !$0 { addProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addProblem ?? "")
        }
        .confirmationDialog("Remove \(removing?.name ?? "this account")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                guard let account = removing else { return }
                Task { await model.removeAccount(account) }
            }
        } message: {
            Text(AccountWords.removeMessage(stopping: removing.map(model.agentsHolding(account:))?.count ?? 0,
                                            from: "this Mac"))
        }
    }

    /// The account a row is for, when the person may sign it in or remove it: not an org account.
    private func account(of row: RuntimeAllowances.Row) -> AccountProfile? {
        row.accountID.flatMap { id in model.accountProfiles.first { $0.id == id && !$0.isOrganisation } }
    }

    /// Every runtime the app knows, in its own order. The daemon sends the whole list
    /// whether or not a runtime is on this Mac, so a missing one is here to be read
    /// rather than guessed at from the absence of a row.
    private var runtimes: [RuntimeStatus] { model.runtimes }

    /// The allowance row for a runtime, which is per credential: a runtime with a key of
    /// its own has more than one. The first is the runtime's own sign-in, which is the
    /// one a new agent would use.
    private func allowance(for runtimeID: String) -> RuntimeAllowances.Row? {
        model.runtimeAllowances?.row(runtimeID, account: nil)
    }

    private func accountRows(for runtimeID: String) -> [RuntimeAllowances.Row] {
        model.runtimeAllowances?.rows.filter { $0.runtimeID == runtimeID && $0.accountID != nil } ?? []
    }
}

/// One runtime: its name, what is true of it, **Mark available** when it is out, and the
/// row's own buttons.
private struct RuntimeStatusRow<Actions: View>: View {
    @Environment(AppModel.self) private var model
    let status: RuntimeStatus
    let allowance: RuntimeAllowances.Row?
    let at: Date
    /// An added account's row is named for it too: "Claude · Work".
    var title: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title ?? status.runtime.name)
                    .fontWeight(.semibold)
                // An org account says where it is from (spec FR-023), never a key or an address.
                if allowance?.isOrganisation == true {
                    Text(OrgAccountWords.fromOrganisation)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                Text(line)
                    .appText(.fine)
                    .foregroundStyle(isOut ? StateTint.failure.style(or: .primary) : AnyShapeStyle(.secondary))
                if let reading, allowance?.unusable == nil {
                    Text(reading)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                    if let current = allowance?.state.reading {
                        AllowanceBar(reading: current)
                    }
                }
                if let note = allowance?.setupNote {
                    Text(LocalizedStringKey(note))
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isOut, let allowance {
                Button("Mark available") {
                    Task { await model.markRuntimeAvailable(allowance.credentialKey) }
                }
                .controlSize(.small)
            }
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// The allowance's own words where it has one, and the runtime's otherwise. What is
    /// not on this Mac is not an allowance state, so it is said in the runtime's terms.
    /// The install row keeps the size of a download and the buttons; this says what is.
    private var line: String {
        // A runtime the daemon found but nothing can start is that, whatever its plan
        // says. "Available" on a binary that is not here would be true of nothing.
        if let unusable = allowance?.unusable { return "Not usable: \(unusable)" }
        if let allowance { return allowance.memberLine(now: at) }
        switch status.availability {
        case .available: return "Available · no plan of its own"
        case .missing: return "Not on this Mac"
        case .needsSignIn, .failed: return status.unavailableReason ?? "Can’t be used"
        case .installing(let progress): return progress.map { "\($0)…" } ?? "Starting…"
        case .installFailed(let reason): return reason
        }
    }

    private var reading: String? {
        PoolWords.reading(allowance?.state.reading, now: at)
    }

    /// Out, and usable enough to say so. A runtime that cannot be started at all is a
    /// different thing, and marking it available would only hide that.
    private var isOut: Bool { allowance?.state.isOut == true && allowance?.unusable == nil }
}

/// The foot of the sidebar's way into Runtimes (065). It says how many runtimes on this
/// Mac can start a turn, out of how many are installed (#379), and a red dot only when
/// none can: one being out does not matter, the work goes on on the others.
struct RuntimesRow: View {
    @Environment(AppModel.self) private var model

    private var tally: RuntimeTally? {
        RuntimeTally(model.runtimes, allowances: model.runtimeAllowances)
    }

    var body: some View {
        // The title alone (#587): how many work is the tooltip's, and none working turns
        // the row's icon red (`activityIcon(_:warns:)`).
        HStack(alignment: .firstTextBaseline) {
            Text("Runtimes").foregroundStyle(.primary)
            Spacer()
        }
        .help(tally.map { "\($0.working) of \($0.total) working. What each runtime can be started on right now, and where its allowance stands" }
              ?? "What each runtime can be started on right now, and where its allowance stands")
        .accessibilityValue(tally.map { $0.noneWorking ? "None of \($0.total) working" : "\($0.working) of \($0.total) working" } ?? "")
    }
}
