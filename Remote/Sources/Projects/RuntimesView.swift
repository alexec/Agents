import AgentsKitCore
import SwiftUI

/// Each runtime on the Mac and where its allowance stands (065, US4): out, since when,
/// when it is next checked, and what is left of its plan. The Mac's Agent Runtimes
/// words, as a list. Mark available is a swipe action.
/// An account added to a runtime (#840) is its own row; Add Account is in the toolbar and
/// Remove is a swipe. Signing one in is done on the Mac.
struct RuntimesView: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        List {
            if let allowances = model.runtimeAllowances {
                ForEach(allowances.rows) { row in
                    RuntimeAllowanceRow(row: row, at: allowances.at, setBy: setBy(of: row))
                        .swipeActions {
                            if row.state.isOut {
                                Button("Mark available") { Task { await model.markRuntimeAvailable(row.credentialKey) } }
                                    .tint(.gray)
                            }
                            if let account = account(of: row) {
                                Button("Remove", role: .destructive) { removing = account }
                            }
                        }
                }
            }
            // The person's own pass-through names on the Mac, a name the policy refuses dimmed (#998).
            if !model.passThrough.names.isEmpty {
                Section("Variables passed to runtimes") {
                    ForEach(model.passThrough.names) { name in
                        VStack(alignment: .leading, spacing: 2) {
                            PassThroughRows(names: [name])
                            if let runtime = name.runtime {
                                Text(OrgPolicyWords.runtimeName(runtime)).appText(.fine).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !model.accountProfiles.isEmpty {
                Section {} footer: {
                    Text("Sign in to an added account on the Mac, in its runtime’s sign-in sheet.")
                }
            }
        }
        .toolbar {
            if !accountRuntimes.isEmpty {
                Menu {
                    ForEach(accountRuntimes) { status in
                        Button(status.runtime.name) {
                            newName = ""
                            addingTo = status.runtime
                        }
                    }
                } label: {
                    Label("Add Account", systemImage: "person.badge.plus")
                }
            }
        }
        .alert("Add a \(addingTo?.name ?? "") account", isPresented: Binding(get: { addingTo != nil },
                                                                           set: { if !$0 { addingTo = nil } })) {
            TextField("Name, such as Work", text: $newName)
            Button("Add") {
                guard let runtime = addingTo else { return }
                Task { addProblem = await model.addAccount(runtimeID: runtime.id, name: newName) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You choose it when you start a session. Sign it in on the Mac.")
        }
        .confirmationDialog("Remove \(removing?.name ?? "this account")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let account = removing else { return }
                Task { await model.removeAccount(account) }
            }
        } message: {
            Text("Its sessions stop, and its sign-in is deleted from the Mac.")
        }
        .navigationTitle("Runtimes")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
        .markedStale(model.isStale)
        .overlay {
            if model.runtimeAllowances?.rows.isEmpty != false {
                Text("No runtimes on the Mac yet.").foregroundStyle(.secondary)
            }
        }
        .task {
            await model.refreshRuntimeAllowances()
            await model.refreshPassThrough()
        }
        .refreshable {
            await model.refreshRuntimeAllowances()
            await model.refreshPassThrough()
        }
        .alert("Not added", isPresented: Binding(get: { addProblem != nil }, set: { if !$0 { addProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addProblem ?? "")
        }
    }

    @State private var addingTo: Runtime?
    @State private var newName = ""
    @State private var removing: AccountProfile?
    @State private var addProblem: String?

    /// The Mac's runtimes that keep their sign-in in a folder, so take more than one account.
    private var accountRuntimes: [RuntimeStatus] {
        model.runtimes.filter { $0.runtime.accountFolderVariable != nil }
    }

    /// The organisation's mark when its policy does not allow the row's runtime (#998).
    private func setBy(of row: RuntimeAllowances.Row) -> DaemonAPI.PolicySetBy? {
        let runtimeID = row.credentialKey.split(separator: ":").first.map(String.init)
        return model.runtimes.first { $0.id == runtimeID }?.setBy
    }

    private func account(of row: RuntimeAllowances.Row) -> AccountProfile? {
        row.accountID.flatMap { id in model.accountProfiles.first { $0.id == id } }
    }
}

private struct RuntimeAllowanceRow: View {
    let row: RuntimeAllowances.Row
    let at: Date
    var setBy: DaemonAPI.PolicySetBy?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.title).fontWeight(.semibold)
                .foregroundStyle(setBy == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            if let setBy { OrgPolicyLine(mark: setBy) }
            Text(row.unusable.map { "Not usable: \($0)" } ?? row.line(now: at))
                .appText(.fine)
                .foregroundStyle(row.state.isOut ? StateTint.failure.style(or: .primary) : AnyShapeStyle(.secondary))
            if row.unusable == nil, let reading = PoolWords.reading(row.state.reading, now: at) {
                Text(reading).appText(.fine).foregroundStyle(.secondary)
                if let current = row.state.reading { AllowanceBar(reading: current) }
            }
            if let note = row.setupNote {
                Text(LocalizedStringKey(note)).appText(.fine).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The link to it at the foot of Spending, with the Mac's red dot when a runtime is out.
struct RuntimesLink: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        NavigationLink { RuntimesView() } label: {
            HStack {
                Label("Runtimes", systemImage: "cpu")
                Spacer()
                if model.runtimeAllowances?.anyOut == true {
                    Circle().fill(StateTint.failure.style(or: .primary)).frame(width: 8, height: 8)
                        .accessibilityLabel("A runtime is out")
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
