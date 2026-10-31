import AgentsKitCore
import SwiftUI
import UniformTypeIdentifiers

/// Events ▸ Audit (#996, spec 736 US8): who did what through the control plane, newest
/// first in days. Read only. An admin also sets how long entries are kept, sees one
/// person's entries or everyone's, and exports them as CSV or JSON lines, as the web
/// page's Console ▸ Audit (#2087); a member sees only their own.
///
/// One view for the Mac's page and the Remote's (the web page's is `Web/src/views/Audit.tsx`).
struct AuditPane: View {
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?
    /// A host's name, as the client shows it.
    let hostName: (MachineRef) -> String

    @State private var list: DaemonAPI.AuditList?
    @State private var problem: String?
    @State private var export: ReportFile?
    /// For an admin: the people to narrow the entries to, and whose are shown ("" for everyone).
    @State private var people: [DaemonAPI.PersonRow] = []
    @State private var user = ""
    @State private var isExporting = false
    /// A shorter time, waiting for the admin to say yes (#2067).
    @State private var shorter: Int?

    private static let page = 200

    var body: some View {
        List {
            if let problem {
                Text(problem).appText(.supporting).foregroundStyle(.secondary).paperListRow()
            }
            if let list {
                Section {
                    footLine(list)
                }
                .paperListRow()
                if list.entries.isEmpty {
                    Text(AuditWords.empty).appText(.supporting).foregroundStyle(.secondary).paperListRow()
                }
                ForEach(AuditWords.days(list.entries), id: \.day) { day in
                    Section(EventDay.heading(for: day.day)) {
                        ForEach(day.entries) { AuditRow(entry: $0, hostName: hostName).paperListRow() }
                    }
                }
                if list.more {
                    Button("Show older") { Task { await loadOlder() } }
                        .buttonStyle(.plain)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .paperListRow()
                }
            } else if problem == nil {
                Text("Loading…").appText(.supporting).foregroundStyle(.secondary).paperListRow()
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
        .task(id: Ask(user: user, connected: control != nil)) { await load() }
        .fileExporter(isPresented: $isExporting, document: export, contentType: export?.type ?? AuditFile.type,
                      defaultFilename: export?.name) { result in
            if case .failure(let error) = result { problem = "Not exported: \(error.localizedDescription)" }
        }
    }

    private struct Ask: Equatable {
        var user: String
        var connected: Bool
    }

    /// The query for the person chosen, or everyone.
    private func query(until: Date? = nil, limit: Int? = nil) -> DaemonAPI.AuditQuery {
        DaemonAPI.AuditQuery(until: until, user: user.isEmpty ? nil : user, limit: limit)
    }

    /// How long entries are kept, and for an admin the menu to change it, Whose and Export.
    @ViewBuilder private func footLine(_ list: DaemonAPI.AuditList) -> some View {
        HStack(spacing: 12) {
            if list.admin {
                // A Picker, so the days set now have a check mark; a shorter time asks first (#2067).
                Picker("How long the audit is kept", selection: Binding(get: { list.days }, set: { days in
                    if days < list.days { shorter = days } else { Task { await setDays(days) } }
                })) {
                    ForEach(AuditWords.choices(with: list.days), id: \.self) { Text(AuditWords.kept($0)).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .appText(.fine)
                .fixedSize()
                .help("How long the control plane keeps who did what")
                .confirmationDialog(AuditWords.shorterTitle(shorter ?? list.days),
                                    isPresented: Binding(get: { shorter != nil }, set: { if !$0 { shorter = nil } }),
                                    titleVisibility: .visible) {
                    Button(AuditWords.shorterConfirm, role: .destructive) {
                        if let days = shorter { Task { await setDays(days) } }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    if let days = shorter {
                        // No count while Whose names a person: the list is theirs, and the
                        // sweep deletes everyone's (#2192).
                        Text(AuditWords.shorterMessage(from: list.days, to: days,
                                                       older: user.isEmpty ? AuditWords.older(list, than: days) : nil))
                    }
                }
                if !people.isEmpty {
                    Picker("Whose", selection: $user) {
                        Text(AuditWords.everyone).tag("")
                        ForEach(people) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .appText(.fine)
                    .fixedSize()
                    .help("Whose entries to see")
                }
                Spacer()
                Menu("Export…") {
                    Button("CSV") { Task { await exportAll(csv: true) } }
                    Button("JSON lines") { Task { await exportAll(csv: false) } }
                }
                .fixedSize()
                .appText(.fine)
                .help("Save these entries")
            } else {
                Text("\(AuditWords.kept(list.days)). You see what you did.")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .rowButtons()
    }

    // MARK: Asking

    private func load() async {
        guard let control else {
            problem = "The control plane can’t be reached."
            return
        }
        do {
            list = try await control.call(DaemonAPI.Method.auditList, query(limit: Self.page),
                                          returning: DaemonAPI.AuditList.self)
            problem = nil
            if list?.admin == true, people.isEmpty,
               let got = try? await control.call(DaemonAPI.Method.peopleList, returning: DaemonAPI.PeopleList.self) {
                people = got.people
            }
        } catch {
            problem = Self.sentence(error)
        }
    }

    private func loadOlder() async {
        guard let control, let current = list, let last = current.entries.last else { return }
        do {
            let older = try await control.call(DaemonAPI.Method.auditList,
                                               query(until: last.at.addingTimeInterval(-0.001), limit: Self.page),
                                               returning: DaemonAPI.AuditList.self)
            var next = current
            let seen = Set(current.entries.map(\.id))
            next.entries += older.entries.filter { !seen.contains($0.id) }
            next.more = older.more
            list = next
        } catch {
            problem = Self.sentence(error)
        }
    }

    private func setDays(_ days: Int) async {
        guard let control else { return }
        do {
            _ = try await control.call(DaemonAPI.Method.controlSetAuditDays, DaemonAPI.AuditDays(days: days))
            await load()
        } catch {
            problem = Self.sentence(error)
        }
    }

    private func exportAll(csv: Bool) async {
        guard let control else { return }
        do {
            let got = try await control.call(DaemonAPI.Method.auditExport, query(),
                                             returning: DaemonAPI.AuditExport.self)
            export = ReportFile(text: csv ? AuditWords.csv(got.lines, hostName: hostName) : got.lines,
                                format: csv ? .csv : .jsonl, name: AuditWords.exportName(csv: csv))
            isExporting = true
        } catch {
            problem = Self.sentence(error)
        }
    }

    private static func sentence(_ error: Error) -> String {
        if let error = error as? JSONRPCError {
            // A control plane before #996 does not know the audit.
            return error.code == -32601 ? "This control plane keeps no audit. Update it to see who did what." : error.message
        }
        return "The control plane can’t be reached."
    }
}

/// One entry: the time, what was done, then who and where, then the call in monospace.
struct AuditRow: View {
    let entry: DaemonAPI.AuditEntry
    let hostName: (MachineRef) -> String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(LeaseWords.clock(entry.at))
                .appText(.fine)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.action)
                    .appText(.reading)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(AuditWords.who(entry.actor)) \(AuditWords.place(entry, hostName: hostName))")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                Text(AuditWords.call(entry))
                    .appText(.fine)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The JSON lines file type; an export is saved as a `ReportFile`.
enum AuditFile {
    static let type = UTType(filenameExtension: "jsonl", conformingTo: .plainText) ?? .plainText
}
