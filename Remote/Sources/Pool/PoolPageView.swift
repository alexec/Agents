import AgentsKitCore
import SwiftUI

/// The Pool page on the phone (052; wireframes §5): the Mac's page as grouped lists.
/// Mark available and Stop waiting are swipe actions; a level opens to one line per
/// runtime, since the Mac's grid does not fit. Every line is `PoolWords`, as on the Mac.
struct PoolPageView: View {
    @Environment(RemoteModel.self) private var model

    private var status: PoolStatus? { model.poolStatus }

    var body: some View {
        List {
            if let status, !status.rows.isEmpty {
                if !status.settings.isEffective {
                    Section {
                        Text(status.settings.isOn
                             ? "Carrying on needs two runtimes or more in the pool."
                             : "Carrying on is off. Chats stop when their allowance runs out, as before.")
                            .foregroundStyle(.secondary)
                    }
                }
                if !status.waiting.isEmpty {
                    Section("Waiting for an allowance") {
                        ForEach(status.waiting) { wait in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(status.titles[wait.agentID] ?? "A chat")
                                Text("resumes on \(PoolWords.runtimeName(wait.runtimeID)) at \(PoolWords.time(wait.resumeAt, now: status.at))")
                                    .appText(.fine).foregroundStyle(.secondary)
                            }
                            .swipeActions {
                                Button("Stop waiting") { Task { await model.stopWaiting(wait.agentID) } }
                            }
                        }
                    }
                }
                Section("Runtimes, in order") {
                    ForEach(status.rows) { row in
                        RuntimeRow(row: row, at: status.at)
                            .swipeActions {
                                if row.state.isOut {
                                    Button("Mark available") { Task { await model.markPoolEntryAvailable(row.entry.id) } }
                                        .tint(.gray)
                                }
                            }
                    }
                }
                Section("Matching models") {
                    if status.settings.levels.isEmpty {
                        Text("No levels yet. They are made on the Mac, or by Remember when a chat continues.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(status.settings.levels) { level in
                        NavigationLink(level.name) { LevelDetailView(level: level, status: status) }
                    }
                }
                Section("Recent switches") {
                    if status.switches.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                    ForEach(status.switches) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(PoolWords.runtimeName(record.from.runtimeID)) → \(PoolWords.runtimeName(record.to.runtimeID))")
                            Text("\(PoolWords.time(record.at, now: status.at)) · \(status.titles[record.agentID] ?? "A chat") · \(PoolWords.why(record))")
                                .appText(.fine).foregroundStyle(.secondary)
                        }
                    }
                    Button("Show the last 30 days") { Task { await model.refreshPoolStatus(days: 30) } }
                }
            } else {
                Section {
                    Text("No pool yet. It is set up on the Mac, in Settings ▸ Pool.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Pool")
        .task { await model.refreshPoolStatus() }
        .refreshable { await model.refreshPoolStatus() }
    }
}

/// One runtime: its name, how it is paid for under it, and its state in words.
private struct RuntimeRow: View {
    let row: PoolStatus.Row
    let at: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(PoolWords.runtimeName(row.entry.runtimeID)).fontWeight(.semibold)
            Text(PoolWords.payment(row.entry.payment, spent: row.state.spent))
                .appText(.fine).foregroundStyle(.secondary)
            Text(row.line(now: at) + (row.chats > 0 ? " · \(row.chats) chat\(row.chats == 1 ? "" : "s") on it" : ""))
                .appText(.fine)
                .foregroundStyle(row.state.isOut ? StateTint.failure.style(or: .primary) : AnyShapeStyle(.secondary))
        }
        .accessibilityElement(children: .combine)
    }
}

/// One level, opened: a line per runtime in the pool, with its model.
struct LevelDetailView: View {
    let level: Level
    let status: PoolStatus

    private var columns: [String] {
        var seen = Set<String>()
        return status.rows.map(\.entry.runtimeID).filter { seen.insert($0).inserted }
    }

    var body: some View {
        List(columns, id: \.self) { runtimeID in
            LabeledContent(PoolWords.runtimeName(runtimeID)) {
                if let cell = level.cells[runtimeID] {
                    Text([cell.model.stringValue, cell.effort?.stringValue].compactMap { $0 }.joined(separator: " · "))
                } else {
                    Text("None").foregroundStyle(.tertiary)
                }
            }
        }
        .navigationTitle(level.name)
    }
}

