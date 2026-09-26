import AgentsKit
import SwiftUI

/// One runtime's credential for servers, in Settings ▸ Servers (043, contracts/ui.md § 1).
///
/// Empty: a field to paste into, and where to get one. Saved: the mask, when it was added
/// and last worked, and Replace and Remove. The text is never shown again once saved.
struct CredentialRow: View {
    @Environment(AppModel.self) private var model
    let runtimeID: String
    let name: String
    @State private var text = ""
    @State private var isReplacing = false
    @State private var notACredential = false

    private var credentials: ServerCredentials { model.credentials }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let record = credentials.record(runtimeID), !isReplacing {
                saved(record)
            } else {
                entry
            }
        }
        .padding(.vertical, 4)
    }

    private func saved(_ record: CredentialStore.Record) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(tint(record).style(or: .secondary)).frame(width: 8, height: 8)
                Text(name).fontWeight(.semibold)
                Text(status(record)).appText(.fine).foregroundStyle(.secondary)
                Spacer()
                Text(record.mask).appText(.code).foregroundStyle(.secondary)
            }
            Text(dates(record)).appText(.fine).foregroundStyle(.secondary)
            if case .answered(.refused(let why)) = credentials.checking[runtimeID] {
                Text("\(name) refused this token: \(why)").appText(.fine).tinted(.failure)
            }
            HStack {
                Spacer()
                if credentials.checking[runtimeID] == .checking {
                    ProgressView().controlSize(.small)
                }
                Button("Check again") { Task { await credentials.check(runtimeID) } }
                    .disabled(credentials.checking[runtimeID] == .checking)
                Button("Replace…") { isReplacing = true }
                Button("Remove", role: .destructive) { credentials.remove(runtimeID) }
            }
            .controlSize(.small)
        }
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(name).fontWeight(.semibold)
                // Replacing keeps the old one until the new one is saved: say which.
                if isReplacing, let record = credentials.record(runtimeID) {
                    Text("Replacing \(record.mask)").appText(.fine).foregroundStyle(.secondary)
                } else {
                    Text("No token").appText(.fine).foregroundStyle(.secondary)
                }
            }
            HStack {
                SecureField("Paste a \(name) token", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                if isReplacing {
                    Button("Cancel") { isReplacing = false; text = "" }
                }
                Button("Save", action: save).disabled(text.isEmpty)
            }
            if notACredential {
                Text("That isn’t a Claude token or API key. They start sk-ant-oat or sk-ant-api.")
                    .appText(.fine).tinted(.failure)
            }
            Text("Make one with `claude setup-token` on this Mac, or use an API key from console.anthropic.com.")
                .appText(.fine).foregroundStyle(.secondary)
        }
    }

    private func save() {
        let pasted = text
        Task {
            if await credentials.save(pasted, for: runtimeID) {
                text = ""
                notACredential = false
                isReplacing = false
            } else {
                notACredential = true
            }
        }
    }

    private func tint(_ record: CredentialStore.Record) -> StateTint {
        switch credentials.checking[runtimeID] {
        case .answered(.works): return .vouched
        case .answered(.refused): return .failure
        case .checking: return .none
        default: break
        }
        if let refused = record.lastRefused, refused > (record.lastWorked ?? .distantPast) { return .failure }
        return record.lastWorked == nil ? .none : .vouched
    }

    private func status(_ record: CredentialStore.Record) -> String {
        switch credentials.checking[runtimeID] {
        case .checking: return "Checking…"
        case .answered(.works): return "Works"
        case .answered(.refused): return "Refused"
        case .answered(.cannotCheck): return "Can’t check right now — saved, and it will be tried on the next server agent"
        default: break
        }
        if let refused = record.lastRefused, refused > (record.lastWorked ?? .distantPast) { return "Refused" }
        return record.lastWorked == nil ? "Not checked yet" : "Works"
    }

    private func dates(_ record: CredentialStore.Record) -> String {
        var parts = ["\(record.kind.display) · added \(record.addedAt.formatted(date: .abbreviated, time: .omitted))"]
        if let worked = record.lastWorked {
            parts.append("last worked \(worked.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}
