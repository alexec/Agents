import AgentsKitCore
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Make a Bot… and Group and Cap… (#1761, spec 736 FR-030, FR-033): a bot's name (when it
/// is made), its group and its daily cap. An admin's, in Settings ▸ People.
struct BotSheet: View {
    @Environment(\.dismiss) private var dismiss
    let control: DaemonClient?
    /// The bot to change; nil makes one.
    let bot: DaemonAPI.PersonRow?
    let groups: [DaemonAPI.Group]
    let saved: () -> Void

    @State private var name = ""
    @State private var group = ""
    @State private var cap = ""
    @State private var problem: String?
    @State private var isAsking = false

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var title: String { bot.map { "\($0.name)’s Group and Cap" } ?? "Make a Bot" }
    private var ready: Bool { (bot != nil || !trimmed.isEmpty) && !group.isEmpty && !isAsking }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 16) {
            Text(title).appText(.title)
            form
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(bot == nil ? "Make Bot" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear(perform: fill)
        #else
        NavigationStack {
            form
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(bot == nil ? "Make" : "Save") { Task { await save() } }.disabled(!ready)
                    }
                }
        }
        .onAppear(perform: fill)
        #endif
    }

    private var form: some View {
        Form {
            Section {
                if bot == nil {
                    TextField("Name", text: $name, prompt: Text("review-bot"))
                }
                Picker("Group", selection: $group) {
                    if group.isEmpty { Text("Choose…").tag("") }
                    ForEach(groups) { Text($0.name).tag($0.id) }
                }
                TextField("Daily cap", text: $cap, prompt: Text("No cap, or dollars a day"))
            } footer: {
                Text(groups.isEmpty ? "Make a group first: a bot belongs to one." : BotWords.foot)
                    .appText(.fine).foregroundStyle(.secondary)
            }
            .paperListRow()
            if let problem {
                Text(problem).appText(.supporting).tinted(.failure).paperListRow()
            }
        }
        .paperForm()
    }

    private func fill() {
        // With one group, a new bot is in it.
        guard let bot else {
            if groups.count == 1 { group = groups[0].id }
            return
        }
        group = bot.group ?? ""
        if let usd = bot.caps?.dailyUSD { cap = BotWords.dollars(usd) }
    }

    private func save() async {
        guard let control else {
            problem = "The control plane can’t be reached."
            return
        }
        guard ready else { return }
        let caps: DaemonAPI.SpendCaps
        switch BotWords.readCap(cap) {
        case .none: caps = DaemonAPI.SpendCaps(dailyUSD: nil)
        case .dollars(let usd): caps = DaemonAPI.SpendCaps(dailyUSD: usd)
        case .refused(let why):
            problem = why
            return
        }
        isAsking = true
        defer { isAsking = false }
        do {
            if let bot {
                _ = try await control.call(DaemonAPI.Method.botsSetCaps, DaemonAPI.BotCaps(user: bot.id, caps: caps, group: group))
            } else {
                _ = try await control.call(DaemonAPI.Method.botsMake, DaemonAPI.BotMake(name: trimmed, group: group, caps: caps),
                                           returning: DaemonAPI.BotMade.self)
            }
            saved()
            dismiss()
        } catch {
            problem = PeopleWords.refusal(error)
        }
    }
}

/// Add a Machine… for a bot: the one line to run on the machine, which joins as the bot's.
struct BotMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    let control: DaemonClient?
    let bot: DaemonAPI.PersonRow

    @State private var shown: DaemonAPI.ControlCodeShown?
    @State private var problem: String?
    @State private var copied = false

    private var line: String? { shown.map { $0.command ?? $0.text } }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 16) {
            Text("A Machine for \(bot.name)").appText(.title)
            form
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task { await make() }
        #else
        NavigationStack {
            form
                .navigationTitle("A Machine for \(bot.name)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await make() }
        #endif
    }

    private var form: some View {
        Form {
            Section {
                if let line {
                    Text(line).appText(.code).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(copied ? "Copied" : "Copy") { copy(line) }
                } else if problem == nil {
                    Text("Making a code…").appText(.supporting).foregroundStyle(.secondary)
                }
            } footer: {
                Text(BotWords.machineFoot).appText(.fine).foregroundStyle(.secondary)
            }
            .paperListRow()
            if let problem {
                Text(problem).appText(.supporting).tinted(.failure).paperListRow()
            }
        }
        .paperForm()
    }

    private func make() async {
        guard let control else {
            problem = "The control plane can’t be reached."
            return
        }
        do {
            shown = try await control.call(DaemonAPI.Method.hostsStartEnroll, DaemonAPI.MachineEnroll(as: bot.id),
                                           returning: DaemonAPI.ControlCodeShown.self)
        } catch {
            problem = PeopleWords.refusal(error)
        }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        copied = true
    }
}
