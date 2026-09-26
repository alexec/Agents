import AgentsKit
import SwiftUI

/// Add credit on an API key to the pool (052, US2; wireframes §4a).
///
/// Only a key whose spending stops by itself can be picked. "Billed with no limit" is
/// shown, disabled, with its reason, so it is plainly refused on purpose rather than
/// forgotten (FR-001a). The app cannot see a provider's billing settings, so the sheet
/// takes the person's word for it and says so.
struct AddCreditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let add: (PoolEntry) -> Void

    enum Kind: Hashable { case freeTier, freeCredit, prepaid }

    @State private var runtimeID = "codex"
    @State private var kind: Kind?
    @State private var amount = ""
    @State private var hasExpiry = false
    @State private var expires = Date.now.addingTimeInterval(30 * 86400)

    /// The runtimes a key can be lent to, with the kind of key each takes.
    private static let keyed: [(runtimeID: String, kind: CredentialKind)] = [
        ("codex", .openAIAPIKey), ("gemini", .geminiAPIKey), ("claude", .apiKey),
    ]

    private var credential: CredentialKind? { Self.keyed.first { $0.runtimeID == runtimeID }?.kind }

    /// The key saved for this runtime, when it is the kind the pool can use. A Claude
    /// sign-in token is not a key billed by use, so it is not one of these.
    private var saved: CredentialStore.Record? {
        guard let record = model.credentials.record(runtimeID), record.kind == credential else { return nil }
        return record
    }

    private var payment: Payment? {
        let cost = Decimal(string: amount.trimmingCharacters(in: .whitespaces)).map { Cost(amount: $0, currency: "USD") }
        return switch kind {
        case .freeTier?: .freeTier(reset: runtimeID == "gemini" ? .gemini : .unknown)
        case .freeCredit?: .freeCredit(amount: cost, expires: hasExpiry ? expires : nil)
        case .prepaid?: .prepaid(amount: cost, expires: hasExpiry ? expires : nil)
        case nil: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add credit on an API key").appText(.title).fontWeight(.semibold)
            Text("A key joins the pool only if its spending stops by itself when the credit is gone.")
                .appText(.supporting).foregroundStyle(.secondary)

            Picker("Runtime", selection: $runtimeID) {
                ForEach(Self.keyed, id: \.runtimeID) { Text(PoolWords.runtimeName($0.runtimeID)).tag($0.runtimeID) }
            }
            // A Gemini key with no billing account is the free tier, which is most of them.
            .onChange(of: runtimeID, initial: true) { _, id in
                if id == RuntimeCatalog.gemini.id, kind == nil { kind = .freeTier }
            }
            if let saved {
                Text("Uses the \(PoolWords.runtimeName(runtimeID)) \(CredentialKind.noun(for: runtimeID)) \(saved.mask), from Settings ▸ Agents.")
                    .appText(.fine).foregroundStyle(.secondary)
            } else {
                Text("No \(PoolWords.runtimeName(runtimeID)) \(CredentialKind.noun(for: runtimeID)) is saved. Add one in Settings ▸ Agents first.")
                    .appText(.fine).foregroundStyle(StateTint.attention.style(or: .primary))
            }

            Text("WHAT KIND OF CREDIT IS IT?").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                choice(.freeTier, "Free tier, no billing on the key",
                       "The provider's free quota, back on its own schedule. Gemini: resets daily at midnight Pacific.")
                choice(.freeCredit, "Free credit", "A trial or promotional grant. It ends when it is spent or expires.")
                choice(.prepaid, "Prepaid, with auto-recharge off",
                       "You topped it up once, and it will not refill itself. Check this with the provider: the app cannot.")
                VStack(alignment: .leading, spacing: 2) {
                    Label("Billed with no limit", systemImage: "circle").foregroundStyle(.tertiary)
                    Text("Auto-recharge on, or invoiced. The pool never carries a chat onto this.")
                        .appText(.fine).foregroundStyle(.tertiary).padding(.leading, 26)
                }
            }

            if kind == .freeCredit || kind == .prepaid {
                Divider()
                HStack {
                    Text("Amount").frame(width: 80, alignment: .leading)
                    TextField("$10.00", text: $amount).frame(width: 120)
                    Text("Optional. The app stops at this even if the provider has not said no.")
                        .appText(.fine).foregroundStyle(.secondary)
                }
                HStack {
                    Toggle("Expires", isOn: $hasExpiry).frame(width: 80, alignment: .leading)
                    if hasExpiry { DatePicker("", selection: $expires, displayedComponents: .date).labelsHidden() }
                    Text("Optional. Free grants usually have one.").appText(.fine).foregroundStyle(.secondary)
                }
            }

            Text("It goes last in the pool, after every allowance. Drag it higher in Settings ▸ Pool if you want it sooner.")
                .appText(.fine).foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .paperWell(in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let payment {
                        add(PoolEntry(runtimeID: runtimeID, payment: payment, credentialRef: credential?.rawValue))
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(payment == nil || saved == nil)
            }
        }
        .padding(24)
        .frame(width: 620)
    }

    private func choice(_ value: Kind, _ title: String, _ detail: String) -> some View {
        Button { kind = value } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: kind == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(.primary)
                Text(detail).appText(.fine).foregroundStyle(.secondary).padding(.leading, 26)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
