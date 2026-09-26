import AgentsKit
import SwiftUI

/// Continue a chat with another runtime, saying what it should be (052, US5;
/// wireframes §3). Four columns: the setting, its value now, its value on the new
/// runtime, and where that came from. What will not carry over is said plainly under
/// them.
///
/// The right-hand column comes from the daemon's carry plan once `agents/continueWith`
/// exists (US5). Until then it shows what the chat has now and "the runtime's default",
/// which is what the look gate needs.
struct ContinueWithSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ContinueWith
    @State private var remember = true

    private var agent: Agent? { model.agents.first { $0.id == request.agentID } }
    private var to: String { PoolWords.runtimeName(request.entry.runtimeID) }
    private var from: String { agent.map { PoolWords.runtimeName($0.runtimeID) } ?? "" }

    /// The settings the chat has now, in the start form's order.
    private var rows: [(name: String, now: String, next: String, source: String)] {
        guard let agent else { return [] }
        return agent.advertisedOptions
            .filter(\.isRenderable)
            .sorted { $0.categoryRank < $1.categoryRank }
            .map { option in
                let now = agent.startOptions.values[option.id] ?? option.currentValue
                let nowName = option.options?.first { $0.value == now }?.name ?? now?.stringValue ?? "—"
                let isModel = option.category == "model" || option.id == "model"
                let next = isModel ? (request.entry.fallbackModel?.stringValue ?? "\(to)’s default") : "\(to)’s default"
                let source = isModel && request.entry.fallbackModel != nil ? "the pool entry" : "\(to)’s default"
                return (option.name, nowName, next, source)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Continue “\(agent?.title ?? "this chat")” with \(to)")
                    .appText(.title).fontWeight(.semibold)
                Spacer()
                if let row = model.poolStatus?.rows.first(where: { $0.entry.id == request.entry.id }) {
                    Text(row.line(now: model.poolStatus?.at ?? .now))
                        .appText(.fine).foregroundStyle(.secondary)
                }
            }
            Text("\(to) starts a new conversation and is given this one so far. Nothing is sent until you write to it.")
                .appText(.supporting).foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    Text("SETTING")
                    Text("NOW, ON \(from.uppercased())")
                    Text("ON \(to.uppercased())")
                    Text("WHERE IT CAME FROM")
                }
                .appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows, id: \.name) { row in
                    GridRow {
                        Text(row.name).appText(.reading).fontWeight(.semibold)
                        Text(row.now).appText(.reading)
                        Text(row.next)
                            .appText(.reading)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                        Text(row.source).appText(.fine).foregroundStyle(.secondary)
                    }
                }
            }

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

            Toggle("Remember this for next time", isOn: $remember)
            Text("Puts the model you pick here beside this chat’s model in a Matching models level.")
                .appText(.fine).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue on \(to)") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(true)
                    .help("Moving a chat by hand arrives with US5")
            }
        }
        .padding(24)
        .frame(width: 760)
    }
}
