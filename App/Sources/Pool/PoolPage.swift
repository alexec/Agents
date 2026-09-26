import AgentsKit
import SwiftUI

/// The pool of runtimes a chat carries on with, and each one's state (052, US3;
/// wireframes §1). A page like Resources, reached from the sidebar's Activity section.
///
/// Every state is in words, never only a colour. The one colour is the failure tint on
/// "out", which is what the sidebar dot means too.
struct PoolPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    private var status: PoolStatus? { model.poolStatus }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    Text("When a runtime's allowance runs out, its chats carry on with the next one here that "
                         + "isn't out. Keys join only on free or prepaid credit that cannot grow a bill.")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 16)
                    Button("Edit the pool in Settings ›") { model.settingsPaneAsked = .pool; openSettings() }
                        .buttonStyle(.link)
                        .appText(.fine)
                }
                if let status, !status.rows.isEmpty {
                    if !status.settings.isEffective { offNotice(status) }
                    if !status.waiting.isEmpty { waiting(status) }
                    runtimes(status)
                    MatchingModelsGrid(status: status)
                    switches(status)
                } else {
                    empty
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .navigationTitle("Pool")
        .task { await model.refreshPoolStatus() }
    }

    // MARK: Sections

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .appText(.fine).fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No pool yet").appText(.reading).fontWeight(.semibold)
            Text("Add the runtimes you are happy to carry on with, in the order to try, and a chat whose "
                 + "allowance runs out moves to the next one by itself.")
                .appText(.supporting).foregroundStyle(.secondary)
            Button("Set up the pool in Settings ›") { model.settingsPaneAsked = .pool; openSettings() }
                .buttonStyle(.link)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperRaised(in: RoundedRectangle(cornerRadius: 10))
    }

    private func offNotice(_ status: PoolStatus) -> some View {
        Text(status.settings.isOn
             ? "Carrying on needs two runtimes or more in the pool."
             : "Carrying on is off. Chats stop when their allowance runs out, as before.")
            .appText(.supporting)
            .foregroundStyle(.secondary)
    }

    private func waiting(_ status: PoolStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Waiting for an allowance")
            VStack(spacing: 0) {
                ForEach(status.waiting) { wait in
                    HStack {
                        Button(status.titles[wait.agentID] ?? "A chat") { model.openAgent(wait.agentID) }
                            .buttonStyle(.link)
                        Text("resumes on \(PoolWords.runtimeName(wait.runtimeID)) at \(PoolWords.time(wait.resumeAt, now: status.at))")
                            .foregroundStyle(.secondary)
                        Spacer()
                        // Asks nothing first: the chat keeps its words, and the next
                        // prompt carries on (US4).
                        Button("Stop waiting") { Task { await model.stopWaiting(wait.agentID) } }
                            .controlSize(.small)
                    }
                    .appText(.supporting)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
            }
            .paperRaised(in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func runtimes(_ status: PoolStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Runtimes, in order")
            VStack(spacing: 0) {
                ForEach(Array(status.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, 44) }
                    PoolEntryRow(position: index + 1, row: row, at: status.at)
                }
            }
            .padding(.vertical, 4)
            .paperRaised(in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func switches(_ status: PoolStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Recent switches")
            VStack(spacing: 0) {
                if status.switches.isEmpty {
                    Text("None yet.")
                        .appText(.supporting).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(Array(status.switches.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { Divider().padding(.leading, 14) }
                    SwitchRow(record: record, title: status.titles[record.agentID], at: status.at)
                }
            }
            .padding(.vertical, 4)
            .paperRaised(in: RoundedRectangle(cornerRadius: 10))
            Button("Show the last 30 days") { Task { await model.refreshPoolStatus(days: 30) } }
                .buttonStyle(.link)
                .appText(.fine)
        }
    }
}

/// One pool entry: its place, its name and how it is paid for, and its state in words.
private struct PoolEntryRow: View {
    @Environment(AppModel.self) private var model
    let position: Int
    let row: PoolStatus.Row
    let at: Date

    private var isOut: Bool { row.state.isOut }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(position)")
                .appText(.fine).foregroundStyle(.tertiary)
                .frame(width: 12, alignment: .trailing)
                .padding(.top, 2)
            Circle()
                .fill(row.unusable != nil ? AnyShapeStyle(.clear)
                      : isOut ? StateTint.failure.style(or: .primary) : StateTint.vouched.style(or: .primary))
                .overlay(Circle().stroke(.tertiary, lineWidth: row.unusable != nil ? 1 : 0))
                .frame(width: 9, height: 9)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(PoolWords.runtimeName(row.entry.runtimeID))
                        .appText(.reading).fontWeight(.semibold)
                        .foregroundStyle(row.unusable != nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    PaymentCapsule(payment: row.entry.payment, spent: row.state.spent)
                }
                HStack(spacing: 0) {
                    Text(row.line(now: at))
                        .foregroundStyle(isOut ? StateTint.failure.style(or: .primary) : AnyShapeStyle(.secondary))
                    if row.chats > 0 {
                        Text(" · \(row.chats) chat\(row.chats == 1 ? "" : "s") on it")
                            .foregroundStyle(.secondary)
                    }
                }
                .appText(.fine)
            }
            Spacer()
            if isOut {
                // Asks nothing first: a wrong mark costs one failed turn (FR-023).
                Button("Mark available") {
                    Task { await model.markPoolEntryAvailable(row.entry.id) }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// How an entry is paid for: grey for an allowance, the warning colour for anything on
/// a key, because a key is the one place money could be involved (FR-001a).
struct PaymentCapsule: View {
    let payment: Payment
    var spent: AllowanceState.Spent? = nil

    private var onAKey: Bool {
        if case .allowance = payment { return false }
        return true
    }

    var body: some View {
        Text(PoolWords.payment(payment, spent: spent))
            .appText(.fine)
            .foregroundStyle(onAKey ? StateTint.attention.style(or: .primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .paperRaised(in: Capsule())
    }
}

/// One switch: when, which chat, from which runtime to which, and why (FR-021).
private struct SwitchRow: View {
    @Environment(AppModel.self) private var model
    let record: SwitchRecord
    let title: String?
    let at: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(PoolWords.time(record.at, now: at))
                .appText(.fine).foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .leading)
            Button(title ?? "A chat") { model.openAgent(record.agentID) }
                .buttonStyle(.link)
                .fontWeight(.semibold)
            Text("\(PoolWords.runtimeName(record.from.runtimeID)) → \(PoolWords.runtimeName(record.to.runtimeID))")
            Text(PoolWords.why(record))
                .appText(.fine).foregroundStyle(.secondary)
            Spacer()
        }
        .appText(.supporting)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

/// The Pool row in the sidebar's Activity section, with its dot and count line (FR-024).
struct PoolSidebarRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Label("Pool", systemImage: "arrow.triangle.swap")
                if let line = model.poolStatus?.countLine {
                    Text(line)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 26)
                }
            }
            Spacer()
            if model.poolStatus?.anyOut == true {
                Circle()
                    .fill(StateTint.failure.style(or: .primary))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("A runtime is out")
            }
        }
        .help("The runtimes a chat carries on with, and which are out")
    }
}
