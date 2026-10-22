import AgentsKitCore
import SwiftUI
import UniformTypeIdentifiers

/// Cost ▸ Reports (#1811): usage, cost and time by person, project, machine and runtime,
/// added up on the control plane from what each machine sends each hour. An admin sees
/// every person's machines; a member their own. Export saves the rows as CSV or JSON lines.
///
/// One view for the Mac's page and the Remote's (the web page's is `Web/src/views/Reports.tsx`).
struct ReportsPane: View {
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?

    @State private var range: DaemonAPI.ReportRange = .week
    @State private var dimension: ReportTotals.Dimension = .person
    @State private var report: DaemonAPI.UsageReport?
    /// The report added up by the dimension, once per report or dimension, not at each draw (#2057).
    @State private var totals: ReportTotals?
    @State private var problem: String?
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
            if let report, report.range == range, let totals {
                Section {
                    if totals.groups.isEmpty {
                        Text(ReportWords.empty).appText(.supporting).foregroundStyle(.secondary)
                    } else {
                        ReportGroupRow(group: totals.total, share: nil).fontWeight(.semibold)
                        ForEach(totals.groups) { group in
                            ReportGroupRow(group: group, share: totals.share(of: group))
                        }
                    }
                } footer: {
                    Text(report.admin ? ReportWords.utcNote : "\(ReportWords.memberNote) \(ReportWords.utcNote)")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                .paperListRow()
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
        .fileExporter(isPresented: $isExporting, document: export, contentType: export?.type ?? .commaSeparatedText,
                      defaultFilename: export?.name) { result in
            if case .failure(let error) = result { problem = "Not exported: \(error.localizedDescription)" }
        }
    }

    private struct Ask: Equatable {
        var range: DaemonAPI.ReportRange
        var connected: Bool
    }

    /// The range, what to add up by, and Export.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Range", selection: $range) {
                    ForEach(DaemonAPI.ReportRange.allCases, id: \.self) { Text(ReportWords.short($0)).tag($0) }
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
            Picker("By", selection: $dimension) {
                ForEach(ReportTotals.Dimension.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
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
            report = try await control.call(DaemonAPI.Method.reportsUsage, DaemonAPI.ReportQuery(range: range),
                                            returning: DaemonAPI.UsageReport.self)
            addUp()
            problem = nil
        } catch {
            problem = ReportWords.sentence(error)
        }
    }

    private func addUp() {
        totals = report.map { ReportTotals($0.rows, by: dimension) }
    }

    private func exportRows(_ format: DaemonAPI.ReportFormat) async {
        guard let control else { return }
        do {
            let got = try await control.call(DaemonAPI.Method.reportsExport, DaemonAPI.ReportQuery(range: range, format: format),
                                             returning: DaemonAPI.ReportExport.self)
            export = ReportFile(text: got.text, format: format, name: ReportWords.exportName(range, format))
            isExporting = true
        } catch {
            problem = ReportWords.sentence(error)
        }
    }
}

/// One person's, project's, machine's or runtime's figures, with a bar for its share of
/// the largest.
private struct ReportGroupRow: View {
    let group: ReportTotals.Group
    /// Nil for the total.
    let share: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.name).appText(.reading).lineLimit(1)
            Text(ReportWords.line(group))
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
