import AgentsKitCore
import SwiftUI

/// Which of the two Status lists (#4161).
enum StatusSecretsKind: Hashable {
    case secrets, accounts

    var title: String { self == .secrets ? StatusSecretsWords.secretsTitle : StatusSecretsWords.accountsTitle }
    var help: String { self == .secrets ? StatusSecretsWords.secretsHelp : StatusSecretsWords.accountsHelp }
    var systemImage: String { self == .secrets ? "key" : "person.crop.rectangle.stack" }
}

extension UserScopeState {
    /// The person's outside accounts, from their settings.
    var accounts: [DaemonAPI.OutsideAccount] {
        (try? settings?.accounts?.decode(DaemonAPI.OutsideAccounts.self))?.accounts ?? []
    }

    /// A Status list's lines (#4161), newest operation first.
    func statusLines(_ kind: StatusSecretsKind) -> [StatusSecretsWords.Line] {
        let secrets = secrets?.secrets ?? []
        return switch kind {
        case .secrets: StatusSecretsWords.secretLines(secrets)
        case .accounts: StatusSecretsWords.accountLines(accounts, secrets: secrets)
        }
    }
}

/// The sidebar's Status ▸ Secrets and Status ▸ Accounts rows (#4161): the title, and at its end the
/// age of the newest operation on any of them. Under it, in grey, the secret or account that operation was on, the
/// operation when it is not a read, and the session that did it, when it is less than 4 hours old (#4931). The icon
/// keeps its plain tint: an operation is not a warning.
struct StatusSecretsRow: View {
    let kind: StatusSecretsKind
    let state: UserScopeState
    /// A session's title by its id, or nil when this client does not know it.
    var agentTitle: (UUID) -> String? = { _ in nil }

    var body: some View {
        let lines = state.statusLines(kind)
        let newest = StatusSecretsWords.newest(lines)
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let read = StatusSecretsWords.recentOperation(lines, now: context.date, agentTitle: agentTitle)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(kind.title).foregroundStyle(.primary)
                    Spacer()
                    if let newest {
                        Text(StatusSecretsWords.ago(newest, now: context.date))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if let read {
                    Text(read).appText(.fine).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .accessibilityValue(read.map { "\(StatusSecretsWords.lastLabel) \($0)" } ?? "")
        }
        .help(kind.help)
    }
}

/// Status ▸ Secrets and Status ▸ Accounts (#4161, specs/secret-info §9): a list you only read, newest
/// operation first: the name, the hint, the last operation in words and its age, and the warning
/// under one that is not backed up. A press on a row, and the link at the foot, open Settings ▸ You.
/// The window and the Remote draw it; the web page draws the same in `Web/src/views/StatusSecrets.tsx`.
struct StatusSecretsPage: View {
    let kind: StatusSecretsKind
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?
    let state: UserScopeState
    /// Opens the item (by its line's id) in Settings ▸ You; nil for the page itself.
    let open: (String?) -> Void

    var body: some View {
        let lines = state.statusLines(kind)
        Form {
            if let problem = state.problem {
                Section {
                    Text(problem).appText(.supporting).tinted(.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .paperListRow()
            }
            Section {
                if lines.isEmpty {
                    Text(kind == .secrets ? StatusSecretsWords.noSecrets : StatusSecretsWords.noAccounts)
                        .appText(.supporting).foregroundStyle(.secondary)
                } else {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        ForEach(lines) { line in row(line, now: context.date) }
                    }
                }
            } header: {
                Text(kind == .secrets ? StatusSecretsWords.secretsLead : StatusSecretsWords.accountsLead)
                    .appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } footer: {
                Button(kind == .secrets ? StatusSecretsWords.editSecrets : StatusSecretsWords.editAccounts) { open(nil) }
                    .buttonStyle(.borderless)
            }
            .paperListRow()
        }
        .paperForm()
        .task(id: control != nil) { await state.load(control) }
        .refreshable { await state.load(control) }
    }

    private func row(_ line: StatusSecretsWords.Line, now: Date) -> some View {
        Button { open(line.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(line.title).foregroundStyle(.primary)
                    Spacer()
                    if let at = line.at {
                        Text(StatusSecretsWords.ago(at, now: now)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Text(StatusSecretsWords.summary(line)).appText(.supporting).foregroundStyle(.secondary)
                if !line.backedUp {
                    Text(StatusSecretsWords.notBackedUp).appText(.supporting).tinted(.attention)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
