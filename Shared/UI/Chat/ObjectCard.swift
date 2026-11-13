import SwiftUI

/// The one Object card (#5035; `specs/session-cards/spec.md`, family 3): a thing the agent made,
/// to open. A raised box: the preview when there is one, then one row of the kind's icon, the
/// name, a quiet line (kind · place), ⋯ for the rest and › when a tap opens it. A file shown
/// with `show_file`, what a turn changed, and an app view's frame are all drawn with it. The
/// window and the Remote both draw it; the web page's is `ObjectCard.tsx`.
struct ObjectCard<Preview: View, Notes: View>: View {
    /// An SF Symbol's name, drawn as its Lucide icon (`Image(icon:)`, #4976).
    let icon: String
    let title: String
    let detail: String
    /// What a tap on the row (and the preview) does; nil draws the card with no ›, and a tap does nothing.
    var open: (@MainActor () -> Void)?
    var openHelp: String?
    /// The actions that are not the tap: Undo These Changes, Pin to Folder, Full screen.
    var more: [StripButton] = []
    /// False when the preview is live (an app view): a click on the preview does not open, as the view takes its own.
    var tapAnywhere = true
    let preview: Preview
    /// Quiet lines under the row: an undo's outcome, a failure.
    let notes: Notes

    /// The widest a card with no live preview is drawn, and the tallest its preview.
    static var width: CGFloat { 360 }
    static var previewHeight: CGFloat { 150 }

    init(icon: String, title: String, detail: String, open: (@MainActor () -> Void)? = nil, openHelp: String? = nil,
         more: [StripButton] = [], tapAnywhere: Bool = true,
         @ViewBuilder preview: () -> Preview, @ViewBuilder notes: () -> Notes) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.open = open
        self.openHelp = openHelp
        self.more = more
        self.tapAnywhere = tapAnywhere
        self.preview = preview()
        self.notes = notes()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if Preview.self != EmptyView.self {
                Group {
                    // A click on the preview opens too, unless the preview is live and takes its own.
                    if let open, tapAnywhere {
                        Button(action: open) { previewBox }
                            .buttonStyle(.plain)
                            .help(openHelp ?? "")
                            .accessibilityHidden(true)
                    } else {
                        previewBox
                    }
                }
                Divider().overlay(Paper.rule)
            }
            VStack(alignment: .leading, spacing: 6) {
                row
                notes
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Paper.raised)
        .clipShape(RoundedRectangle(cornerRadius: Paper.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule))
        .accessibilityElement(children: .contain)
    }

    private var previewBox: some View {
        preview
            .frame(maxWidth: .infinity)
            .background(Paper.well)
            .contentShape(Rectangle())
    }

    /// The icon and the words: the button that opens, with ⋯ and › beside it rather than in it,
    /// so each keeps its own click (a menu inside a button's label does not, on the Mac).
    private var words: some View {
        HStack(spacing: 10) {
            Image(icon: icon)
                .foregroundStyle(Paper.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appText(.reading).fontWeight(.semibold).lineLimit(1)
                Text(detail).appText(.fine).foregroundStyle(Paper.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var row: some View {
        HStack(spacing: 6) {
            if let open {
                Button(action: open) { words }
                    .buttonStyle(.plain)
                    .help(openHelp ?? "")
                    .accessibilityLabel("\(title), \(detail)")
                    .accessibilityHint(openHelp ?? "")
            } else {
                words
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(title), \(detail)")
            }
            if !more.isEmpty {
                Menu {
                    ForEach(more.indices, id: \.self) { index in
                        let item = more[index]
                        Button(item.title, action: item.action).disabled(item.disabled).help(item.help ?? "")
                    }
                } label: {
                    Image(icon: "ellipsis")
                        .foregroundStyle(Paper.secondary)
                        .frame(minWidth: 24, minHeight: 24)
                        .contentShape(Rectangle())
                        .accessibilityLabel(StripWords.moreActions)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(StripWords.moreActions)
            }
            if let open {
                Button(action: open) {
                    Image(icon: "chevron.right").appText(.fine).foregroundStyle(Paper.tertiary)
                        .frame(minWidth: 20, minHeight: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(openHelp ?? "")
                .accessibilityHidden(true)
            }
        }
    }
}

// Name the closure at each call (`preview:` or `notes:`): a bare trailing closure matches both
// inits below, and Swift takes the one for notes.
extension ObjectCard where Notes == EmptyView {
    init(icon: String, title: String, detail: String, open: (@MainActor () -> Void)? = nil, openHelp: String? = nil,
         more: [StripButton] = [], tapAnywhere: Bool = true, @ViewBuilder preview: () -> Preview) {
        self.init(icon: icon, title: title, detail: detail, open: open, openHelp: openHelp, more: more,
                  tapAnywhere: tapAnywhere, preview: preview, notes: { EmptyView() })
    }
}

extension ObjectCard where Preview == EmptyView {
    init(icon: String, title: String, detail: String, open: (@MainActor () -> Void)? = nil, openHelp: String? = nil,
         more: [StripButton] = [], @ViewBuilder notes: () -> Notes) {
        self.init(icon: icon, title: title, detail: detail, open: open, openHelp: openHelp, more: more,
                  preview: { EmptyView() }, notes: notes)
    }
}
