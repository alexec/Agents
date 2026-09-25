import AgentsKitCore
import SwiftUI

/// What happened on the Mac, and what came of it, read on the phone or iPad (042 FR-029;
/// wireframes §4).
///
/// The same rows as the Mac's page, from the same view. The phone reads: there is no
/// cancelling a wait, no Copy as trigger and no subject filters here, only one menu
/// for where. An agent in a consequence is a way to its chat; a workflow is plain text,
/// because the phone has no workflow page to go to.
struct EventsListView: View {
    @Environment(RemoteModel.self) private var model
    /// Nil: every project and the Mac.
    @State private var scope: EventScope?
    @State private var picked: Event?

    private var events: [Event] {
        model.work.recentEvents.filter { scope == nil || $0.scope == scope }
    }

    var body: some View {
        List {
            if events.isEmpty {
                Text(model.work.eventsLoaded
                     ? "Nothing has happened yet. Events appear here as agents, workflows, pull requests and the Mac do things."
                     : "Loading…")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .paperListRow()
            }
            ForEach(EventDay.grouped(events), id: \.day) { day in
                Section(EventDay.heading(for: day.day)) {
                    ForEach(day.events, id: \.position) { event in
                        EventRow(event: event, scopeName: scopeName(event.scope),
                                 openAgent: { model.open($0) })
                            .contentShape(Rectangle())
                            .onTapGesture { picked = event }
                            .paperListRow()
                    }
                }
            }
            if model.work.moreEvents {
                Button("Show older") { Task { await model.loadOlderEvents() } }
                    .appText(.supporting)
                    .paperListRow()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .paperGround()
        .navigationTitle("Events")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("All") { scope = nil }
                    Button("This Mac") { scope = .mac }
                    Divider()
                    ForEach(model.projects, id: \.project.folder) { summary in
                        Button(summary.name) { scope = .project(folder: summary.project.folder) }
                    }
                } label: {
                    Text(scope.map(scopeName) ?? "All").appText(.supporting)
                }
            }
        }
        .refreshable { await model.refreshEvents() }
        .sheet(item: $picked) { event in
            EventSheet(event: event, scopeName: scopeName(event.scope))
        }
    }

    private func scopeName(_ scope: EventScope) -> String {
        switch scope {
        case .mac: return "This Mac"
        case .project(let folder):
            return model.projects.first { Project.standardize($0.project.folder) == folder }?.name
                ?? folder.lastPathComponent
        }
    }
}

/// Everything one event carries, read-only.
private struct EventSheet: View {
    let event: Event
    let scopeName: String

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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(event.sentence).appText(.reading)
                    Text(event.name).appText(.fine).monospaced().foregroundStyle(.secondary)
                }
                Section {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        LabeledContent(row.0, value: row.1)
                            .appText(.supporting)
                    }
                }
            }
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .paperSheet()
    }
}

/// The way into Events, under the projects beside Spending, with the Mac's shape.
struct EventsRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        NavigationLink {
            EventsListView()
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text("Events")
                Spacer()
                if let last = model.work.lastEventAt {
                    Text("Last \(LeaseWords.clock(last))").monospacedDigit()
                }
                Image(systemName: "chevron.right")
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
            }
            .appText(.supporting)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Paper.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(Paper.rule).frame(height: 1) }
        .accessibilityHint("Opens Events")
    }
}