/// The Pool row under Spending, with the Mac's icon, dot and count line (FR-024).
struct PoolRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Label("Pool", systemImage: "arrow.triangle.swap")
                if let line = model.poolStatus?.countLine {
                    Text(line)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 36)
                }
            }
            Spacer()
            if model.poolStatus?.anyOut == true {
                Circle().fill(StateTint.failure.style(or: .primary)).frame(width: 8, height: 8)
                    .accessibilityLabel("A runtime is out")
            }
        }
        .accessibilityHint("Opens the Pool")
    }
}

/// A chat the person is moving by hand on the phone, or whose switch they are changing.
struct RemoteContinue: Identifiable, Hashable {
    let agentID: UUID
    var runtimeID: String
    var entryID: UUID?
    var adjust = false
    var id: String { "\(agentID)-\(runtimeID)-\(adjust)" }
}

/// Continue with on the phone (wireframes §5): the Mac's sheet as a list, one row per
/// setting, the new value with the old under it. Each value is a menu of what the
/// runtime offers, modes capped at the chat's own.
struct ContinueWithList: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: RemoteContinue
    @State private var preview: DaemonAPI.ContinueWithResult?
    @State private var choices: [String: JSONValue] = [:]
    @State private var refusal: String?

    private var agent: Agent? { model.agent(request.agentID) }
    private var to: String { PoolWords.runtimeName(request.runtimeID) }

    private var currentMode: String? {
        guard let agent, let option = ModeMemory.modeOption(in: agent.advertisedOptions) else { return nil }
        return (agent.startOptions.values[option.id] ?? option.currentValue)?.stringValue
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(request.adjust ? "From its next turn. Nothing is started again and nothing is sent again."
                                        : "\(to) starts a new conversation and is given this one so far. Nothing is sent until you write to it.")
                        .foregroundStyle(.secondary)
                }
                if let preview, preview.options.isEmpty {
                    Text("\(to) has not run in this folder yet, so it starts on its defaults.")
                        .foregroundStyle(.secondary)
                } else if let preview {
                    Section("Settings") {
                        ForEach(preview.plan.rows, id: \.optionID) { row in setting(row, options: preview.options) }
                    }
                }
                if let refusal {
                    Text(refusal).foregroundStyle(StateTint.failure.style(or: .primary))
                }
            }
            .navigationTitle(request.adjust ? "On \(to)" : "Continue with \(to)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.adjust ? "Use" : "Continue") { Task { await apply() } }
                        .disabled(preview == nil || agent?.state.hasTurnInFlight == true || (request.adjust && choices.isEmpty))
                }
            }
            .task { await load() }
        }
    }

    private func setting(_ row: CarriedSetting, options: [ConfigOption]) -> some View {
        let option = options.first { $0.id == row.optionID }
        let isMode = option?.id == ModeMemory.modeOption(in: options)?.id
        let offered = (option?.options ?? []).filter { choice in
            guard isMode, let limit = currentMode, let value = choice.value.stringValue else { return true }
            return ModeLooseness.isNoLooser(value, than: limit)
        }
        let chosen = choices[row.optionID] ?? row.to
        return Menu {
            ForEach(offered) { choice in Button(choice.name) { choices[row.optionID] = choice.value } }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).appText(.fine).foregroundStyle(.secondary)
                Text(name(chosen, options: options, id: row.optionID))
                Text("was \(name(row.from, options: (agent?.advertisedOptions ?? []), id: row.optionID))")
                    .appText(.fine).foregroundStyle(.tertiary)
            }
        }
    }

    private func name(_ value: JSONValue?, options: [ConfigOption], id: String) -> String {
        options.first { $0.id == id }?.options?.first { $0.value == value }?.name ?? value?.stringValue ?? "—"
    }

    private func call(confirmed: Bool) -> DaemonAPI.ContinueWithRequest {
        DaemonAPI.ContinueWithRequest(agentID: request.agentID, entryID: request.adjust ? nil : request.entryID,
                                      runtimeID: request.adjust ? nil : request.runtimeID, adjust: request.adjust,
                                      choices: choices, confirmed: confirmed)
    }

    private func load() async {
        switch await model.continueWith(call(confirmed: false)) {
        case .success(let result): preview = result
        case .failure(let error): refusal = error.message
        }
    }

    private func apply() async {
        switch await model.continueWith(call(confirmed: true)) {
        case .success: dismiss()
        case .failure(let error): refusal = error.message
        }
    }
}
