import AgentsKitCore
import SwiftUI

/// A file an agent showed with `show_file`, where it showed it (#836), as an Object card (#5035):
/// a chart, a diagram (#853) or a picture has its preview above the name; anything else is one
/// row. A tap opens it in the Files pane at its line. The page draws the same card in FileCard.tsx.
struct FileCard: View {
    let file: ShownFile
    @Environment(\.chatActions) private var actions
    /// A spec's own mark, once its preview has read it: "Bar chart", not "Chart".
    @State private var mark: ChartMark?

    var body: some View {
        Group {
            if file.look == .chart || file.look == .diagram || file.look == .picture {
                ObjectCard(icon: symbol, title: file.name, detail: detail,
                           open: open, openHelp: "Open \(file.name) in Files") {
                    FilePreview(file: file, mark: $mark)
                        .frame(height: ObjectCard<EmptyView, EmptyView>.previewHeight)
                }
            } else {
                ObjectCard(icon: symbol, title: file.name, detail: detail,
                           open: open, openHelp: "Open \(file.name) in Files",
                           preview: { EmptyView() }, notes: { EmptyView() })
            }
        }
        .frame(maxWidth: ObjectCard<EmptyView, EmptyView>.width, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(actions.showFile == nil ? [] : .isButton)
    }

    /// A tap opens it in Files, where the chat can.
    private var open: (@MainActor () -> Void)? {
        guard let show = actions.showFile else { return nil }
        let file = file
        return { show(file) }
    }

    private var symbol: String {
        switch file.look {
        case .chart: return "chart.bar"
        case .diagram: return "point.3.connected.trianglepath.dotted"
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

/// The card's preview: the chart or the diagram drawn small, or the picture.
private struct FilePreview: View {
    let file: ShownFile
    @Binding var mark: ChartMark?
    @Environment(\.chatActions) private var actions

    private enum Shown {
        case loading
        case chart(ChartSpec)
        case diagram(MermaidDiagram)
        case picture(Image)
        case nothing(String)
    }

    @State private var shown = Shown.loading

    var body: some View {
        ZStack {
            switch shown {
            case .loading:
                ProgressView().controlSize(.small)
            case .chart(let spec):
                ChartView(spec: spec, compact: true).padding(10)
            case .diagram(let diagram):
                MermaidView(diagram: diagram).padding(10)
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
        if file.look == .diagram {
            switch MermaidDiagram.read(text) {
            case .success(let diagram): return .diagram(diagram)
            case .failure(let problem): return .nothing(problem.words)
            }
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
