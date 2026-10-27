import AgentsKitCore
import SwiftUI
import UniformTypeIdentifiers

/// Cost ▸ Reports (#1811): usage, cost and time by person, project, folder, machine and runtime,
/// added up on the control plane from what each machine sends each hour. It shows the
/// caller's own machines, an admin's too (the Me scope, #2071); a group's and everyone's are
/// Reports on the web page. Export saves the rows as CSV or JSON lines. Page picks Spend or
/// one of the pages of what the agents did (#2183): Outcomes, Time, Runtimes, Adoption and
/// Workflows, from the same rows' counts.
///
/// One view for the Mac's page and the Remote's (the web page's is `Web/src/views/Reports.tsx`).
struct ReportsPane: View {
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?

    @State private var page: DaemonAPI.ReportPage = .spend
    @State private var range: DaemonAPI.ReportRange = .week
    @State private var dimension: ReportTotals.Dimension = .person
    @State private var report: DaemonAPI.UsageReport?
    /// The report added up by the dimension, once per report or dimension, not at each draw (#2057).
    @State private var totals: ReportTotals?
    /// The counts pages' figures, added up once per report, page or dimension (#2183).
    @State private var outcomes: ReportOutcomes?
    @State private var weeks: [ReportAdoptionWeek]?
    @State private var problem: String?
    /// Whether reports/scopes offers the caller more than Me (#2200).
    @State private var seesMore = false
    @State private var export: ReportFile?
    @State private var isExporting = false

