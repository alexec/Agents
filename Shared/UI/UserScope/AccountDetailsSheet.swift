#if os(macOS)
import AgentsKitCore
import AppKit
import SwiftUI

/// Opens this client's own copy of one of the person's secrets (#5112): `user/sealedSecret`,
/// which writes the audit entry first, then this client's key. The window gives one; the
/// Remote gives none, so it has no Details… (tier mac+web).
typealias SecretReveal = @MainActor (DaemonAPI.UserSealedSecretRequest) async throws -> String

/// The general pasteboard for a value a person copies (#5112, wireframes section 3). A secret
/// goes with `org.nspasteboard.ConcealedType`, so clipboard managers that obey it do not keep
/// it, and leaves after 90 s when the pasteboard still holds it. A plain field goes as text.
@MainActor
enum ConcealedClipboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    static func copy(_ value: String, secret: Bool) {
        let board = NSPasteboard.general
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        if secret { item.setString("", forType: concealed) }
        board.writeObjects([item])
        guard secret else { return }
        let count = board.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(SecretRevealWords.clipboardSeconds))
            if board.changeCount == count { board.clearContents() }
        }
    }
}

/// Settings ▸ You ▸ Accounts ▸ Details… (#5116, `specs/5112-view-copy-secrets-accounts`,
/// section 7): each field, with Copy for each plain one that has a value, and Reveal and Copy
/// for the secret and the card it names. A reveal or a copy of a value goes in the audit log;
/// a copy of a plain field does not. The web page draws the same in `Web/src/views/Accounts.tsx`.
struct AccountDetailsSheet: View {
    let account: DaemonAPI.OutsideAccount
    let rows: [DaemonAPI.UserSecretRow]
    let reveal: SecretReveal
    let edit: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// The one value shown (section 2: one at a time), by its slot, "secret" or "card".
    @State private var shown: (slot: String, value: String)?
    /// Each shown value's own count, so an old timer does not hide a newer one.
    @State private var shownCount = 0
    /// The slot or field whose value is being fetched.
    @State private var busy: String?
    /// The field or part just copied, and the line it gives.
    @State private var copied: (key: String, line: String)?
    /// Why a slot's value could not be had, by slot.
    @State private var problems: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(AccountsWords.identity(account)) { field($0) }
            } header: {
                Text(account.service)
            }
            Section {
                slot("Secret", key: "secret", AccountsWords.named(account.secret, rows: rows))
                slot("Card", key: "card", AccountsWords.named(account.card, rows: rows))
                if let expiry = AccountsWords.tokenExpiry(account) {
                    LabeledContent("Token expires") { Text(expiry) }
                }
            }
            Section {
                ForEach(AccountsWords.record(account)) { field($0) }
                SecretInfoLine(parts: AccountsWords.line(account))
            } footer: {
                if let copied { Text(copied.line).appText(.fine).foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button("Edit…") { dismiss(); edit() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .paperForm()
        .frame(minWidth: 560, minHeight: 420)
        // Hidden again when the window goes to the background, or the secret changes (section 2).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in hide() }
        .onChange(of: rows) { hide() }
    }

    private func field(_ f: AccountsWords.Field) -> some View {
        LabeledContent(f.label) {
            HStack(spacing: 8) {
                Text(f.text).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                if f.copies {
                    copyButton(key: f.label, help: "Copy \(f.label)") {
                        ConcealedClipboard.copy(f.text, secret: false)
                        flash(f.label, SecretRevealWords.copiedPlain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func slot(_ label: String, key: String, _ named: AccountsWords.Named) -> some View {
        switch named {
        case .none:
            LabeledContent(label) {
                Text(key == "secret" ? "—   " + AccountsWords.noSecretLine : "—").foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        case .elsewhere(let text):
            LabeledContent(label) {
                HStack(spacing: 8) {
                    Text("\(text) · \(AccountsWords.notInSecrets)").foregroundStyle(.secondary)
                    copyButton(key: key, help: "Copy \(label)") {
                        ConcealedClipboard.copy(text, secret: false)
                        flash(key, SecretRevealWords.copiedPlain)
                    }
                }
            }
        case .secret(let row):
            secretRows(label, key: key, row: row)
        }
    }

    @ViewBuilder
    private func secretRows(_ label: String, key: String, row: DaemonAPI.UserSecretRow) -> some View {
        let value = shown?.slot == key ? shown?.value : nil
        let card = value.flatMap { CardSecret(value: $0) }
        LabeledContent(label) {
            HStack(spacing: 8) {
                Text(row.name).appText(.code)
                if value == nil { Text(SecretInfoWords.hint(row.hint)).appText(.code).foregroundStyle(.secondary) }
                Group {
                    if busy == key + ".reveal" {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            if value == nil { Task { await show(key, row: row) } } else { hide() }
                        } label: {
                            Image(icon: value == nil ? "eye" : "eye.slash")
                        }
                        .buttonStyle(.borderless)
                        .help(value == nil ? "Reveal" : "Hide")
                        .accessibilityLabel("\(value == nil ? "Reveal" : "Hide") \(row.name)")
                    }
                }
                copyButton(key: key, help: "Copy", label: "Copy \(row.name)") {
                    Task { await copy(key, row: row, part: row.isCard ? .number : nil) }
                }
            }
        }
        if let card {
            ForEach(card.shown) { part in
                LabeledContent(part.label) {
                    HStack(spacing: 8) {
                        Text(part.text).appText(.code)
                        copyButton(key: "\(key).\(part.part.rawValue)", help: "Copy", label: "Copy \(part.label)") {
                            Task { await copy("\(key).\(part.part.rawValue)", row: row, part: part.part) }
                        }
                    }
                }
            }
        } else if let value {
            // Text a person can not select: Copy is the only way, so each copy is audited.
            Text(value).appText(.code).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if value != nil {
            Text(SecretRevealWords.shown).appText(.fine).foregroundStyle(.secondary)
        }
        if let problem = problems[key] {
            Text(problem).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyButton(key: String, help: String, label: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if busy == key {
                ProgressView().controlSize(.small)
            } else {
                Image(icon: copied?.key == key ? "checkmark" : "doc.on.doc")
            }
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(label ?? help)
    }

    private func request(_ row: DaemonAPI.UserSecretRow, _ purpose: DaemonAPI.UserSealedSecretRequest.Purpose,
                         part: DaemonAPI.UserSealedSecretRequest.Part? = nil) -> DaemonAPI.UserSealedSecretRequest {
        .init(name: row.name, purpose: purpose, part: part, account: AccountsWords.auditAccount(account))
    }

    private func show(_ key: String, row: DaemonAPI.UserSecretRow) async {
        hide()
        busy = key + ".reveal"
        do {
            let value = try await reveal(request(row, .reveal))
            busy = nil
            problems[key] = nil
            shownCount += 1
            let count = shownCount
            shown = (key, value)
            try? await Task.sleep(for: .seconds(SecretRevealWords.shownSeconds))
            if shownCount == count { hide() }
        } catch {
            busy = nil
            problems[key] = SecretRevealWords.failure(error)
        }
    }

    private func copy(_ key: String, row: DaemonAPI.UserSecretRow, part: DaemonAPI.UserSealedSecretRequest.Part?) async {
        busy = key
        defer { busy = nil }
        let slot = key.split(separator: ".").first.map(String.init) ?? key
        do {
            var value = try await reveal(request(row, .copy, part: part))
            if let part {
                guard let card = CardSecret(value: value) else {
                    problems[slot] = SecretRevealWords.notCard
                    return
                }
                value = card.part(part)
            }
            ConcealedClipboard.copy(value, secret: true)
            value = ""
            problems[slot] = nil
            flash(key, SecretRevealWords.copied)
        } catch {
            problems[slot] = SecretRevealWords.failure(error)
        }
    }

    private func flash(_ key: String, _ line: String) {
        copied = (key, line)
        Task {
            try? await Task.sleep(for: .seconds(SecretRevealWords.copiedSeconds))
            if copied?.key == key { copied = nil }
        }
    }

    /// Drops the value shown from memory.
    private func hide() {
        shown = nil
        shownCount += 1
    }
}
#endif
