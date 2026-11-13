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
    /// What a tap does; nil draws the card with no ›, and a tap does nothing.
    var open: (@MainActor () -> Void)?
    var openHelp: String?
    /// The actions that are not the tap: Undo These Changes, Pin to Folder, Full screen.
    var more: [StripButton] = []
    /// False when the preview is live (an app view): only the › opens, as the view takes its own taps.
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
        Group {
            // The whole card is the button, so a click anywhere on it opens (the ⋯ inside keeps its own).
            if let open, tapAnywhere {
                Button(action: open) { card }
                    .buttonStyle(.plain)
                    .help(openHelp ?? "")
            } else {
                card
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(detail)")
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if Preview.self != EmptyView.self {
                preview
                    .frame(maxWidth: .infinity)
                    .background(Paper.well)
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
        .contentShape(RoundedRectangle(cornerRadius: Paper.Radius.card))
    }

    private var row: some View {
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
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(StripWords.moreActions)
            }
            if let open {
                if tapAnywhere {
                    Image(icon: "chevron.right").appText(.fine).foregroundStyle(Paper.tertiary)
                        .accessibilityHidden(true)
                } else {
                    Button(action: open) {
                        Image(icon: "chevron.right").appText(.fine).foregroundStyle(Paper.tertiary)
                            .frame(minWidth: 24, minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(openHelp ?? "")
                    .accessibilityLabel(openHelp ?? title)
                }
            }
        }
    }
}

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
