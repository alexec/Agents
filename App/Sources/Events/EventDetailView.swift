import AgentsKit
import SwiftUI

/// Everything one event carries, beside the list (042; wireframes §1).
///
/// Its details, who published it if an agent did, its place in the log, and Copy as
/// trigger — the shortest way from "that happened" to "do something next time it does".
struct EventDetailView: View {
    let event: Event
    let scopeName: String
    let close: () -> Void
    @State private var copied = false

    private var trigger: String { EventPattern.matching(event).asTrigger }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.name).appText(.reading).monospaced()
                    Spacer()
                    Button(action: close) {
                        Image(systemName: "xmark").font(.caption) // decorative glyph
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Close")
                }
                Text(event.sentence).appText(.reading)
                detailGrid
                if let meaning = EventCatalogue.kind(named: event.name)?.meaning
                    ?? (EventCatalogue.isCustom(event.name) ? EventCatalogue.customMeaning : nil) {
                    Text(meaning).appText(.supporting).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(trigger)
                        .appText(.fine)
                        .monospaced()
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .paperWell(in: RoundedRectangle(cornerRadius: 6))
                    Button(copied ? "Copied" : "Copy as trigger") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(trigger, forType: .string)
                        copied = true
                    }
                    .help("Copies the lines a workflow's on: needs to run when this happens again")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: event.position) { copied = false }
    }

    private var rows: [(String, String)] {
        var rows: [(String, String)] = [
            ("When", event.at.formatted(date: .abbreviated, time: .standard)),
            ("Where", scopeName),
        ]
        if event.count > 1, let last = event.lastAt {
            rows.append(("Repeats", "\(event.count) times, last at \(LeaseWords.clock(last))"))
        }
        if let publisher = event.publisher { rows.append(("Published by", publisher.title)) }
        if let message = event.message { rows.append(("Message", message)) }
        for (key, value) in event.details.sorted(by: { $0.key < $1.key }) { rows.append((key, value)) }
        rows.append(("Position", "\(event.position)"))
        return rows
    }

    private var detailGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary)
                    Text(row.1).textSelection(.enabled)
                }
            }
        }
        .appText(.supporting)
    }
}