    var body: some View {
        List {
            Section {
                controls
                if let problem {
                    Text(problem).appText(.supporting).foregroundStyle(.secondary)
                }
            }
            .paperListRow()
            if let report, report.range == range {
                switch page {
                case .spend: spend
                case .adoption: adoption
                default: counts
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
        .task(id: Ask(range: range, connected: control != nil)) { await load() }
        .onChange(of: dimension) { addUp() }
        .onChange(of: page) {
            if page == .adoption, range == .day { range = .week }
            dimension = ReportOutcomes.Page(page)?.firstWay ?? .person
            addUp()
        }
        .fileExporter(isPresented: $isExporting, document: export, contentType: export?.type ?? .commaSeparatedText,
                      defaultFilename: export?.name) { result in
            if case .failure(let error) = result { problem = "Not exported: \(error.localizedDescription)" }
        }
    }

    /// Spend: cost, tokens and time by a way.
    @ViewBuilder private var spend: some View {
        if let totals {
            Section {
                if totals.groups.isEmpty {
                    Text(ReportWords.empty).appText(.supporting).foregroundStyle(.secondary)
                } else {
                    ReportGroupRow(name: totals.total.name, line: ReportWords.line(totals.total), share: nil).fontWeight(.semibold)
                    ForEach(totals.groups) { group in
                        ReportGroupRow(name: group.name, line: ReportWords.line(group), share: totals.share(of: group))
                    }
                }
            } footer: {
                footer(nil, bars: totals.groups.isEmpty ? nil : ReportWords.barCaption)
            }
            .paperListRow()
        }
    }

    /// Outcomes, Time, Runtimes or Workflows (#2183): the counts by a way.
    @ViewBuilder private var counts: some View {
        if let outcomes {
            Section {
                if outcomes.isEmpty {
                    Text(ReportOutcomeWords.none(outcomes.page)).appText(.supporting).foregroundStyle(.secondary)
                } else {
                    ReportGroupRow(name: outcomes.total.name, line: outcomes.line(outcomes.total), share: nil).fontWeight(.semibold)
                    ForEach(outcomes.groups) { group in
                        ReportGroupRow(name: group.name, line: outcomes.line(group), share: outcomes.bar(group))
                    }
                }
            } footer: {
                footer(ReportOutcomeWords.note(outcomes.page), bars: outcomes.isEmpty ? nil : ReportOutcomeWords.barCaption(outcomes.page))
            }
            .paperListRow()
        }
    }

    /// Adoption (#2183): each week's active people, sessions, runtimes and workflows.
    @ViewBuilder private var adoption: some View {
        if let weeks {
            Section {
                if weeks.isEmpty {
                    Text(ReportWords.empty).appText(.supporting).foregroundStyle(.secondary)
                } else {
                    ForEach(weeks) { week in
                        ReportGroupRow(name: week.title, line: week.line, share: nil)
                    }
                }
            } footer: {
                footer(ReportOutcomeWords.adoptionNote)
            }
            .paperListRow()
        }
    }

    /// What the bars measure, what the page counts, then whose machines.
    private func footer(_ note: String?, bars: String? = nil) -> some View {
        let whose = "\(ReportWords.meNote(seesMore: seesMore)) \(ReportWords.utcNote)"
        return Text([bars, note, whose].compactMap { $0 }.joined(separator: " "))
            .appText(.fine)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The ways a page adds up: none for Adoption.
    private static func ways(_ page: DaemonAPI.ReportPage) -> [ReportTotals.Dimension] {
        if page == .adoption { return [] }
        return ReportOutcomes.Page(page)?.ways ?? ReportTotals.Dimension.spend
    }

    /// The caller's own machines, an admin's too: the organisation is Reports ▸ Spend's (#2071).
    private static let me = DaemonAPI.ReportScope(kind: .me)

    private struct Ask: Equatable {
        var range: DaemonAPI.ReportRange
        var connected: Bool
    }

    /// The range, what to add up by, and Export.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Page", selection: $page) {
                ForEach(DaemonAPI.ReportPage.allCases, id: \.self) { Text(ReportOutcomeWords.title($0)).tag($0) }
            }
            // Six pages fit a segmented control on the Mac, not on a phone (#2183).
            #if os(macOS)
            .pickerStyle(.segmented)
            #else
            .pickerStyle(.menu)
            #endif
            .fixedSize()
            HStack(spacing: 12) {
                Picker("Range", selection: $range) {
                    // Adoption counts weeks, so it starts at W.
                    ForEach(DaemonAPI.ReportRange.allCases.filter { page != .adoption || $0 != .day }, id: \.self) {
                        Text(ReportWords.short($0)).accessibilityLabel(ReportWords.spoken($0)).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(ReportWords.span(range))
                Spacer(minLength: 0)
                Menu("Export…") {
                    Button("CSV") { Task { await exportRows(.csv) } }
                    Button("JSON lines") { Task { await exportRows(.jsonl) } }
                }
                .fixedSize()
                .appText(.fine)
                .help("Save the rows of this range")
                .disabled(control == nil)
            }
            if !Self.ways(page).isEmpty {
                Picker("By", selection: $dimension) {
                    ForEach(Self.ways(page)) { Text($0.rawValue).tag($0) }
                }
                // Up to six ways with Project (#2670): segments on the Mac, a menu on a phone.
                #if os(macOS)
                .pickerStyle(.segmented)
                #else
                .pickerStyle(.menu)
                .fixedSize()
                #endif
            }
            Text(ReportWords.span(range)).appText(.fine).foregroundStyle(.secondary)
        }
    }

    // MARK: Asking

    private func load() async {
        guard let control else {
            problem = "The control plane can’t be reached."
            return
        }
        do {
            report = try await control.call(DaemonAPI.Method.reportsUsage, DaemonAPI.ReportQuery(range: range, scope: Self.me),
                                            returning: DaemonAPI.UsageReport.self)
            addUp()
            problem = nil
        } catch {
            problem = ReportWords.sentence(error)
        }
        // A control plane before scopes offers Me only.
        let scopes = try? await control.call(DaemonAPI.Method.reportsScopes, DaemonAPI.Empty(), returning: DaemonAPI.ReportScopes.self)
        seesMore = (scopes?.scopes.count ?? 0) > 1
    }

    /// Adds up the report for the page shown only.
    private func addUp() {
        guard let report else { return }
        switch page {
        case .spend: totals = ReportTotals(report.rows, by: dimension)
        case .adoption: weeks = ReportAdoptionWeek.weeks(report.rows, hidden: report.personsHidden == true)
        default:
            if let counts = ReportOutcomes.Page(page) { outcomes = ReportOutcomes(report.rows, page: counts, by: dimension) }
        }
    }

    private func exportRows(_ format: DaemonAPI.ReportFormat) async {
        guard let control else { return }
        do {
            let got = try await control.call(DaemonAPI.Method.reportsExport, DaemonAPI.ReportQuery(range: range, format: format, scope: Self.me),
                                             returning: DaemonAPI.ReportExport.self)
            export = ReportFile(text: got.text, format: format, name: ReportWords.exportName(range, format))
            isExporting = true
        } catch {
            problem = ReportWords.sentence(error)
        }
    }
}

/// One person's, folder's, machine's or runtime's figures, with a bar for its share of
/// the largest.
private struct ReportGroupRow: View {
    let name: String
    let line: String
    /// Nil for the total.
    let share: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).appText(.reading).lineLimit(1)
            Text(line)
                .appText(.fine)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if let share {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(width: max(2, proxy.size.width * share))
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// An export, as the file it is saved as.
struct ReportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, AuditFile.type] }

    var text: String
    var type: UTType
    var name: String

    init(text: String, format: DaemonAPI.ReportFormat, name: String) {
        self.text = text
        self.type = format == .csv ? .commaSeparatedText : AuditFile.type
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
        type = configuration.contentType
        name = configuration.file.filename ?? "report"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
