import AgentsKit
import SwiftUI

/// Continue a chat with another runtime, saying what it should be (052, US5;
/// wireframes §3). Four columns: the setting, its value now, its value on the new
/// runtime, and where that came from. What will not carry over is said plainly under
/// them.
///
/// The right-hand column is the daemon's carry plan (`agents/continueWith`, a preview),
/// made against what the runtime last offered in this folder. Each value is a menu of
/// what it offers, the mode capped at the chat's own. In adjust mode it is the runtime
/// the chat is already on, after an automatic switch, and nothing moves.
struct ContinueWithSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var request: ContinueWith
    @State private var preview: DaemonAPI.ContinueWithResult?
    @State private var choices: [String: JSONValue] = [:]
    @State private var refusal: String?
    @State private var isApplying = false
    @State private var remember = false
    /// Where Remember puts the pair: a level, or nil for a new one named below.
    @State private var rememberIn: UUID?
    @State private var newLevelName = ""

    private var agent: Agent? { model.agents.first { $0.id == request.agentID } }
    private var to: String { PoolWords.runtimeName(request.entry.runtimeID) }
    private var from: String { agent.map { PoolWords.runtimeName($0.runtimeID) } ?? "" }
    private var isBusy: Bool { agent?.state.hasTurnInFlight == true }

    /// The chat's mode now: no value picked here may ask less often (FR-027).
    private var currentMode: String? {
        guard let agent, let option = ModeMemory.modeOption(in: agent.advertisedOptions) else { return nil }
        return (agent.startOptions.values[option.id] ?? option.currentValue)?.stringValue
    }

    /// The runtimes it could continue with: the pool's first, then the rest.
    private var destinations: [PoolEntry] {
        let pooled = (model.poolStatus?.rows ?? []).map(\.entry).filter { $0.runtimeID != agent?.runtimeID }
        let names = Set(pooled.map(\.runtimeID))
        let others = model.availableRuntimes
            .filter { $0.runtime.id != agent?.runtimeID && !names.contains($0.runtime.id) }
            .map { PoolEntry(runtimeID: $0.runtime.id, payment: .allowance(label: nil)) }
        return pooled + others
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let preview, preview.options.isEmpty {
                Text("\(to) has not run in this folder yet, so what it offers is not known. It starts on its "
                     + "defaults; change them on the prompt bar once it has.")
                    .appText(.supporting).foregroundStyle(.secondary)
            } else if let preview {
                grid(preview)
            } else {
                ProgressView().controlSize(.small)
            }
            if !request.adjust { wontCarry }
            if !request.adjust { rememberRow }
            if let refusal {
                Text(refusal).appText(.supporting).foregroundStyle(StateTint.failure.style(or: .primary))
            }
            footer
        }
        .padding(24)
        .frame(width: 760)
        .task(id: request) { await load() }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(request.adjust ? "What “\(agent?.title ?? "this chat")” carried on with on \(to)"
                                    : "Continue “\(agent?.title ?? "this chat")” with")
                    .appText(.title).fontWeight(.semibold)
                if !request.adjust {
                    Menu(to) {
                        ForEach(destinations, id: \.id) { entry in
                            Button(PoolWords.runtimeName(entry.runtimeID)) {
                                request.entry = entry
                                choices = [:]
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .appText(.title)
                }
                Spacer()
                if let row = model.poolStatus?.rows.first(where: { $0.entry.id == request.entry.id }) {
                    Text(row.line(now: model.poolStatus?.at ?? .now))
                        .appText(.fine).foregroundStyle(.secondary)
                }
            }
            Text(request.adjust
                 ? "From its next turn. Nothing is started again and nothing is sent again."
                 : "\(to) starts a new conversation and is given this one so far. Nothing is sent until you write to it.")
                .appText(.supporting).foregroundStyle(.secondary)
        }
    }

    private func grid(_ preview: DaemonAPI.ContinueWithResult) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow {
                Text("SETTING")
                Text(request.adjust ? "WAS" : "NOW, ON \(from.uppercased())")
                Text("ON \(to.uppercased())")
                Text("WHERE IT CAME FROM")
            }
            .appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(preview.plan.rows, id: \.optionID) { row in
                GridRow {
                    Text(row.name).appText(.reading).fontWeight(.semibold)
                    Text(name(of: row.from, in: row.optionID)).appText(.reading)
                    valueMenu(row, options: preview.options)
                    Text(source(of: row)).appText(.fine).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The new value, as a menu of what the runtime offers, the mode capped.
    private func valueMenu(_ row: CarriedSetting, options: [ConfigOption]) -> some View {
        let option = options.first { $0.id == row.optionID }
        let isMode = option?.id == ModeMemory.modeOption(in: options)?.id
        let chosen = choices[row.optionID] ?? row.to
        let offered = (option?.options ?? []).filter { choice in
            guard isMode, let limit = currentMode, let value = choice.value.stringValue else { return true }
            return ModeLooseness.isNoLooser(value, than: limit)
        }
        return Menu(name(of: chosen, in: row.optionID)) {
            ForEach(offered) { choice in
                Button(choice.name) { choices[row.optionID] = choice.value }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .appText(.reading)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    private var wontCarry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WON'T CARRY OVER").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
            Text("“Always allow” answers you gave \(from). \(to) may ask again.")
                .appText(.supporting)
            if let extra = agent?.startOptions.extraArguments, !extra.isEmpty {
                Text("Extra arguments \(extra.joined(separator: " ")): they were for \(from) only.")
                    .appText(.supporting)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperWell(in: RoundedRectangle(cornerRadius: 8))
    }

    /// Remember: the chat's model and the one picked here go side by side in a level, so
    /// the next switch between these runtimes takes the same step (US6). The level that
    /// already holds the chat's model wins, whatever is picked here.
    private var levels: [Level] { model.poolStatus?.settings.levels ?? [] }

    private var holdingLevel: Level? {
        guard let agent, let option = SettingsCarry.model(in: agent.advertisedOptions),
              let now = agent.startOptions.values[option.id] ?? option.currentValue else { return nil }
        return levels.first { $0.cells[agent.runtimeID]?.model == now }
    }

    private var rememberRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("Remember this for next time", isOn: $remember)
                if remember, holdingLevel == nil {
                    Picker("in", selection: $rememberIn) {
                        Text("a new level").tag(UUID?.none)
                        ForEach(levels) { level in Text(level.name).tag(UUID?.some(level.id)) }
                    }
                    .fixedSize()
                    if rememberIn == nil {
                        TextField("Name", text: $newLevelName).frame(width: 140)
                    }
                }
            }
            Text(holdingLevel.map { "Goes in “\($0.name)”, which already has this chat’s model." }
                 ?? "Puts the model you pick beside this chat’s in a Matching models level.")
                .appText(.fine).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if isBusy {
                Text("Stop the turn first.").appText(.supporting).foregroundStyle(.secondary)
                Button("Stop") { Task { await model.stop(request.agentID) } }
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(request.adjust ? "Use these from the next turn" : "Continue on \(to)") {
                Task { await apply() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy || isApplying || preview == nil || (request.adjust && choices.isEmpty))
        }
    }

    // MARK: Words

    private func name(of value: JSONValue?, in optionID: String) -> String {
        let options = (preview?.options ?? []) + (agent?.advertisedOptions ?? [])
        let choice = options.first { $0.id == optionID }?.options?.first { $0.value == value }
        return choice?.name ?? value?.stringValue ?? "—"
    }

    private func source(of row: CarriedSetting) -> String {
        if choices[row.optionID] != nil { return "chosen by you" }
        return switch row.source {
        case .level(let name): "your “\(name)” level"
        case .sameValue: "the same as now"
        case .poolEntry: "the pool entry"
        case .remembered: "the last one chosen for \(to)"
        case .runtimeDefault: "\(to)’s default"
        case .strictestMode: "\(to)’s strictest"
        case .closestNoLooser: "the closest that is no looser"
        case .person: "chosen by you"
        }
    }

    // MARK: Asking the daemon

    private func load() async {
        refusal = nil
        preview = nil
        switch await model.previewContinue(request) {
        case .success(let result): preview = result
        case .failure(let error): refusal = error.message
        }
    }

    private func apply() async {
        isApplying = true
        defer { isApplying = false }
        let keep = remember ? DaemonAPI.ContinueWithRequest.Remember(levelID: rememberIn,
                                                                      newLevelName: newLevelName.isEmpty ? nil : newLevelName) : nil
        if let why = await model.applyContinue(request, choices: choices, remember: keep) {
            refusal = why
        } else {
            dismiss()
        }
    }
}
