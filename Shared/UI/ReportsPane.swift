import AgentsKitCore
import SwiftUI
import UniformTypeIdentifiers

/// Cost ▸ Reports (#1811): usage, cost and time by person, project, folder, machine and runtime,
/// added up on the control plane from what each machine sends each hour. It shows the
/// caller's own machines, an admin's too (the Me scope, #2071); a group's and everyone's are
/// Reports on the web page. Export saves the rows as CSV or JSON lines. Page picks Spend or
/// one of the pages of what the agents did (#2183): Outcomes, Time, Runtimes, Adoption and
/// Workflows, from the same rows' counts. Value (#2351) is what the work cost and delivered, on
/// the Mac only: the Remote's tier leaves it out (#2796). Features (#2165) is which methods the clients and
/// agents called on the person's own machines, from each host's counts; the Mac's and the web
/// page's too.
///
/// One view for the Mac's page and the Remote's (the web page's is `Web/src/views/Reports.tsx`).
struct ReportsPane: View {
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?
    /// Every host's feature counts (#2165), added up; nil where the page is not drawn.
    var features: (() async -> DaemonAPI.FeatureUsage?)?

    @State private var page: DaemonAPI.ReportPage = .spend
    /// Features is shown in place of the page (#2165): it is no page of the control plane's.
    @State private var showsFeatures = false
    @State private var featureUsage: DaemonAPI.FeatureUsage?
    @State private var range: DaemonAPI.ReportRange = .week
    @State private var dimension: ReportTotals.Dimension = .person
    @State private var report: DaemonAPI.UsageReport?
    /// The report added up by the dimension, once per report or dimension, not at each draw (#2057).
    @State private var totals: ReportTotals?
    /// The counts pages' figures, added up once per report, page or dimension (#2183).
    @State private var outcomes: ReportOutcomes?
    @State private var weeks: [ReportAdoptionWeek]?
    /// Value's answer (#2351), asked for only on that page.
    @State private var value: DaemonAPI.ReportValue?
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
            if showsFeatures {
                if let featureUsage {
                    featuresPage(featureUsage)
                } else {
                    Text("Loading…").appText(.supporting).foregroundStyle(.secondary).paperListRow()
                }
            } else if page == .value {
                if let value, value.range == range {
                    valuePage(value)
                } else if problem == nil {
                    Text("Loading…").appText(.supporting).foregroundStyle(.secondary).paperListRow()
                }
            } else if let report, report.range == range {
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
        .refreshable {
            if showsFeatures { await loadFeatures() } else { await load() }
        }
        .task(id: showsFeatures) { if showsFeatures { await loadFeatures() } }
        .task(id: Ask(range: range, connected: control != nil, isValue: page == .value)) { await load() }
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

    /// Value (#2351): cost per merged pull request, waste and lead time, then each issue and
    /// milestone, the most costly first.
    @ViewBuilder private func valuePage(_ value: DaemonAPI.ReportValue) -> some View {
        Section {
            if ReportValueWords.isEmpty(value) {
                Text(ReportValueWords.none).appText(.supporting).foregroundStyle(.secondary)
            } else {
                ReportGroupRow(name: ReportValueWords.headline(value), line: ReportValueWords.waste(value), share: nil)
                    .fontWeight(.semibold)
                if let lead = ReportValueWords.lead(value) { Text(lead).appText(.supporting) }
                if let unlinked = ReportValueWords.unlinked(value) {
                    Text(unlinked).appText(.supporting).foregroundStyle(.secondary)
                }
            }
        } footer: {
            footer(ReportValueWords.note)
        }
        .paperListRow()
        if !value.issues.isEmpty {
            Section("Issues") { ForEach(value.issues) { ReportValueRowView(row: $0) } }
                .paperListRow()
        }
        if !value.milestones.isEmpty {
            Section {
                ForEach(value.milestones) { ReportValueRowView(row: $0) }
            } header: {
                Text("Milestones")
            } footer: {
                if value.limited == true { Text("The 100 most costly of each.").appText(.fine).foregroundStyle(.secondary) }
            }
            .paperListRow()
        }
    }

    /// Features (#2165): each method with its uses, the least used first; one never used in
    /// the range is marked.
    @ViewBuilder private func featuresPage(_ usage: DaemonAPI.FeatureUsage) -> some View {
        Section {
            // Above the rows, not in the footer, where a long list cuts it to one line.
            Text(FeatureWords.note(usage))
                .appText(.fine)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if usage.features.isEmpty {
                Text(FeatureWords.none).appText(.supporting).foregroundStyle(.secondary)
            } else {
                ForEach(usage.features) { feature in
                    FeatureRow(feature: feature, days: usage.days)
                }
            }
        }
        .paperListRow()
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
        if page == .adoption || page == .value { return [] }
        return ReportOutcomes.Page(page)?.ways ?? ReportTotals.Dimension.spend
    }

    /// The caller's own machines, an admin's too: the organisation is Reports ▸ Spend's (#2071).
    private static let me = DaemonAPI.ReportScope(kind: .me)

    private struct Ask: Equatable {
        var range: DaemonAPI.ReportRange
        var connected: Bool
        var isValue: Bool
    }

    /// The pages this client draws: Value is the Mac's and the web page's (tier mac+web, #2796).
    private static var pages: [DaemonAPI.ReportPage] {
        #if os(macOS)
        DaemonAPI.ReportPage.allCases
        #else
        DaemonAPI.ReportPage.allCases.filter { $0 != .value }
        #endif
    }

    /// The page picked: a page of the control plane's, or Features.
    private var choice: Binding<String> {
        Binding(get: { showsFeatures ? Self.featuresTag : page.rawValue }, set: { tag in
            if tag == Self.featuresTag {
                showsFeatures = true
            } else if let picked = DaemonAPI.ReportPage(rawValue: tag) {
                showsFeatures = false
                page = picked
            }
        })
    }

    private static let featuresTag = "features"

    /// The page, then the range, what to add up by, and Export.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Page", selection: choice) {
                ForEach(Self.pages, id: \.self) { Text(ReportOutcomeWords.title($0)).tag($0.rawValue) }
                if features != nil { Text("Features").tag(Self.featuresTag) }
            }
            // Six pages fit a segmented control on the Mac, not on a phone (#2183).
            #if os(macOS)
            .pickerStyle(.segmented)
            #else
            .pickerStyle(.menu)
            #endif
            .fixedSize()
            if !showsFeatures { reportControls }
        }
    }

    /// The range, what to add up by, and Export, for a page of the control plane's.
    @ViewBuilder private var reportControls: some View {
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
            // Value's numbers are not rows to export.
            if page != .value { exportMenu }
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

    private var exportMenu: some View {
        Menu("Export…") {
            Button("CSV") { Task { await exportRows(.csv) } }
            Button("JSON lines") { Task { await exportRows(.jsonl) } }
        }
        .fixedSize()
        .appText(.fine)
        .help("Save the rows of this range")
        .disabled(control == nil)
    }

    // MARK: Asking

    private func loadFeatures() async {
        guard let features else { return }
        featureUsage = await features() ?? DaemonAPI.FeatureUsage(days: 90, features: [])
    }

    private func load() async {
        guard let control else {
            problem = "The control plane can’t be reached."
            return
        }
        if page == .value {
            do {
                value = try await control.call(DaemonAPI.Method.reportsValue, DaemonAPI.ReportQuery(range: range, scope: Self.me),
                                               returning: DaemonAPI.ReportValue.self)
                problem = nil
            } catch {
                problem = ReportValueWords.sentence(error)
            }
        } else {
            do {
                report = try await control.call(DaemonAPI.Method.reportsUsage, DaemonAPI.ReportQuery(range: range, scope: Self.me),
                                                returning: DaemonAPI.UsageReport.self)
                addUp()
                problem = nil
            } catch {
                problem = ReportWords.sentence(error)
            }
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

/// An issue or a milestone on Value (#2351): its name, a link to it on GitHub, and its figures.
private struct ReportValueRowView: View {
    let row: DaemonAPI.ReportValueRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let url = ReportValueWords.url(row.node) {
                Link(ReportValueWords.name(row.node), destination: url).appText(.reading).lineLimit(1)
            } else {
                Text(ReportValueWords.name(row.node)).appText(.reading).lineLimit(1)
            }
            Text(ReportValueWords.line(row))
                .appText(.fine)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// One feature on Features (#2165): its method, its uses and its clients, marked when unused.
private struct FeatureRow: View {
    let feature: DaemonAPI.FeatureUse
    let days: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(feature.method).appText(.reading).monospaced().lineLimit(1)
                if feature.quarter == 0 {
                    Text(FeatureWords.unused).appText(.fine).foregroundStyle(.orange)
                }
            }
            Text(FeatureWords.line(feature, days: days))
                .appText(.fine)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
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
