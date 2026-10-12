import AgentsKitCore
import SwiftUI

/// A file an agent showed with `show_file`, where it showed it (#836). Layout A of
/// specs/836-file-card/layout.svg: a chart or a picture has its preview above the
/// name; anything else is one line. A tap opens it in the Files pane at its line.
/// The page draws the same card in FileCard.tsx.
struct FileCard: View {
    let file: ShownFile
    @Environment(\.chatActions) private var actions
    /// A spec's own mark, once its preview has read it: "Bar chart", not "Chart".
    @State private var mark: ChartMark?

    /// The widest a card is drawn, and the tallest its preview.
    static let width: CGFloat = 340
    static let previewHeight: CGFloat = 150

    var body: some View {
        Group {
            if let open = actions.showFile {
                Button { open(file) } label: { card }
                    .buttonStyle(.plain)
                    .help("Open \(file.name) in Files")
            } else {
                card
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.name), \(file.lookWords)")
        .accessibilityAddTraits(actions.showFile == nil ? [] : .isButton)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            if file.look == .chart || file.look == .picture {
                FilePreview(file: file, mark: $mark)
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.previewHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).appText(.reading).fontWeight(.semibold).lineLimit(1)
                    Text(detail).appText(.fine).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if actions.showFile != nil {
                    Image(systemName: "chevron.right").appText(.fine).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    private var symbol: String {
        switch file.look {
        case .chart: return "chart.bar"
        case .picture: return "photo"
        case .page: return "doc.richtext"
        case .file: return "doc.text"
        }
    }

    /// "Bar chart · reports/ · line 12".
    private var detail: String {
        let folder = file.url.deletingLastPathComponent().lastPathComponent
        return [mark?.words ?? file.lookWords, folder.isEmpty ? nil : "\(folder)/", file.line.map { "line \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// The card's preview: the chart drawn small, or the picture.
private struct FilePreview: View {
    let file: ShownFile
    @Binding var mark: ChartMark?
    @Environment(\.chatActions) private var actions

    private enum Shown {
        case loading
        case chart(ChartSpec)
        case picture(Image)
        case nothing(String)
    }

    @State private var shown = Shown.loading

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.5))
            switch shown {
            case .loading:
                ProgressView().controlSize(.small)
            case .chart(let spec):
                ChartView(spec: spec, compact: true).padding(10)
            case .picture(let image):
                image.resizable().scaledToFit().padding(6)
            case .nothing(let words):
                Text(words).appText(.fine).foregroundStyle(.secondary).padding(10)
            }
        }
        .task(id: file) {
            shown = await load()
            if case .chart(let spec) = shown { mark = spec.mark }
        }
    }

    private func load() async -> Shown {
        if file.look == .picture {
            if let image = await actions.picture(file) { return .picture(image) }
            return .nothing("Not there now")
        }
        guard case .text(let text, _, _, _)? = await actions.readFile(file.path) else {
            return .nothing("Not there now")
        }
        let read = actions.readFile
        let result = await ChartPage.read(text, url: file.url, hint: file.chart) { url in
            if case .text(let text, _, _, _)? = await read(url.path) { return text }
            return nil
        }
        switch result {
        case .success(let spec): return .chart(spec)
        case .failure(let problem): return .nothing(problem.words)
        }
    }
}
