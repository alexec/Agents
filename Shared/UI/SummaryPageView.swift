import AgentsKitCore
import SwiftUI

/// The sidebar's Summary row's label (#3721): "Summary", the newest page's title under it, and
/// a dot while that page is unread. The Mac and the Remote draw it at the top of the sidebar,
/// above Work and the smart groups, while the daily summary is on; the client adds the icon.
struct SummaryRowLabel: View {
    let newest: SummaryPage?

    /// The row's icon, beside it as the other pages' rows have theirs.
    static let systemImage = "sun.horizon"

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Summary")
                    .foregroundStyle(.primary)
                    .fontWeight(newest?.unread == true ? .semibold : .regular)
                Text(newest?.title ?? SummaryPageView.nonePage)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if newest?.unread == true {
                Circle()
                    .sidebarMark(Paper.accent)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Unread")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The Summary page (#3721): the daily summary's newest saved page, with the earlier ones in a
/// picker, the session that wrote it one tap away, and the daily summary's control under it,
/// the same one Settings ▸ Agent Configuration ▸ Workflows has (#3351, #3395). Opens in the
/// detail column on a Mac and an iPad and is pushed on an iPhone. Links on the page open their
/// session, pull request or issue (#3353), as the client's openURL does.
struct SummaryPageView: View {
    /// The saved pages, newest first, as `summaries/list` says them.
    let pages: [SummaryPage]
    /// The control; nil while the host has not said.
    let settings: DailySummarySettings?
    /// Reads a page; nil when it could not be read. Reading the newest marks it read.
    let read: (String) async -> SummaryPageText?
    let setSettings: (DailySummarySettings) -> Void
    /// Opens the session that wrote the page; nil where the client cannot.
    var openAgent: ((UUID) -> Void)?

    /// The row's line and the page's when no page is saved yet.
    static let nonePage = "No summary yet"

    @State private var chosen: String?
    @State private var text: SummaryPageText?
    @State private var loaded = false

    /// The page shown: the one picked, else the newest.
    private var shown: SummaryPage? {
        pages.first { $0.name == chosen } ?? pages.first
    }

    var body: some View {
        content
            .navigationTitle("Summary")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if pages.count > 1 {
                    ToolbarItem { picker }
                }
            }
            // The newest page again after a new one is saved, and read again after a change.
            .task(id: shown) {
                guard let shown else {
                    text = nil
                    loaded = true
                    return
                }
                if text?.page.name != shown.name { text = nil }
                text = await read(shown.name)
                loaded = true
            }
    }

    #if os(iOS)
    private var content: some View {
        List {
            Section { page }
                .paperListRow()
            if let writer = shown?.writer, let openAgent {
                Section { Button("How this was written") { openAgent(writer) } }
                    .paperListRow()
            }
            Section {
                if let settings {
                    DailySummaryControls(settings: settings, set: setSettings)
                }
            } header: {
                Text("Daily summary")
            } footer: {
                Text(DailySummaryControls.footer(for: settings?.mode ?? .off))
                    .appText(.fine)
            }
            .paperListRow()
        }
        .paperForm()
    }
    #else
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                page
                if let writer = shown?.writer, let openAgent {
                    Button("How this was written") { openAgent(writer) }
                        .buttonStyle(.link)
                        .appText(.supporting)
                }
                Divider()
                if let settings {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 16) {
                            DailySummaryControls(settings: settings, set: setSettings)
                                .fixedSize()
                            Spacer()
                        }
                        Text(DailySummaryControls.footer(for: settings.mode))
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
    #endif

    @ViewBuilder private var page: some View {
        if let text {
            MarkdownText(markdown: text.markdown)
                .appText(.reading)
                .textSelection(.enabled)
        } else if shown == nil {
            Text(Self.nonePage + ". " + Self.firstAt(settings))
                .appText(.supporting)
                .foregroundStyle(.secondary)
        } else if !loaded {
            ProgressView().controlSize(.small)
        } else {
            Text("The summary could not be read.")
                .appText(.supporting)
                .foregroundStyle(.secondary)
        }
    }

    private var picker: some View {
        Picker("Page", selection: Binding(get: { shown?.name ?? "" }, set: { chosen = $0 })) {
            ForEach(pages) { page in
                Text(Self.when(page.savedAt)).tag(page.name)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    /// A page's place in the picker, such as "Fri 6 Nov, 18:10".
    static func when(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    /// When the first page comes, as the page says before there is one.
    static func firstAt(_ settings: DailySummarySettings?) -> String {
        guard let settings, settings.mode != .off else { return "Turn the daily summary on below." }
        return "The first one is written at \(DailySummarySettings.timeLabel(settings.at))."
    }
}
