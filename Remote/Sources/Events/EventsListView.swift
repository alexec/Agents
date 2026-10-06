import AgentsKitCore
import SwiftUI

/// What happened on the Mac, and what came of it, read on the phone or iPad (042 FR-029;
/// wireframes §4).
///
/// The same rows as the Mac's page, from the same view. The phone reads: no Copy as
/// trigger and no subject filters here, only one menu for where.
struct EventsListView: View {
    @Environment(RemoteModel.self) private var model
    /// Nil: every project and the Mac.
    @State private var scope: EventScope?
    @State private var picked: Event?

    private struct Ask: Equatable {
        var filter: EventFilter
        var connected: Bool
    }

    private var filter: EventFilter { EventFilter(scope: scope) }

    /// The Mac sends pages already narrowed; narrowing here too keeps the list right in
    /// the moment between the menu changing and its page arriving. Narrowed and cut into
    /// days once per change of the events or the filter, not per redraw (#137).
    private var shown: ShownEvents {
        model.work.shownEvents(filter)
    }

    var body: some View {
        let shown = self.shown
        List {
            if !model.work.waitingAgents.isEmpty {
                Section("Waiting now") {
                    ForEach(model.work.waitingAgents) { agent in
                        HStack(spacing: 12) {
                            Button {
                                model.open(agent.agentID)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.title).appText(.reading)
                                    Text(agent.status.line).appText(.fine).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if agent.status.cancellable {
                                Button {
                                    Task { await model.cancelWait(of: agent.agentID) }
                                } label: {
                                    Image(systemName: "xmark").font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Stop waiting. Nothing will start it again for this wait.")
                            }
                        }
                        .paperListRow()
                    }
                }
            }
            if shown.events.isEmpty {
                Text(model.work.eventsLoaded
                     ? "Nothing has happened yet. Events appear here as agents, workflows and the Mac do things."
                     : "Loading…")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .paperListRow()
            }
            ForEach(shown.days, id: \.day) { day in
                Section(EventDay.heading(for: day.day)) {
                    ForEach(day.events, id: \.position) { event in
                        EventRow(event: event, scopeName: scopeName(event.scope),
                                 openAgent: { model.open($0) },
                                 openWorkflow: { folder, workflow in
                                     model.openWorkflow = Project.standardize(folder).path + "/" + workflow
                                 })
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
        .refreshable { await model.refreshEvents(filter) }
        // Read as it opens, as the filter changes, and as the Mac is back (#175): not on
        // every connection while it is shut.
        .task(id: Ask(filter: filter, connected: model.isConnected)) {
            if model.isConnected { await model.refreshEvents(filter) }
        }
        .onDisappear { model.work.clearEvents() }
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

/// The Events row under Activity, the Mac's shape.
struct EventsRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Events")
            Spacer()
            if let last = model.work.lastEventAt {
                Text("Last \(LeaseWords.clock(last))")
                    .monospacedDigit()
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHint("Opens Events")
    }
}
